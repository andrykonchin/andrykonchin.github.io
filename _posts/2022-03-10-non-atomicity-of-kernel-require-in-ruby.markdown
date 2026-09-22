---
layout: post
title:  "The Non-Atomicity of Kernel#require in Ruby"
date:   2022-03-10 18:00
categories: Ruby
---

In Ruby, `Kernel#require` is so fundamental that we rarely question how it behaves behind the scenes. We take for granted that it just works, seldom pausing to consider the runtime details: Is `require` thread-safe? Is it atomic? How does it deal with circular dependencies? Encountering an unexpected race condition in a multi-threaded application led me to examine these guarantees closely. What I discovered was surprising: `Kernel#require` is not an atomic operation.

### The Non-Atomic Nature of File Loading

In computer systems, atomicity implies two distinct properties:

1. Isolation under concurrency: an outside observer cannot see intermediate states while the operation is in flight.
2. All-or-nothing failure semantics: if an operation fails or is aborted, it rolls back so that either all effects occur or none do.

`Kernel#require` provides neither guarantee.

In many languages, including a dependency is a compile-time or boot-time operation where declarations are finalized before execution begins. In Ruby, `require` is an ordinary runtime method, and the class, method, and variable initializations inside the file are executable statements evaluated on the fly. Opening a class immediately makes its constant accessible - long before its methods exist - breaking isolation under concurrency.

```ruby
# required_file.rb
class A
  sleep 0.1 # simulate work
  def foo; end
end
```

An outside thread querying the namespace mid-load observes the class before its methods exist:

```ruby
Object.const_defined?(:A)         # => true
A.instance_methods.include?(:foo) # => false
```

Any thread calling `A.new.foo` during this window crashes with a `NoMethodError`.

Ruby also lacks all-or-nothing failure semantics: an exception raised midway leaves all previously evaluated constants and methods in memory, even though the file is omitted from `$LOADED_FEATURES`.

### Checking Constant Existence: A Concurrency Trap

The real danger emerges from the combination of *lazy loading and concurrent processing*. When a shared component - such as a dynamic plugin or database adapter - is initialized on demand rather than eagerly at boot, multiple worker threads in Sidekiq or Puma may attempt to initialize it concurrently on first use.

To avoid race conditions and prevent loading the file multiple times, it is tempting to use `const_defined?` as a guard:

```ruby
def adapter
  unless const_defined?(:MyAdapter)
    require 'my_adapter'
  end
  MyAdapter.new
end
```

The irony is that this check achieves the exact opposite. By attempting to prevent a race condition with `const_defined?`, the code actually introduces one:

1. Thread 1 calls `adapter`, finds the constant undefined, and invokes `require 'my_adapter'`.
2. Inside `require`, CRuby acquires its internal load lock. Opening `class MyAdapter` immediately registers the constant.
3. Thread 2 calls `adapter` concurrently. Seeing the constant defined, it skips `require` - bypassing CRuby's internal lock entirely.
4. Thread 2 instantiates `MyAdapter.new` and invokes methods that Thread 1 has not defined yet, crashing with `NoMethodError`.

### The Real-World Fix: Trust `require`

I came across this exact issue while reviewing a pull request for Dynamoid, the DynamoDB ORM I maintain ([Dynamoid PR #373](https://github.com/Dynamoid/dynamoid/pull/373)).

The pull request addressed intermittent `NoMethodError` exceptions during Sidekiq startup. When Sidekiq booted with multiple worker threads, they immediately began executing jobs that made database queries. Because the database adapter was loaded lazily on first access, the worker threads collided during initialization. Random threads crashed with `NoMethodError` calling methods that were clearly present in the adapter's source code, yet the issue never reproduced in single-threaded test suites and completely vanished once the process had warmed up.

The submitted fix was counter-intuitive: *delete the `const_defined?` guard completely*:

```diff
- unless Dynamoid.const_defined?(:AdapterPlugin) && Dynamoid::AdapterPlugin.const_defined?(name)
-   require "dynamoid/adapter_plugin/#{name}"
- end
+ require "dynamoid/adapter_plugin/#{name}"
```

CRuby's `Kernel#require` already synchronizes concurrent loads with an internal per-feature lock. Calling `require` unconditionally forces subsequent threads to wait until the file has completely finished evaluating, proceeding only when all methods and constants are in place.

### Takeaways

- Ruby defines classes imperatively; constants become accessible as soon as the `class` statement begins executing, not when it finishes.
- Never guard `require` with `const_defined?` in multi-threaded paths. It bypasses CRuby's internal require lock and exposes half-loaded classes.
- Trust `Kernel#require` to handle its own synchronization, or eagerly load dependencies during boot before starting worker threads.
