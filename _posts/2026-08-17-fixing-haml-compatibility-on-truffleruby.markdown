---
layout: post
title:  "Fixing Haml Compatibility on TruffleRuby: A Parser Tale"
date:   2026-08-17 22:21:12
categories: Ruby
---

Recently, while working on improving TruffleRuby compatibility with popular Ruby gems, I looked into an issue with the `haml` gem. Haml's unit tests were failing on CI when running on TruffleRuby. And by failing, I mean about half of all tests failed. In other words, the gem was practically unusable on TruffleRuby. Let's dive into the details: what caused the bug, how to fix it, and a neat parsing trick used by the Haml authors.

As I mentioned, about half of the test suite (162 out of 370 tests) failed on TruffleRuby, all with the exact same error: `Haml::SyntaxError: Unbalanced brackets`.

```
315) Error:
Haml::Engine::old attributes::html escape#test_0001_escapes attribute values on static attributes:
Haml::SyntaxError: Unbalanced brackets.
    (__TEMPLATE__):2:in 'Tilt::CompiledTemplates#__tilt_46344'
    <internal:core> core/unbound_method.rb:19:in 'UnboundMethod#bind_call'
    vendor/bundle/truffleruby/34.0.1.1/gems/tilt-2.8.0/lib/tilt/template.rb:394:in 'Tilt::Template#evaluate_method'
    vendor/bundle/truffleruby/34.0.1.1/gems/tilt-2.8.0/lib/tilt/template.rb:266:in 'Tilt::Template#evaluate'
    vendor/bundle/truffleruby/34.0.1.1/gems/tilt-2.8.0/lib/tilt/template.rb:134:in 'Tilt::Template#render'
    test/test_helper.rb:40:in 'RenderHelper#render_haml'
    test/test_helper.rb:33:in 'RenderHelper#assert_render'
    test/haml/engine/old_attribute_test.rb:339:in 'test_0001_escapes attribute values on static attributes'
```


## Finding the Culprit

All clues pointed to the `Haml::Parser#balance_tokens` method - the only place where `Haml::SyntaxError` with the message "Unbalanced brackets" was raised. However, looking at the backtrace, the error originated inside a compiled template, and there was not a single line referencing the `haml` gem directly.

Why? Haml catches parser errors during compilation and turns them into embedded Ruby `raise` statements within the compiled template so they are only raised when the template is rendered at runtime.

Fair enough. Now we just needed to figure out what `Haml::Parser#balance_tokens` actually does and why it was breaking on TruffleRuby.


## Digging Deeper

This logic handles parsing Haml templates, specifically HTML tag attributes. In Haml, you can specify tag attributes like this:

```
%input{:selected => true}
```

Which compiles to the following HTML:

```
<input selected='selected'>
```

Attributes are written as a Hash-like expression: `{:selected => true}`. `Haml::Parser#balance_tokens` is used to find where this Hash-like expression ends. In general, tag attributes can be followed by static text that needs to be stripped out. For example, in:

```
%a{:title => @title, :href => href} Stuff
```

The parser needs to strip the tag name `"%a"` and the suffix `" Stuff"`, returning only `{:title => @title, :href => href}`.


## How It's Implemented

Let's look at the code to see how this works under the hood. The main method for extracting attributes is `#parse_old_attributes`. It's called "old" because Haml also supports a newer HTML-style attribute syntax (e.g., `%a(title=@title href=href) Stuff`) - see the [Haml Reference](https://haml.info/docs/yardoc/file.REFERENCE.html).

```ruby
    # Used for scanning old attributes, substituting the first '{'
    METHOD_CALL_PREFIX = 'a('

    def parse_old_attributes(text)
      # ...
      balanced, rest = balance_tokens(text.sub(?{, METHOD_CALL_PREFIX), :on_embexpr_beg, :on_embexpr_end, count: 1)
      attributes_hash = balanced.sub(METHOD_CALL_PREFIX, ?{)
      # ...
      return attributes_hash, rest, last_line
    end
```
[Haml parser.rb](https://github.com/haml/haml/blob/97a48651b8b8c2507096c1243d5f12abcb8e007b/lib/haml/parser.rb#L679-L705)

Essentially, it calls `#balance_tokens`, attempts to recover if a `SyntaxError` occurs, and returns the result. Now let's inspect `#balance_tokens`:

```ruby
def balance_tokens(buf, start, finish, count: 0)
  text = ''.dup
  Ripper.lex(buf).each do |_, token, str|
    text << str
    case token
    when start
      count += 1
    when finish
      count -= 1
    end

    if count == 0
      return text, buf.sub(text, '')
    end
  end
  raise SyntaxError.new(Error.message(:unbalanced_brackets))
end
```
[Haml parser.rb](https://github.com/haml/haml/blob/97a48651b8b8c2507096c1243d5f12abcb8e007b/lib/haml/parser.rb#L849-L865)

Here is how the algorithm works:
- replace the opening `{` with `a(`
- lex the string using `Ripper.lex` to get a token stream
- count the balance between opening and closing tokens (`{` and `}`)
- once an unmatched `}` is encountered, treat it as the end of the attributes and return the slice up to that character

For anyone unfamiliar with Ripper: it's Ruby's built-in parser API. Basically, it's what parses your Ruby code (or did, before Ruby 3.4 moved to Prism). It works out of the box and is 100% compliant with standard Ruby syntax. `Ripper.lex` tokenizes Ruby code into tokens (numbers, identifiers, operators, whitespace, etc.) which are normally used to build the AST.

Let's walk through an example. Suppose we have the attribute expression `"{:selected => true}"`. After replacing `{` with `a(`, we get `"a(:selected => true}"`. Lexing this with `Ripper.lex` yields:

```ruby
require 'ripper'

s = "a(:selected => true}"
Ripper.lex(s)

[[[1, 0], :on_ident, "a", CMDARG],
 [[1, 1], :on_lparen, "(", BEG|LABEL],
 [[1, 2], :on_symbeg, ":", FNAME],
 [[1, 3], :on_ident, "selected", ENDFN],
 [[1, 11], :on_sp, " ", END],
 [[1, 12], :on_op, "=>", BEG],
 [[1, 14], :on_sp, " ", BEG],
 [[1, 15], :on_kw, "true", END],
 [[1, 19], :on_embexpr_end, "}", END]]
```

When reaching the final `:on_embexpr_end` token, `count` (which started at `1`) is decremented by 1 to `0`. That triggers the exit condition: we found the matching closing `}`.

Everything seems straightforward. So what goes wrong on TruffleRuby?


## What's Happening in TruffleRuby?

Some time ago, TruffleRuby switched from MRI's Ripper native extension to a compatibility layer based on the new Prism parser. To ease the migration from Ripper to Prism, the `prism` gem includes the `Prism::Translation::Ripper` class, which emulates the Ripper interface. TruffleRuby uses this translation layer under the hood. So when Haml calls `Ripper.lex`, it is actually calling `Prism::Translation::Ripper.lex`. That means our issue lies somewhere in Prism.

Let's check how `Prism::Translation::Ripper.lex` tokenizes the same input:

```ruby
require 'prism'

s = "a(:selected => true}"
Prism::Translation::Ripper.lex(s)

[[[1, 0], :on_ident, "a", CMDARG],
 [[1, 1], :on_lparen, "(", BEG|LABEL],
 [[1, 2], :on_symbeg, ":", FNAME],
 [[1, 3], :on_ident, "selected", ENDFN],
 [[1, 11], :on_sp, " ", ENDFN],
 [[1, 12], :on_op, "=>", BEG],
 [[1, 14], :on_sp, " ", BEG],
 [[1, 15], :on_kw, "true", END],
 [[1, 19], :on_rbrace, "}", END]]
```

Notice the difference? The last token in standard Ripper is `:on_embexpr_end`, but Prism returns `:on_rbrace`. And Haml's bracket balancing logic was specifically looking for `:on_embexpr_end`.

The problem is clear. Next step: fix `Prism::Translation::Ripper.lex` in Prism.


## A Closer Look at Ripper

Let's look at Ripper itself before fixing Prism.

Curiously, Ripper uses different tokens for `{` and `}` depending on the syntactic context:
- Hash literals
- Blocks
- Lambda literals (`-> {}`)
- String interpolation

Moreover, Ripper reuses the same tokens for closing `}` while introducing distinct tokens for opening `{`. It produces `:on_lbrace`, `:on_tlambeg`, and `:on_embexpr_beg` for opening braces (in hashes/blocks, lambdas, and string interpolations, respectively), and `:on_rbrace` or `:on_embexpr_end` for closing braces.

After digging into Ripper internals, it turned out that Ripper intentionally emits `embexpr_end` when encountering invalid Ruby code with unbalanced `{` and `}`. For some reason, it defaults to assuming string interpolation (like `"#{42}"`). When Ripper encounters an unmatched `}`, it returns `tSTRING_DEND` (which maps to `embexpr_end`). It's a bit quirky, but when dealing with invalid Ruby code, a parser has to guess whether the author intended a block `{ |x| ... }`, a hash `{ a: 1 }`, or string interpolation `"#{ ... }"`. Returning either `embexpr_end` or `rbrace` are both plausible choices.

Here is the relevant code in Ruby's parser:

```c
case '}':
  /* tSTRING_DEND does COND_POP and CMDARG_POP in the yacc's rule */
  if (!p->lex.brace_nest--) return tSTRING_DEND;
  COND_POP();
  CMDARG_POP();
  SET_LEX_STATE(EXPR_END);
  p->lex.paren_nest--;
  return c;
```
[Ruby parse.y](https://github.com/ruby/ruby/blob/03b6d3f8898a28604fe6cb00eae3226b821168f4/parse.y#L11006-L11013)

Here we see that the parser tracks nesting levels for parentheses, brackets, and braces (`p->lex.paren_nest`), as well as a separate counter specifically for brace nesting (`p->lex.brace_nest`). When a `}` is encountered but the brace counter is already `0` (meaning there was no corresponding opening `{`), `tSTRING_DEND` is returned to handle this invalid Ruby syntax, which Ripper maps to `:on_embexpr_end` (see [`eventids2.c`](https://github.com/ruby/ruby/blob/03b6d3f8898a28604fe6cb00eae3226b821168f4/ext/ripper/eventids2.c#L265)).

Interestingly, I even found a test in Ruby's own test suite that explicitly references Haml regarding this behavior:
```ruby
def test_trailing_on_embexpr_end
  # This is useful for scanning a template engine literal `{ foo, bar: baz }`
  # whose body inside brackes works like trailing method arguments, like Haml.
  token = Ripper.lex("a( foo, bar: baz }").last
  assert_equal [[1, 17], :on_embexpr_end, "}", state(:EXPR_ARG)], token
end
```

## Fixing `Prism::Translation::Ripper.lex`

So I prepared a patch for `Prism::Translation::Ripper.lex` to mirror Ripper's behavior by returning `embexpr_end` instead of `rbrace` on unmatched braces.

The fix was ready quickly: [ruby/prism#4164](https://github.com/ruby/prism/pull/4164). I was looking forward to getting it merged and solving the issue across Prism, Haml, and TruffleRuby. However, the Prism maintainers weren't keen on the change. It turned out this was a known discrepancy, and Prism didn't want to replicate what they considered an illogical quirk in Ripper. So my PR was closed. They pointed out that Haml was already trying to fix this on their side with an open pull request ([haml/haml#1210](https://github.com/haml/haml/pull/1210)).

A bit disappointed, I checked out that PR in Haml. The situation didn't look great: the PR had been waiting for review for over a month. When we finally pinged the Haml maintainer, he mentioned that while he was open to fixing TruffleRuby compatibility, he didn't like the approach taken in that specific PR and suggested redesigning it.

"Great," I thought, "the PR author will update it soon, and the issue will be resolved." But the author didn't respond - not the next day, nor a week later. Seeing that the PR had stalled, I decided to pick it up and rework the fix myself in a new PR.


## Fixing Haml

The original proposed fix counted `{` and `}` manually without using the `a(` substitution trick - assuming the attributes string was simply a valid Ruby Hash. It parsed the code using `Ripper.lex` and looked for a closing `}`, whether it was `embexpr_end` or `rbrace`. Sounds logical, right?

The catch is that the `a(` trick was actually necessary. Haml syntax allows embedding an existing Hash variable directly into the attribute list, merging it with explicit key-value pairs at runtime:

```
%a{ hash, foo: bar }
```

The expression `{ hash, foo: bar }` is not a valid Ruby Hash literal - it's invalid Ruby syntax. How a parser (Ripper or Prism) handles invalid syntax is undefined.

The `a(` trick turns `{ hash, foo: bar }` into `a( hash, foo: bar }`. This looks like a standard method call where a `)` was accidentally replaced by a `}`, making the parsing behavior much more predictable.

So I took the token-counting approach, restored the `a(` prefix trick, and expanded the list of matched tokens for opening and closing braces. And, of course, added missing tests.

```diff
-        balanced, rest = balance_tokens(text.sub(?{, METHOD_CALL_PREFIX), :on_embexpr_beg, :on_embexpr_end, count: 1)
+        balanced, rest = balance_tokens(
+          text.sub(?{, METHOD_CALL_PREFIX),
+          [:on_lbrace, :on_tlambeg, :on_embexpr_beg],
+          [:on_rbrace, :on_embexpr_end],
+          count: 1
+        )
```

How did this fix the TruffleRuby issue? The original Haml implementation relied specifically on Ripper's quirk of returning `:on_embexpr_end` for unmatched braces in invalid code. In the updated implementation, we look for closing braces matching either `:on_embexpr_end` or `:on_rbrace`.

The new PR ([haml/haml#1212](https://github.com/haml/haml/pull/1212)) was reviewed and merged quickly without any issues.


## P.S.

Shortly after my fix, Haml migrated its parser from Ripper to Prism directly ([haml/haml#1214](https://github.com/haml/haml/pull/1214)), which is great news! The core attribute-parsing logic remained unchanged, as Prism maps to equivalent token names:

```diff
         attributes_hash, rest = balance_tokens(
           text.sub(?{, METHOD_CALL_PREFIX),
-           [:on_lbrace, :on_tlambeg, :on_embexpr_beg],
-           [:on_rbrace, :on_embexpr_end],
+           [:BRACE_LEFT, :LAMBDA_BEGIN, :EMBEXPR_BEGIN],
+           [:BRACE_RIGHT, :EMBEXPR_END],
           count: 1)
```


## Pull Requests

- [ruby/prism#4164](https://github.com/ruby/prism/pull/4164) — Prism PR to mirror Ripper's behavior
- [haml/haml#1210](https://github.com/haml/haml/pull/1210) — Initial stalled Haml PR
- [haml/haml#1212](https://github.com/haml/haml/pull/1212) — The merged fix for TruffleRuby compatibility
- [haml/haml#1214](https://github.com/haml/haml/pull/1214) — Haml's migration from Ripper to Prism
