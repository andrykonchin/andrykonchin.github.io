---
layout:     post
title:      "Exceptions in Ruby Cheat Sheet"
date:       2019-09-08 20:03
categories: Ruby
---

Mechanizm of exceptions in Ruby is very similar to conunterparts in the
mainstream object oriented languages like C++ and Java. But dynamic
nature of Ruby brings flexibility and extra power into this well known
language feature. The mechanizm of exceptions in Ruby is wel described
not only in documentation but also in numerous actibles. But there are a
lot of tricky nuances that might astonish you.

So, how do we usually use exceptions? Let's recap the basics.

The `rescue` operator. It's the keyword we use to catch and handle
exceptions.

Its syntax is the following:

```ruby
begin
  # code which raises exception
rescue RuntimeError => e
  # code to handle exception
end
```

### The `ensure` operator.

It seems it's used less frequently in projects. Declared with this
operator source code section is called always **after** a main code
section even if an exception is raised and not handled. Usually it's
used to free resources, close files etc.

```ruby
begin
  @file = File.open('foo.txt', 'w')
  raise
ensure
  @file.close
end
```

### The `retry` operator.

I have never seem it in production Rails application and very very rary
in libraries. It could be used only inside the `rescue` code section and
it causes executoin of a main code section one more time:

```ruby
begin
  # ...
rescue
  # do something that may change the result of the begin block
  retry
end
```

### The `else` operator

I bet you have never used or even seen the `else` keyword together with
the `rescue` keyword. Nevertheless an _else_ branch specifies that will
be executed if no exception is raised. This way `rescue` and `else`
operators complement one another.

So far the full syntax of a code block (`begin`/`end` as well as
`do`/`end`) is the following:

```ruby
begin
  # ...
rescue
  # ...
else
  # this runs only when no exception was raised
ensure
  # ...
end
```

In case all the brenches are specified (`rescue`, `else` and `ensure`),
then they are executed in the following order:

* main `begin`/`end` code block
* `else`
* `ensure`

If an exception is raised - the order is the following:

* main `begin`/`end` code block
* `rescue`
* `ensure`

### Exceptions list to catch

Multiple exception classes can be specified in the `rescue` operator:

```ruby
begin
  raise
rescue ArgumentError, RuntimeError
end
```

There is a tiny nuance - in contrast to mainstream staticly typed
languages in Ruby the list of exception classes is an expression, not
statement or declaration, that evaluates in runtime. And consequently it
could be anything that returns a list:

```ruby
begin
  raise
rescue *[StandardError]
  puts $!.class
end
```

Moreover, this list could be _dynamic_ and depend on context:

```ruby
exception_list = [StandardError]

begin
  raise
rescue *exception_list
  puts $!.class
end
```

`exception_list` could be anything - a local variable, a constant or
even a method call.

One more nuance. This expression evaluates lazyly, that's only when an
exception is actually raised. For instance in the following example no
exception is raised, despite presence of the `raise` method call:

```ruby
begin
rescue *[(raise), StandardError]
  puts $!.class
end
```

In the `begin`/`end` block no exception is raised so the list of
exceptions isn't evaluated and the method `raise` isn't called.


### Exception class

According to the documentation an exception class should be specified to
rescue an exception. But actually **any** module or class are allowed,
not only subclass of `Exception` class:

```ruby
begin
  raise
rescue Integer
end
```

```ruby
begin
  raise
rescue Comparable
end
```

Specifying anything other than class or module leads to exception:
`TypeError - class or module required for rescue clause`.

It doesn't make sense to specify class that doesn't inherit `Exception`
class or its subclasses as far as the `raise` method accepts only
`Exception` subclasses. Othewise an exception will be raised -
`TypeError (exception class/object expected)`.

But.

Actually it might be useful.

Under the hood the `rescue` operator matches raised exception and
exception class using `#===` method defined on the exception class. And
it's only interface that is requied frim an exception class. That's why
any class or module could be used, even not `Exception` subclass, that
defines the `#===` method:

```ruby
Rescuer = Class.new do
  def self.===(exception)
    true
  end
end

begin
  raise
rescue Rescuer
end
```

In this example a `Rescuer` class doesn't inherit `Exception` class, but
still rescues exceptions. In this particular case the `#===` method
returns `true` unconditionally so all the exception will be rescued.


### Raised exception

As was mentioned above the method `raise` accepts only instance of
`Exception` subclasses. Actually it doesn't. Actually it can _convert_
its argument to an excepion if this argument responds to a method
`exception`. Returned value must be instance of `Exception` subclass:

```ruby
obj = Object.new

def obj.exception
  RuntimeError.new("Internal error")
end

raise obj
# RuntimeError (Internal error)
```

Out of curiocity you can look at the `Kernel#raise` method
implementation in Rubinius
([source](https://github.com/rubinius/rubinius/blob/v4.6/core/zed.rb#L1454))


### Returned value

It's well known that when exception is rescued then an outer block's or
method's returns a value returned from a `rescue` section:

```ruby
def foo
  1/0
rescue
  Float::INFINITY
end

foo
# => Infinity
```

### Using in classes and modules

It's hard to imagine when it might be useful, but `rescue` section could
be declared not only in a block or a method, but also in a class and
module body:

```ruby
class A
  raise
rescue
  puts "from rescue"
end

# from class A
```

### `ensure` and explicit `return`

It's interesting to play with explicit `return` within `ensure` section.
As we know `ensure` section doesn't affect a block or method returned
value.But explicit `return` makes a difference.

First of all it overrides returned value from a block or method:

```ruby
def foo
  return 'from foo'
ensure
  return 'from ensure'
end

foo
# => "from ensure"
```

Secondly, if an exception is raised and rescued, then explicit `return`
overrides value returned from a `rescue` section:

```ruby
def foo
  raise
rescue
  'from rescue'
ensure
  return 'from ensure'
end

foo
# => "from ensure"
```

The last one, the most surprising. If an exception is raised and there
is no `rescue` section then explicit `return` just swallows it and
hides:

```ruby
def foo
  raise
ensure
  return 'from ensure'
end

foo
# => "from ensure"
```

The same happens when a new exception is raised in a `rescue` section
itself:

```ruby
def foo
  raise
rescue
  raise
ensure
  return 'from ensure'
end

foo
# => "from ensure"
```

### PS

I am sure there are listed not all the tricks with raising and rescuing
exeptions. Most of them I've found looking through test cased in
[ruby/spec](https://github.com/ruby/spec) project. By the way, recommend
it as good (but not comprehensive) Ruby specification.

### Links

* [https://ruby-doc.org/core-2.5.3/doc/syntax/exceptions_rdoc.html](https://ruby-doc.org/core-2.5.3/doc/syntax/exceptions_rdoc.html)
* [https://ruby-doc.org/core-2.5.3/Exception.html](https://ruby-doc.org/core-2.5.3/Exception.html)
* [https://github.com/ruby/spec/blob/master/language/rescue_spec.rb](https://github.com/ruby/spec/blob/master/language/rescue_spec.rb)
* [Weird Ruby Part 2: Exceptional Ensurance](https://blog.newrelic.com/engineering/weird-ruby-2-rescue-interrupt-ensure)
* [Advanced Rescue & Raise](https://www.exceptionalcreatures.com/guides/advanced-rescue-and-raise.html#raising-non-exceptions)

[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
