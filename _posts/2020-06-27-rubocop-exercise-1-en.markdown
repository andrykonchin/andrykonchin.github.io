---
layout:     post
title:      Rubocop. Fixing a bug
date:       2020-06-27 14:01
categories: Ruby Rubocop
---

Recently I had a chance to be involved in one of the most
interesting Ruby libraries - Rubocop. If you didn't hear about it -
it's a Ruby linter. No, it's not accurate. It's a framework for
developing your own rules and policies. Rubocop statically analyzes Ruby
source code and by default applies rules of [Ruby Style
Guide](https://rubystyle.guide/). Moreover it can automatically correct
source code - removes excessive whitespaces, replaces `unless` keywords
with `if` etc.

I have been interested in parsers, lexers, syntax analysis, AST etc for
a long time since graduating from university and now I had an
opportunity to touch on this topic.

There is an [official
documentation](https://docs.rubocop.org/rubocop/0.85/development.html)
for developing new rules and autocorrections (_cops_ in Rubocop terms).
But it's too brief and a poor developer is forced to look under the hood
and figure out how everything works on his own. No wonder there are
numerous blog posts with examples of developing new cops (I will list
some of them at the end of the post).

In this post I will describe my first experience with Rubocop. I've
fixed a bug in one of the _cops_ for Minitest - it's a library for
unit-testing like RSpec. I had to dive into Rubocop source code to find
out how _cops_ work. As well as AST patterns. And how to test them.


### Background

One open source project I was contributing to uses Minitest for unit
testing. Strange choice, I would say. Personally I prefer RSpec. That
time I upgraded the Minitest version and it caused numerous deprecation
warnings. So I gave Rubocop autocorrection a try - Rubocop doesn't
contain _cops_ for libraries but there are official and not official
plugins for popular ones, and for Minitest as well - `rubocop-minitest`.

To my surprise Rubocop fixed not all the warnings. And it definitely was
a bug. "Good time to get familiar with Rubocop" - I told myself.  And
instead of reporting a new issue I started investigating it.

A _cop_ responsible for correcting these warnings is
`Minitest/GlobalExpectations`. It is searching for deprecated method
calls (global matchers `must_equal`, `wont_match` etc) and replaces them
with a new DSL, e.g.:

```ruby
# bad
musts.must_equal expected_musts

# good
_(musts).must_equal expected_musts
```

Let's look into how the `Minitest/GlobalExpectations` _cop_ works.


### Minitest/GlobalExpectations _cop_

The source code of the _cop_ (we will describe it in details below):

```ruby
# frozen_string_literal: true

module RuboCop
  module Cop
    module Minitest
      # This cop checks for deprecated global expectations
      # and autocorrects them to use expect format.
      #
      # @example
      #   # bad
      #   musts.must_equal expected_musts
      #   wonts.wont_match expected_wonts
      #   musts.must_raise TypeError
      #
      #   # good
      #   _(musts).must_equal expected_musts
      #   _(wonts).wont_match expected_wonts
      #   _ { musts }.must_raise TypeError
      class GlobalExpectations < Cop
        MSG = 'Use `%<preferred>s` instead.'

        VALUE_MATCHERS = %i[
          must_be_empty must_equal must_be_close_to must_be_within_delta
          must_be_within_epsilon must_include must_be_instance_of must_be_kind_of
          must_match must_be_nil must_be must_respond_to must_be_same_as
          path_must_exist path_wont_exist wont_be_empty wont_equal wont_be_close_to
          wont_be_within_delta wont_be_within_epsilon wont_include wont_be_instance_of
          wont_be_kind_of wont_match wont_be_nil wont_be wont_respond_to wont_be_same_as
        ].freeze

        BLOCK_MATCHERS = %i[must_output must_raise must_be_silent must_throw].freeze

        MATCHERS_STR = (VALUE_MATCHERS + BLOCK_MATCHERS).map do |m|
          ":#{m}"
        end.join(' ').freeze

        def_node_matcher :global_expectation?, <<~PATTERN
          (send {
            (send _ _)
            ({lvar ivar cvar gvar} _)
            (send {(send _ _) ({lvar ivar cvar gvar} _)} _ _)
          } {#{MATCHERS_STR}} ...)
        PATTERN

        def on_send(node)
          return unless global_expectation?(node)

          message = format(MSG, preferred: preferred_receiver(node))
          add_offense(node, location: node.receiver.source_range, message: message)
        end

        def autocorrect(node)
          return unless global_expectation?(node)

          lambda do |corrector|
            receiver = node.receiver.source_range

            if BLOCK_MATCHERS.include?(node.method_name)
              corrector.insert_before(receiver, '_ { ')
              corrector.insert_after(receiver, ' }')
            else
              corrector.insert_before(receiver, '_(')
              corrector.insert_after(receiver, ')')
            end
          end
        end

        private

        def preferred_receiver(node)
          source = node.receiver.source
          if BLOCK_MATCHERS.include?(node.method_name)
            "_ { #{source} }"
          else
            "_(#{source})"
          end
        end
      end
    end
  end
end
```
([source](https://github.com/rubocop-hq/rubocop-minitest/blob/v0.8.0/lib/rubocop/cop/minitest/global_expectations.rb))

An entry point into the _cop_ is an `on_send` method:

```ruby
def on_send(node)
  # ...
end
```

RuboCop uses the Visitor pattern and every _cop_ declares one or
multiple callbacks for AST nodes. Rubocop traverses an AST and for each
node calls corresponding callbacks declared in all the _copes_. The
`on_send` callback will be called for every node of type _send_. The
type _send_ means, as you might guess, a method call. A node is passed
as a parameter `node` into a callback.

Every syntax construction is represented by a certain node type and
there is a corresponding callback, e.g.:
* on_def - for a method definition
* on_class - for a class definition
* on_module - for a module definition
* on_block - for a block literal (`{}` or `do`/`end`)
* on_if - for `if` conditional operator
* on_ensure - for an `ensure` section
* on_const - for a constant (e.g `FooBar`)
* on_hash - for a `Hash` literal
* on_array - for an `Array` literal

The whole list of callbacks could be found in `parser` _gem_'s
documentation
([here](https://whitequark.github.io/parser/Parser/AST/Processor.html))

An AST subtree for a method call looks in the following way:

<img src="/assets/images/2020-06-27-rubocop-exerсise-1/send-node.svg"/>

Here a root is a node _send_. There are children nodes:
- object, a method is called on, _receiver_
- method name
- argument (or a list of arguments)

In our case, for instance, an expression `obj.must_equal expected` is
represented by the following AST:

```
(send
  (send nil :obj)
  :must_equal
  (send nil :expected))
```

где:
- _receiver_ - `(send nil :obj)`
- method name - `:must_equal`
- and argument - `(send nil :expected))`

<img src="/assets/images/2020-06-27-rubocop-exerсise-1/matcher-node.svg"/>

The logic of the `on_send` callback is simple:

```ruby
def on_send(node)
  return unless global_expectation?(node)

  message = format(MSG, preferred: preferred_receiver(node))
  add_offense(node, location: node.receiver.source_range, message: message)
end
```

It checks if the current _sent_ node is a call of some of the Minitest
global matchers (`must_be_empty`, `must_equal`, `must_be_close_to`,
`must_be_within_delta`...)

```ruby
return unless global_expectation?(node)
```

Then if the check is successful and it's a deprecated method, then the
_cop_ registers an _offense_:

```ruby
add_offense(node, location: node.receiver.source_range, message: message)
```

The method `global_expectation?` is pretty interesting. It's defined in
unusual way with a `def_node_matcher` marco:

```ruby
def_node_matcher :global_expectation?, <<~PATTERN
  (send {
    (send _ _)
    ({lvar ivar cvar gvar} _)
    (send {(send _ _) ({lvar ivar cvar gvar} _)} _ _)
  } {#{MATCHERS_STR}} ...)
PATTERN
```

The `def_node_matcher` method call generates a new method
`global_expectation?` that matches a node to the specified pattern.
There is a custom pattern matching mechanism in Rubocop, similar to
regular expressions, that works with AST nodes.

The pattern has the following structure:

```
(send <receiver> <method name> <arguments>)
```

The _receiver_'s part in the pattern is:

```
{
  (send _ _)
  ({lvar ivar cvar gvar} _)
  (send {(send _ _) ({lvar ivar cvar gvar} _)} _ _)
}
```

`{}` means logical _OR_ that's a _receiver_ is either a method call without
arguments (`send _ _`) or a local/instance/class variable (`{lvar ivar cvar gvar}`)
or a method call chain (`send {(send _ _) ({lvar ivar cvar gvar} _)} _ _`).

A part for a method name is the following:

```
{#{MATCHERS_STR}}
```

The `MATCHERS_STR` Ruby constant is a list of deprecated Minitest
matchers separated with whitespaces - `:must_be_empty`, `:must_equal`,
`:must_be_close_to`... So the subpattern is evaluated into:

```
{:must_be_empty :must_equal :must_be_close_to ...}
```

Method arguments should match a subpattern `...`, that means any
sequence of nodes or no nodes at all.


### So what was wrong?

The mentioned above pattern for _receiver_ is too strict and doesn't
handle some valid cases. For example it doesn't match the following
expressions (from the open source project that I mentioned above):

```ruby
response[1]['X-Runtime'].must_match /[\d\.]+/

::File.read(::File.join(@def_disk_cache, 'path', 'to', 'blah.html')).must_equal @def_value.first

Rack::Contrib.must_respond_to(:release)
```

Let's look at the last expression:

```ruby
Rack::Contrib.must_respond_to(:release)
```

Its AST looks like the following one:

```
(send
  (const
    (const nil :Rack) :Contrib)
  :must_respond_to
  (sym :release))
```

A _receiver_ `(const (const nil :Rack) :Contrib)` in no way matches the
corresponding subpattern - it is neither a method call nor a variable nor a
method call chain.


### Solution

Solution is relatively simple. The simplest and generic pattern works
well enough:

```
(send !(send nil? :_ _) {#{MATCHERS_STR}} ...)
```

It checks if a global matcher is called and it isn't the new DSL (that's
not in format of `_(musts).must_equal expected_musts`).

Of course there are some additional complications, e.g. some matchers
are used with a block:


A matcher without block:
```ruby
obj.foo.must_equal :bar
```

A matcher with block:
```ruby
-> { obj.foo }.must_raise ArgumentError
```

In both cases AST looks very different:

```
(send
  (send
    (send nil :obj) :foo) :must_equal
  (sym :bar))
```

and

```
(send
  (block
    (lambda)
    (args)
    (send
      (send nil :obj) :foo)) :must_raise
  (const nil :ArgumentError))
```

so we need two different patterns.

In the new DSL a checked expression is wrapped into a `#_` method call
(e.g. `_(obj)`). But Minitest also supports aliases - `#value` and
`#expect`, that may make tests more readable:

```ruby
_(obj.foo).must_equal :bar
value(obj.foo).must_equal :bar
expect(obj.foo).must_equal :bar
```

That's why the final solution is slightly longer:

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


### AST patterns

Let's talk about Rubocop's patterns mechanism. The Rubocop documentation
recommends using patterns instead of direct nodes manipulation.
Patterns are implemented in a `NodePattern` class
([source](https://github.com/rubocop-hq/rubocop-ast/blob/master/lib/rubocop/ast/node_pattern.rb)),
that was recently moved out into a separate _gem_ `rubocop-ast`.

There are two official sources of information about patterns that I've found:
- <https://www.rubydoc.info/gems/rubocop-ast/0.0.3/RuboCop/AST/NodePattern>
- <https://github.com/rubocop-hq/rubocop-ast/blob/1899234a41c399aa9a445b9bb44716815fda5559/docs/modules/ROOT/pages/node_pattern.adoc>

There are very few examples so I had been blundering around in the dark
and experimenting to build the new pattern. After digging into the
documentation and source code I sketched the following Ruby script to
check if a new version of the pattern matches some source code:

```ruby
require 'rubocop'

source = "-> { obj.foo }.must_raise ArgumentError"
pattern = '(send _ :must_raise _)'

processed_source = RuboCop::AST::ProcessedSource.new(source, 2.7)
node_pattern = RuboCop::NodePattern.new(pattern)
node_pattern.match(processed_source.ast) # => true | nil
```

We parse Ruby source code with `RuboCop::AST::ProcessedSource` class and
call `#ast` method to get resulting AST nodes. Then we instantiate a
pattern with `RuboCop::NodePattern` class and call method `match` that
returns `true` or `nil`.


### Final words

The bug was fixed and [my
PR](https://github.com/rubocop-hq/rubocop-minitest/pull/72) was merged.
Even though it isn't the main Rubocop repository, but an official
plugin, it's a small win for me.

Despite getting familiar with Rubocop source code, I still haven't tried
to manipulate nodes manually without patterns. There are open questions
about node types and order of iterating over AST nodes. It isn't
described in the documentation and Rebocop heavily relies on a `parser`
_gem_


### Posts about developing new _cops_:

- <https://downey.io/blog/writing-rubocop-linters-for-database-migrations/>
- <https://mwallba.io/custom-rubocops-to-support-code-reviews/>
- <https://blog.sideci.com/overview-and-implementation-of-performance-regexpmatch-cop-afe58d2c5ed3>
- <https://medium.com/@DmytroVasin/how-to-add-a-custom-cop-to-rubocop-47abf82f820a>
- <https://kirshatrov.com/2016/12/18/rewrite-code-with-rubocop/>

### Links

- <https://docs.rubocop.org/rubocop/0.85/development.html>
- <https://www.rubydoc.info/gems/rubocop-ast/0.0.3/RuboCop/AST/NodePattern>
- <https://github.com/rubocop-hq/rubocop-ast/blob/1899234a41c399aa9a445b9bb44716815fda5559/docs/modules/ROOT/pages/node_pattern.adoc>
- <https://github.com/whitequark/parser/blob/master/doc/AST_FORMAT.md>


[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
