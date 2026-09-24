---
layout: post
title:  "Why Constant Lookup in instance_eval Is More Complicated Than It Looks"
date:   2023-02-04 15:10
categories: Ruby TruffleRuby
---

Ruby developers frequently reach for `BasicObject#instance_eval` when building domain-specific languages or evaluating code dynamically. However, how Ruby resolves constants in code executed by `instance_eval` is practically undocumented and rarely behaves as engineers expect, even shifting between Ruby versions without much notice. While working on TruffleRuby compatibility with CRuby, I investigated how constant lookup works under the hood - uncovering an intricate resolution order and an unexpected quirk where defining a method silently flips constant lookup precedence.

### The Conflict: Caller Scope vs Receiver Hierarchy

In Ruby, `BasicObject#instance_eval` evaluates code within the context of the receiver, binding `self` to that object and granting direct access to its instance variables and private methods:

```ruby
receiver.instance_eval("@secret") # => self is receiver, exposing its instance variables
```

When passed a *block*, standard closure rules apply: `self` and instance variables come from the receiver, while everything else - including constants - resolves against the lexical scope where the block was defined.

When passed a *string*, however, there is no definition-site closure. The code executes dynamically in the context where `instance_eval` was called (the *caller*), but with `self` bound to the *receiver*.

To see why string evaluation is so unusual, it helps to recall how standard constant resolution works in Ruby. When an unqualified constant is referenced, Ruby searches:

- current and outer lexical scopes (class or module nesting)
- the current class and its ancestor chain (up to `Object` and `BasicObject`)

When evaluating a constant name inside `instance_eval`, two competing sources of constants collide:

- the caller - the lexical scopes and class hierarchy where `instance_eval` was called
- the receiver - the class hierarchy of the object on which `instance_eval` was called

### The Resolution Order

When resolving an unqualified constant inside a string passed to `instance_eval` (in Ruby 3.1+, without a singleton class), Ruby searches in the following order:

1. the receiver's class
2. the caller's immediate lexical scope
3. outer lexical scopes enclosing the caller
4. the receiver's superclasses and ancestors (up through `Object` and `BasicObject`)

We can observe this order with a minimal reproduction:

```ruby
module CallerOuter
  FOO = :caller_outer

  module CallerInner
    FOO = :caller_inner

    class CallerParent; FOO = :caller_parent; end

    class Caller < CallerParent
      FOO = :caller

      def resolve(receiver)
        receiver.instance_eval("FOO")
      end
    end
  end
end

module ReceiverOuter
  FOO = :receiver_outer

  module ReceiverInner
    FOO = :receiver_inner

    class ReceiverParent; FOO = :receiver_parent; end

    class Receiver < ReceiverParent
      FOO = :receiver_class
    end
  end
end

receiver = ReceiverOuter::ReceiverInner::Receiver.new
caller_instance = CallerOuter::CallerInner::Caller.new
```

When all constants are defined, the receiver's class takes precedence:

```ruby
caller_instance.resolve(receiver)
# => :receiver_class
```

If we remove `FOO` from `Receiver`, Ruby does not check its superclass or outer modules; instead, it falls back to the caller's immediate lexical scope:

```ruby
ReceiverOuter::ReceiverInner::Receiver.send(:remove_const, :FOO)
caller_instance.resolve(receiver)
# => :caller
```

If we remove `FOO` from `Caller`, Ruby continues walking outward through the caller's lexical scopes, completely bypassing `CallerParent`:

```ruby
CallerOuter::CallerInner::Caller.send(:remove_const, :FOO)
caller_instance.resolve(receiver)
# => :caller_inner

CallerOuter::CallerInner.send(:remove_const, :FOO)
caller_instance.resolve(receiver)
# => :caller_outer
```

Only after exhausting all caller lexical scopes does Ruby fall back to the receiver's inheritance chain:

```ruby
CallerOuter.send(:remove_const, :FOO)
caller_instance.resolve(receiver)
# => :receiver_parent
```

Finally, if we remove `FOO` from `ReceiverParent`, Ruby raises a `NameError`. Even though `CallerParent`, `ReceiverInner`, and `ReceiverOuter` all define `FOO`, Ruby never checks them:

```ruby
ReceiverOuter::ReceiverInner::ReceiverParent.send(:remove_const, :FOO)
caller_instance.resolve(receiver)
# => NameError: uninitialized constant ReceiverOuter::ReceiverInner::Receiver::FOO
```

An interesting observation is that CRuby omits several potential sources:
- `CallerParent` because caller lookup checks lexical nesting, not inheritance
- `ReceiverInner` and `ReceiverOuter` because `instance_eval` checks the receiver's class hierarchy, not where it was defined

### Under the Hood: Lazy Singletons in CRuby

Why does the receiver's class sit *in front* of the caller's lexical scope, while the receiver's superclass sits *behind* it?

The answer comes down to an internal optimization in CRuby and the way it tracks lexical scopes. In CRuby, lexical nesting is represented by an internal linked list of scope frames (known as `cref`). When evaluating a string with `instance_eval`, Ruby prepends a single scope frame for the receiver directly onto the caller's lexical chain.

Prior to Ruby 3.1, calling `instance_eval` on an object always eagerly created a singleton class for that object so that any method defined inside the evaluated string would attach to the instance rather than its class. Because the singleton class was created up front, the new scope frame pointed to that singleton class. A singleton class almost never defines constants, so Ruby quickly moved past it to check the caller's lexical scopes. Only during the subsequent inheritance fallback did Ruby search the singleton class's ancestors, finally reaching the receiver's class and superclasses *after* the caller.

In Ruby 3.1, John Hawthorn and Matthew Draper [optimized](https://github.com/ruby/ruby/pull/5146) this mechanism. Allocating a singleton class carries noticeable overhead, and most `instance_eval` invocations never define methods. To avoid that cost, Ruby stopped creating the singleton class immediately, instead marking the scope frame as a deferred singleton and storing the raw receiver object.

This optimization had an unintended consequence for constant resolution. When walking the lexical chain, the VM asks each scope frame for its class. Under lazy singletons, the very first step of constant lookup now checks *either* the receiver's class or its singleton class, depending on whether a singleton class has already been created.

If no singleton class has been materialized yet, the VM returns the receiver's own class, placing it directly at the front of the lexical search - before the caller's lexical scopes. But if a singleton class already exists, the VM returns that singleton class instead, and on the final step the receiver's class and its ancestors are searched (instead of just its superclasses).

We can see how this was implemented directly in CRuby (`eval_intern.h`). When retrieving the class for a scope frame, the VM calls `CREF_CLASS`:

```c
static inline VALUE
CREF_CLASS(const rb_cref_t *cref)
{
    if (CREF_SINGLETON(cref)) {
        return CLASS_OF(cref->klass_or_self);
    }
    return cref->klass_or_self;
}
```

For lazy singletons, `CREF_SINGLETON(cref)` is true, directing the VM to `CLASS_OF(cref->klass_or_self)`. In CRuby, `CLASS_OF` returns the object's singleton class if one has already been allocated, or its basic class if not. That single check determines whether `Receiver` enters constant lookup on step 1 or step 4.

### How Defining a Method Flips Lookup

This lazy-singleton mechanism produces an unexpected side effect: materializing a singleton class on the receiver - whether beforehand or mid-evaluation - silently flips constant lookup precedence back to the pre-3.1 order.

We can observe this in practice:

```ruby
class Receiver
  FOO = :from_receiver
end

class Caller
  FOO = :from_caller

  def evaluate(receiver, code)
    receiver.instance_eval(code)
  end
end

caller_inst = Caller.new

# 1. Default (lazy singleton): receiver class takes precedence
puts caller_inst.evaluate(Receiver.new, "FOO")
# => :from_receiver

# 2. Materialized singleton: resolution flips to the caller
obj = Receiver.new
obj.singleton_class
puts caller_inst.evaluate(obj, "FOO")
# => :from_caller

# 3. Defining a method: dynamically materializes singleton mid-execution
puts caller_inst.evaluate(Receiver.new, "def hook; end; FOO")
# => :from_caller
```

A seemingly unrelated operation - inspecting `obj.singleton_class` or defining a method inside the evaluated string - silently alters constant lookup order.

### Compatibility in TruffleRuby

This investigation began when addressing a test failure in Sprockets on TruffleRuby ([Issue #2810](https://github.com/truffleruby/truffleruby/issues/2810)). Sprockets evaluated ERB templates using `engine.result(a.instance_eval('binding'))`, which failed because TruffleRuby and CRuby resolved constants differently. Tracing the incompatibility required digging into CRuby's source code to see what the runtime was actually doing.

To implement matching lookup in TruffleRuby, we [prepended](https://github.com/truffleruby/truffleruby/commit/f9113553823106072f9979b72ccaae9a7e372119) both the receiver's class and its singleton class (if one can exist) to the caller's lexical scope chain.

This leads to an interesting divergence between the two implementations. Because TruffleRuby explicitly links both the singleton class and the receiver's class into the scope chain, it consistently follows the order: `singleton class -> receiver class -> caller scopes -> receiver ancestors`. In TruffleRuby, defining a method or inspecting `singleton_class` does not flip constant lookup: the receiver's class always remains ahead of the caller.

The behavior was documented with new specs added to the *ruby/spec* test suite.

### Summary

Constant lookup is one of the most complex parts of Ruby, and `instance_eval` makes it even harder to grasp. With caller and receiver colliding, it is clear why the Ruby core team omitted steps like the caller's class and ancestors. It also shows how easily a minor optimization can introduce a breaking change when VM internals are tightly coupled. For DSL authors, the takeaway is simple: avoid unqualified constant lookup inside `instance_eval` strings and qualify constants explicitly (`::Foo`).
