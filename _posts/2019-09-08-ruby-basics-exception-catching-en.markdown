---
layout:     post
title:      "Exceptions in Ruby Cheat Sheet"
date:       2019-09-08 20:03
categories: Ruby
---

The mechanism of exceptions in Ruby closely resembles that of mainstream object-oriented languages like C++ and Java. However, thanks to Ruby's dynamic nature, it introduces a level of flexibility and additional power to this familiar language feature. While the documentation and numerous articles do provide a good description of Ruby's exception handling, there are still various tricky nuances that may surprise you.

Considering our typical usage of exceptions, let's take a moment to review the basics.

### Basics

#### The `rescue` operator

This keyword is utilized to catch and manage exceptions. The syntax is as follows:

```ruby
begin
  # code which raises exception
rescue RuntimeError => e
  # code to handle exception
end
```

#### The `ensure` operator

This operator seems to see less usage in projects. When utilized, the source code section following it is executed **regardless** of whether an exception is raised and handled. Its primary purpose is often freeing resources, closing files, and other cleanup tasks.

```ruby
begin
  @file = File.open('foo.txt', 'w')
  raise
ensure
  @file.close
end
```

#### The `retry` operator.

It is a rarity to find this operator in production Rails applications and libraries. Limited to the `rescue` code section, it serves the unique purpose of re-executing the main code section:

```ruby
begin
  # ...
rescue
  # do something that may change the result of the begin block
  retry
end
```

#### The `else` operator

It's quite possible that you've never utilized or encountered the `else` keyword in combination with `rescue`. Nevertheless, the _else_ branch is designed to execute only when no exception is raised. By doing so, the `rescue` and `else` operators complement each other seamlessly.

#### Summing it up


Now, let's take a look at the comprehensive syntax for a code block, incorporating both `begin`/`end` and `do`/`end` constructs:

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

If all the branches are specified (`rescue`, `else`, and `ensure`), they are executed in the following order:

* main `begin`/`end` code block
* `else`
* `ensure`

In the event of an exception being raised, the specified order of execution is as follows:

* main `begin`/`end` code block
* `rescue`
* `ensure`

### Exceptions list to catch

Within the `rescue` operator, it is possible to specify multiple exception classes:

```ruby
begin
  raise
rescue ArgumentError, RuntimeError
end
```

There is a subtle nuance - unlike mainstream statically typed languages, in Ruby, the list of exception classes is an expression that evaluates at runtime, rather than a static statement or declaration. As a result, it can encompass anything that returns a list:

```ruby
begin
  raise
rescue *[StandardError]
  puts $!.class
end
```

Additionally, it's worth noting that this list can be _dynamic_ and context-dependent:

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

Another important nuance is that this expression evaluates lazily, meaning it occurs only when an exception is actually raised. For instance, in the following example, no exception is raised, despite the presence of the `raise` method call:

```ruby
begin
rescue *[(raise), StandardError]
  puts $!.class
end
```

Since no exception is raised within the `begin`/`end` block, the list of exceptions remains unevaluated, and the `raise` method is not invoked.

### Exception class

Although the documentation states that an exception class should be used for exception rescue, it's essential to note that **any** module or class can be employed, not restricted solely to subclasses of the `Exception` class:

```ruby
begin
  raise
rescue Integer
end

begin
  raise
rescue Comparable
end
```

If you try to specify anything other than a class or module, it will trigger a `TypeError` exception "class or module required for rescue clause".

Specifying a class that does not inherit from the `Exception` class or any of its subclasses doesn't serve any purpose, considering the `raise` method exclusively accepts `Exception` subclasses. Attempting to do so will result in a `TypeError` exception being raised - "exception class/object expected".

But.

Actually it might be useful.

Beneath the surface, the `rescue` operator performs exception matching by utilizing the `#===` method defined on the exception class. Remarkably, this method is the sole interface required from an exception class. As a result, developers have the freedom to use any class or module, regardless of its inheritance from `Exception`, as long as it offers a valid implementation of the `#===` method:

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

The `Rescuer` class in this example does not derive from the `Exception` class; nevertheless, it is capable of rescuing exceptions. The reason behind this lies in the `#===` method, which always returns `true`, causing the `Rescuer` to match any exception.


### Raised exception

Contrary to what was mentioned earlier, the `raise` method is not strictly limited to accepting only instances of `Exception` subclasses. Surprisingly, it can _convert_ its argument into an exception if the argument responds to a `#exception` method. However, it's important to note that the returned value from this method must still be an instance of an `Exception` subclass:

```ruby
obj = Object.new

def obj.exception
  RuntimeError.new("Internal error")
end

raise obj
# RuntimeError (Internal error)
```

Out of curiosity, you may explore the implementation of the `Kernel#raise` method in Rubinius
([source](https://github.com/rubinius/rubinius/blob/v4.6/core/zed.rb#L1454))


### Returned value

It is commonly known that when an exception is rescued, the return value of the outer block is determined by the value returned from the `rescue` section:


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

While it may seem unconventional, there are situations where declaring the `rescue` keyword could be useful, not just within a block or a method, but also within a class and module body:

```ruby
class A
  raise
rescue
  puts "from rescue"
end

# from class A
```

### `ensure` and explicit `return`

Exploring the use of explicit `return` statements within the `ensure` section can be intriguing. Typically, the `ensure` section does not impact the return value of a block or method. However, when an explicit `return` is utilized, it can lead to a notable difference.

Primarily, the explicit `return` within the `ensure` section takes precedence and overrides the returned value from a block or method:

```ruby
def foo
  return 'from foo'
ensure
  return 'from ensure'
end

foo
# => "from ensure"
```

Moreover, in scenarios where an exception is raised and subsequently rescued, the explicit `return` within the `ensure` section takes precedence over the value returned from the `rescue` section.

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

The final case is perhaps the most surprising. In the event of an exception being raised, and no `rescue` section is present, the explicit `return` statement simply swallows the exception and conceals its occurrence:

```ruby
def foo
  raise
ensure
  return 'from ensure'
end

foo
# => "from ensure"
```

Likewise, a similar outcome unfolds when a new exception is raised within a `rescue` section:

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

I am certain that the provided list does not cover all the intricacies associated with raising and rescuing exceptions. A significant number of these discoveries were made while exploring test cases within the [ruby/spec](https://github.com/ruby/spec) project. By the way, I enthusiastically recommend it as an excellent (though not all-encompassing) source for Ruby specifications.

### Links

* [https://ruby-doc.org/core-2.5.3/doc/syntax/exceptions_rdoc.html](https://ruby-doc.org/core-2.5.3/doc/syntax/exceptions_rdoc.html)
* [https://ruby-doc.org/core-2.5.3/Exception.html](https://ruby-doc.org/core-2.5.3/Exception.html)
* [https://github.com/ruby/spec/blob/master/language/rescue_spec.rb](https://github.com/ruby/spec/blob/master/language/rescue_spec.rb)
* [Weird Ruby Part 2: Exceptional Ensurance](https://blog.newrelic.com/engineering/weird-ruby-2-rescue-interrupt-ensure)
* [Advanced Rescue & Raise](https://www.exceptionalcreatures.com/guides/advanced-rescue-and-raise.html#raising-non-exceptions)

[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
