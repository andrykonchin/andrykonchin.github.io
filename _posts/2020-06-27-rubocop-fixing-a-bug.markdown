---
layout:     post
title:      "RuboCop: Fixing a Bug"
date:       2020-06-27 14:01
categories: Ruby RuboCop
---

Recently, I had a chance to contribute to [RuboCop](https://github.com/rubocop-hq/rubocop) - a great opportunity to dive into my long-standing interest in parsers and ASTs. More than just a linter, RuboCop is a complete static analysis framework that parses Ruby source code and automatically corrects offenses against the [Ruby Style Guide](https://rubystyle.guide/).

While there is [official documentation](https://docs.rubocop.org/rubocop/0.85/development.html) for building custom rules (*cops*), it is quite brief. In this post, I'll share my experience fixing a bug in one of the cops for Minitest: exploring how cops work under the hood, how AST Node Patterns are written, and how to test them in isolation.


### Background

While upgrading Minitest on an open-source project, I ran into a flood of deprecation warnings for global expectation matchers. To resolve them quickly, I turned to the official `rubocop-minitest` plugin.

To my surprise, RuboCop's autocorrection missed several occurrences. Rather than just reporting an issue, I decided to investigate the cop responsible: `Minitest/GlobalExpectations`. Its job is to rewrite deprecated global calls to Minitest's newer expectation DSL:

```ruby
# bad
musts.must_equal expected_musts

# good
_(musts).must_equal expected_musts
```

Let's look into how `Minitest/GlobalExpectations` works under the hood.


### How `Minitest/GlobalExpectations` Works

The entry point into the cop ([source](https://github.com/rubocop-hq/rubocop-minitest/blob/v0.8.0/lib/rubocop/cop/minitest/global_expectations.rb)) is the `on_send` callback:

```ruby
def on_send(node)
  return unless global_expectation?(node)

  message = format(MSG, preferred: preferred_receiver(node))
  add_offense(node, location: node.receiver.source_range, message: message)
end
```

RuboCop uses the Visitor pattern: each cop defines one or multiple callbacks for specific AST node types (such as `on_class`, `on_def`, `on_if`, or `on_const`). As RuboCop traverses the AST, it invokes the corresponding callbacks registered across all active cops.

The `on_send` callback is triggered for every node of type `send` (which represents a Ruby method call), passing the AST node to the callback via the `node` argument. (The full list of node callbacks is available in the [`parser` gem documentation](https://whitequark.github.io/parser/Parser/AST/Processor.html)).

The AST subtree for a method call looks like this:

<img src="/assets/images/2020-06-27-rubocop-exerсise-1/send-node.svg"/>

In this subtree, the root is the `send` node, with child nodes for:
- the object on which the method is called (the *receiver*)
- the method name
- the arguments (if any)

In our case, for instance, an expression `obj.must_equal expected` is represented by the following AST:

```
(send
  (send nil :obj)
  :must_equal
  (send nil :expected))
```

where:
- *receiver* — `(send nil :obj)`
- method name — `:must_equal`
- argument — `(send nil :expected)`

<img src="/assets/images/2020-06-27-rubocop-exerсise-1/matcher-node.svg"/>

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

The `def_node_matcher` macro call generates a new `global_expectation?` method that matches an AST node against the specified pattern. RuboCop implements its own pattern-matching engine (similar to regular expressions for ASTs) to query node structures.

The pattern has the following structure:

```
(send <receiver> <method name> <arguments>)
```

The receiver subpattern is:

```
{
  (send _ _)
  ({lvar ivar cvar gvar} _)
  (send {(send _ _) ({lvar ivar cvar gvar} _)} _ _)
}
```

`{}` denotes a logical **OR**, meaning the receiver is either a method call without arguments (`send _ _`), a variable (`{lvar ivar cvar gvar}`), or a method call chain (`send {(send _ _) ({lvar ivar cvar gvar} _)} _ _`).

The method name subpattern is:

```
{#{MATCHERS_STR}}
```

The `MATCHERS_STR` constant is a list of deprecated Minitest matchers separated by spaces (`:must_be_empty :must_equal :must_be_close_to ...`), so the subpattern expands to:

```
{:must_be_empty :must_equal :must_be_close_to ...}
```

Method arguments match the wildcard `...` subpattern, representing any sequence of child nodes (or none at all).


### So What Was Wrong?

The receiver pattern in the original cop was far too restrictive:

```
{
  (send _ _)
  ({lvar ivar cvar gvar} _)
  (send {(send _ _) ({lvar ivar cvar gvar} _)} _ _)
}
```

It attempted to **whitelist** acceptable receiver shapes, permitting only local/instance/class variables, zero-argument method calls, or simple call chains. But in Ruby, almost *any* expression can act as a method receiver.

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


### The Solution

Instead of whitelisting valid receiver types, the right approach is to **invert the logic**: match *any* receiver, **unless** it has already been wrapped in the new expectation syntax.

The starting pattern is much simpler and broader:

```
(send !(send nil? :_ _) {#{MATCHERS_STR}} ...)
```

Here, `!` negates the pattern, and `nil?` matches a top-level call to `_(...)`. This catches any target expression not already wrapped in `_()`, seamlessly covering constants, array lookups, and method chains.

#### Handling Edge Cases

However, real-world code introduced two complications:

##### Value Expectations vs. Block Expectations

Minitest expectations fall into two categories: those checking an expression's value and those checking a block of code. Their syntax and resulting AST structures differ significantly:

* **Value expectation** (`must_equal`, `wont_match`, etc.):
  ```ruby
  obj.foo.must_equal :bar
  ```
  ```
  (send
    (send
      (send nil :obj) :foo) :must_equal
    (sym :bar))
  ```

* **Block expectation** (`must_raise`, `must_output`, etc.):
  ```ruby
  -> { obj.foo }.must_raise ArgumentError
  ```
  ```
  (send
    (block
      (lambda)
      (args)
      (send
        (send nil :obj) :foo)) :must_raise
    (const nil :ArgumentError))
  ```

Because of this difference in AST layout, we need separate pattern matchers for value and block expectations.

##### DSL Aliases

In the new DSL, the checked expression is wrapped with `_(obj)`. However, Minitest also supports `value` and `expect` as aliases:

```ruby
_(obj.foo).must_equal :bar
value(obj.foo).must_equal :bar
expect(obj.foo).must_equal :bar
```

To avoid registering false positives on already modernized code, we must account for all three helper methods (`_`, `value`, and `expect`), whether they receive a value as an argument (`_(...)`) or a block (`_ { ... }`).


#### Putting It All Together

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


### A Quick Recipe for Testing Node Patterns

When writing custom cops or fixing existing ones, crafting and debugging Node Patterns is often the trickiest part. While RuboCop strongly recommends using `NodePattern` over manual AST traversal, the pattern engine (implemented in [`RuboCop::AST::NodePattern`](https://github.com/rubocop-hq/rubocop-ast/blob/master/lib/rubocop/ast/node_pattern.rb) and extracted into the `rubocop-ast` gem) has relatively sparse documentation:

- [RuboCop::AST::NodePattern API Docs](https://www.rubydoc.info/gems/rubocop-ast/0.0.3/RuboCop/AST/NodePattern)
- [Node Pattern Syntax Guide](https://github.com/rubocop-hq/rubocop-ast/blob/1899234a41c399aa9a445b9bb44716815fda5559/docs/modules/ROOT/pages/node_pattern.adoc)

Relying on trial-and-error by re-running an entire RSpec suite is slow and tedious. If you are developing your own patterns, here is a lightweight standalone script you can use to test patterns against target Ruby snippets with an instant feedback loop:

```ruby
require 'rubocop'

source = "-> { obj.foo }.must_raise ArgumentError"
pattern = '(send _ :must_raise _)'

processed_source = RuboCop::AST::ProcessedSource.new(source, 2.7)
node_pattern = RuboCop::NodePattern.new(pattern)
node_pattern.match(processed_source.ast) # => true | nil
```

`RuboCop::AST::ProcessedSource` parses any Ruby code into an AST (available via `#ast`). We then compile our pattern with `RuboCop::NodePattern` and call `#match`, which returns `true` on match and `nil` otherwise. This makes it effortless to test edge cases in isolation before plugging them into a cop.


### Conclusion

The bug was fixed and [my PR](https://github.com/rubocop/rubocop-minitest/pull/72) was merged. Even though it was in an official plugin rather than the core RuboCop repository, it was a satisfying win.

While I gained a solid understanding of RuboCop cops and Node Patterns, I still haven't had the chance to manipulate AST nodes directly without patterns. A few questions remain around less common AST node types and exact traversal orders - areas where documentation is sparse and RuboCop relies heavily on the underlying `parser` gem. Even in a project as mature and widely used as RuboCop, abstractions can still leak.


### References & Further Reading

#### Official Documentation & Guides
- [RuboCop Development Documentation](https://docs.rubocop.org/rubocop/latest/development.html)
- [RuboCop::AST::NodePattern API Docs](https://www.rubydoc.info/gems/rubocop-ast/0.0.3/RuboCop/AST/NodePattern)
- [RuboCop Node Pattern Syntax Guide](https://github.com/rubocop-hq/rubocop-ast/blob/1899234a41c399aa9a445b9bb44716815fda5559/docs/modules/ROOT/pages/node_pattern.adoc)
- [Parser Gem AST Format Guide](https://github.com/whitequark/parser/blob/master/doc/AST_FORMAT.md)

#### Community Articles on Writing Custom Cops
- [Rewriting code with Rubocop](https://kirshatrov.com/posts/rewrite-code-with-rubocop)
- [How to Write Custom Rubocop Linters for Database Migrations](https://downey.io/blog/writing-rubocop-linters-for-database-migrations/)
- [How to Add a Custom Cop to RuboCop](https://medium.com/@DmytroVasin/how-to-add-a-custom-cop-to-rubocop-47abf82f820a)


[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
