---
layout:     post
title:      "Under the Hood of RuboCop: Fixing AST Node Patterns in Minitest Cops"
date:       2020-06-27 14:01
categories: Ruby RuboCop
---

While upgrading Minitest on an open-source project, I used `rubocop-minitest` to migrate deprecated global expectations, but found that its autocorrection silently missed several valid expressions. In this post, I dig into the `Minitest/GlobalExpectations` cop to explore why allowlisting AST node types fails in Ruby, how matching by exclusion fixes it, and how to test RuboCop AST patterns in isolation.


## Background

Historically, Minitest provided expectation syntax by monkey-patching methods like `must_equal` and `must_raise` directly onto Ruby's top-level `Object`. Because polluting `Object` with dozens of matcher methods can cause naming collisions and subtle bugs, newer versions of Minitest deprecated these global matchers in favor of an explicit expectation DSL: wrapping values in `_(...)` and blocks in `_ { ... }`.

To automate this migration across test suites, the `rubocop-minitest` gem provides the `Minitest/GlobalExpectations` cop:

```ruby
# bad
musts.must_equal expected_musts

# good
_(musts).must_equal expected_musts
```

However, when running autocorrection on real-world projects, the cop skipped several valid expressions - including chained array indexing, method calls on constants, and calls with arguments in the receiver chain. To understand why it failed, let's look at how `Minitest/GlobalExpectations` works under the hood.


## How `Minitest/GlobalExpectations` Works

The entry point into the cop ([source](https://github.com/rubocop-hq/rubocop-minitest/blob/v0.8.0/lib/rubocop/cop/minitest/global_expectations.rb)) is the `on_send` callback:

```ruby
def on_send(node)
  return unless global_expectation?(node)

  message = format(MSG, preferred: preferred_receiver(node))
  add_offense(node, location: node.receiver.source_range, message: message)
end
```

RuboCop traverses ASTs using the Visitor pattern, invoking node callbacks like `on_class`, `on_def`, or `on_send` across active cops. The `on_send` callback runs for every `send` node (representing a method call), passing the AST node as `node`. (See the [`parser` gem documentation](https://whitequark.github.io/parser/Parser/AST/Processor.html) for all node callbacks).

The AST subtree for a method call looks like this:

<img src="/assets/images/2020-06-27-rubocop-fixing-ast-node-patterns-in-minitest-cops/send-node.svg"/>

In this subtree, the root is the `send` node, with child nodes for:
- the object on which the method is called (the *receiver*)
- the method name
- the arguments (if any)

For example, `obj.must_equal expected` produces the following AST (where `obj` and `expected` are parsed as method calls on implicit `self`):

```
(send
  (send nil :obj)
  :must_equal
  (send nil :expected))
```

<img src="/assets/images/2020-06-27-rubocop-fixing-ast-node-patterns-in-minitest-cops/matcher-node.svg"/>

The logic of the `on_send` callback is simple. It checks if the current `send` node is a call to one of the Minitest global matchers (`must_be_empty`, `must_equal`, `must_be_close_to`, `must_be_within_delta`...):

```ruby
return unless global_expectation?(node)
```

If the check succeeds and a deprecated method is found, the cop registers an offense:

```ruby
add_offense(node, location: node.receiver.source_range, message: message)
```

The method `global_expectation?` is pretty interesting. It's defined in an unusual way using the `def_node_matcher` macro:

```ruby
def_node_matcher :global_expectation?, <<~PATTERN
  (send {
    (send _ _)
    ({lvar ivar cvar gvar} _)
    (send {(send _ _) ({lvar ivar cvar gvar} _)} _ _)
  } {#{MATCHERS_STR}} ...)
PATTERN
```

The `def_node_matcher` macro generates a new `global_expectation?` method that queries AST nodes using RuboCop's pattern-matching engine. The pattern follows the `(send <receiver> <method name> <arguments>)` structure:

- The receiver `{ ... }` uses `{}` for a logical **OR**, matching any of three shapes: (1) zero-argument method calls `(send _ _)`, (2) variables `({lvar ivar cvar gvar} _)`, or (3) single-argument calls on a variable or zero-argument call `(send ... _ _)`.
- The method name `{#{MATCHERS_STR}}` expands to any deprecated matcher symbol (`:must_be_empty`, `:must_equal`, `:must_be_close_to`, etc.).
- The trailing `...` wildcard matches any sequence of method arguments (or none).


## So What Was Wrong?

The original receiver pattern was an **allowlist**: it only permitted variables, zero-argument method calls, or single-argument calls where the inner receiver was itself a variable or zero-argument call. But in Ruby's grammar, virtually any valid expression (constants, indexed lookups, chained invocations, block returns) can act as a method receiver.

Consequently, the cop failed on many valid expressions:

```ruby
# Array/Hash indexing (method calls with arguments)
response[1]['X-Runtime'].must_match /[\d\.]+/

# Nested calls with arguments in the receiver chain
::File.read(::File.join(@def_disk_cache, 'path', 'to', 'blah.html')).must_equal @def_value.first

# Constant / module paths
Rack::Contrib.must_respond_to(:release)
```

Taking the last example (`Rack::Contrib.must_respond_to(:release)`), its AST is:

```
(send
  (const
    (const nil :Rack) :Contrib)
  :must_respond_to
  (sym :release))
```

Here, the receiver is a `(const ...)` node, which completely fails to match the whitelist. Trying to fix this by manually adding every possible Ruby AST node type (`const`, method calls with arguments, literals, etc.) to the pattern would quickly turn into an unmaintainable game of whack-a-mole.


## The Solution

Instead of whitelisting valid receiver types, the right approach is to **invert the logic**: match *any* receiver, **unless** it has already been wrapped in the new expectation syntax.

The starting pattern is much simpler and broader:

```
(send !(send nil? :_ _) {#{MATCHERS_STR}} ...)
```

Here, `!` negates the pattern, and `nil?` matches a top-level call to `_(...)`. This catches any target expression not already wrapped in `_()`, seamlessly covering constants, array lookups, and method chains.

### Handling Edge Cases

Because our strategy is to match any receiver that is *not* already modernized, we need to recognize what the **new DSL** looks like in the AST.

Real-world code introduced two complications:

First, modernized value expectations and block expectations produce fundamentally different receiver ASTs:

- Modern value expectation (`_(obj.foo).must_equal :bar`):
  ```
  (send
    (send nil :_
      (send
        (send nil :obj) :foo)) :must_equal
    (sym :bar))
  ```

- Modern block expectation (`_ { obj.foo }.must_raise ArgumentError`):
  ```
  (send
    (block
      (send nil :_)
      (args)
      (send
        (send nil :obj) :foo)) :must_raise
    (const nil :ArgumentError))
  ```

In the value expectation, the receiver of `:must_equal` is a `send` node (`(send nil :_ ...)`). But in the block expectation, the receiver of `:must_raise` is a `block` node (`(block (send nil :_) ...)`). Because of this structural difference, we cannot use a single pattern to recognize both modernized forms - they require separate pattern matchers.

Second, Minitest supports `value` and `expect` as aliases for `_`. To avoid false positives on already modernized code, both matchers must account for all three helper methods (`_`, `value`, and `expect`), whether called with an argument (`_(...)`) or a block (`_ { ... }`).


### Putting It All Together

Combining these patterns and helper aliases, the updated cop implementation looks like this:

```ruby
# There are aliases for the `_` method - `expect` and `value`
DSL_METHODS_LIST = %w[_ value expect].map do |n|
  ":#{n}"
end.join(' ').freeze

def_node_matcher :value_global_expectation?, <<~PATTERN
  (send !(send nil? {#{DSL_METHODS_LIST}} _) {#{VALUE_MATCHERS_STR}} _)
PATTERN

def_node_matcher :block_global_expectation?, <<~PATTERN
  (send
    [
      !(send nil? {#{DSL_METHODS_LIST}} _)
      !(block (send nil? {#{DSL_METHODS_LIST}}) _ _)
    ]
    {#{BLOCK_MATCHERS_STR}}
    _
  )
PATTERN

def on_send(node)
  return unless value_global_expectation?(node) || block_global_expectation?(node)

  message = format(MSG, preferred: preferred_receiver(node))
  add_offense(node, location: node.receiver.source_range, message: message)
end
```

While `value_global_expectation?` is straightforward, the `block_global_expectation?` pattern is worth a closer look. In this matcher, the `[...]` brackets denote a logical **AND**. The second condition `!(block ...)` handles standard block syntax (`_ { ... }`), while the first condition `!(send nil? ...)` handles the case where a proc or lambda stored in a variable is passed as an argument (`_(action).must_raise`).


### The Arity Trap: Why Existing Tests Didn't Catch It

My PR was approved, all tests passed, and it was merged. But look closely at the trailing `_` in the matcher:

```ruby
def_node_matcher :value_global_expectation?, <<~PATTERN
  (send !(send nil? {#{DSL_METHODS_LIST}} _) {#{VALUE_MATCHERS_STR}} _)
PATTERN
```

In RuboCop's `NodePattern`, `_` matches **exactly one node**. By ending the pattern with `_`, I had inadvertently required every expectation method call to take exactly one argument.

Why did the test suite pass? Because every single test case added in the PR happened to use single-argument assertions like `.must_equal 42` or `.must_match /.../`.

In reality, Minitest matchers have variable arities:
- Zero-argument matchers (`n.must_be_nil`, `list.must_be_empty`, `-> { puts }.must_be_silent`) take no arguments.
- Multi-argument matchers (`val.must_be_within_delta(expected, delta)`) take two or more.

Because of that trailing `_`, expectations like `n.must_be_nil` were completely skipped. Right after the PR was merged, Yasuo Honda [spotted](https://github.com/rubocop/rubocop-minitest/issues/75) this false negative, and Koichi Ito [fixed](https://github.com/rubocop/rubocop-minitest/commit/fb1131c41814b1a3eff19465c5a8d9a50466c622) it by replacing `_` with the variable-length wildcard `...`:

```diff
- (send !(send nil? {#{DSL_METHODS_LIST}} _) {#{VALUE_MATCHERS_STR}} _)
+ (send !(send nil? {#{DSL_METHODS_LIST}} _) {#{VALUE_MATCHERS_STR}} ...)
```

In `NodePattern`, `...` matches zero or more elements. It is an easy trap to fall into: when test suites only exercise the most common call patterns, fixed-arity constraints can easily slip through.


## A Quick Recipe for Testing Node Patterns

Crafting and debugging Node Patterns is often the trickiest part of writing RuboCop cops. While RuboCop recommends `NodePattern` over manual AST traversal, documentation is sparse and relying on full RSpec test runs is slow.

Here is a lightweight standalone script to test patterns against target Ruby snippets with an instant feedback loop:

```ruby
require 'rubocop'

source = "-> { obj.foo }.must_raise ArgumentError"
pattern = '(send _ :must_raise _)'

processed_source = RuboCop::AST::ProcessedSource.new(source, 2.7)
node_pattern = RuboCop::AST::NodePattern.new(pattern)
node_pattern.match(processed_source.ast) # => true | nil
```

`RuboCop::AST::ProcessedSource` parses any Ruby code into an AST (available via `#ast`). We then compile our pattern with `RuboCop::AST::NodePattern` and call `#match`, which returns `true` on match and `nil` otherwise. This makes it effortless to test edge cases in isolation before plugging them into a cop.


## Conclusion

The bug was fixed and [my PR](https://github.com/rubocop/rubocop-minitest/pull/72) was merged. Even though it was in an official plugin rather than the core RuboCop repository, it was a satisfying win.

For me, the biggest takeaway was to avoid allowlisting AST node types for open-ended expressions. In Ruby, virtually anything can act as a receiver, so enumerating valid shapes quickly becomes a game of whack-a-mole. Matching by exclusion produces far cleaner, more resilient rules.

While I gained a solid understanding of RuboCop cops and Node Patterns, questions still remain around direct AST manipulation without patterns, less common node types, and traversal order nuances where RuboCop relies heavily on the underlying `parser` gem.


## References & Further Reading

### Official Documentation & Guides
- [RuboCop Development Documentation](https://docs.rubocop.org/rubocop/latest/development.html)
- [RuboCop::AST::NodePattern API Docs](https://www.rubydoc.info/gems/rubocop-ast/0.0.3/RuboCop/AST/NodePattern)
- [RuboCop Node Pattern Syntax Guide](https://github.com/rubocop-hq/rubocop-ast/blob/1899234a41c399aa9a445b9bb44716815fda5559/docs/modules/ROOT/pages/node_pattern.adoc)
- [Parser Gem AST Format Guide](https://github.com/whitequark/parser/blob/master/doc/AST_FORMAT.md)

### Community Articles on Writing Custom Cops
- [Rewriting code with Rubocop](https://kirshatrov.com/posts/rewrite-code-with-rubocop)
- [How to Write Custom Rubocop Linters for Database Migrations](https://downey.io/blog/writing-rubocop-linters-for-database-migrations/)
- [How to Add a Custom Cop to RuboCop](https://medium.com/@DmytroVasin/how-to-add-a-custom-cop-to-rubocop-47abf82f820a)

