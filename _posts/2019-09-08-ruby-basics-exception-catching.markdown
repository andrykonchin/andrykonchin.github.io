---
layout:     post
title:      "Ликбез по исключениям в Ruby"
date:       2019-09-08 20:03
categories: Ruby
---

Механизм исключений в Ruby мало чем отличается от реализаций в других
распространенных ООП языках, таких как C++ и Java. Но динамическая природа
Ruby вносит свои коррективы расширяя стандартные возможности. Механизм
исключений Ruby хорошо описан не только в документации, но и в
многочисленных детальных статьях. И, как всегда, здесь найдутся свои
тонкости и нюансы, которые могут вас удивить.

Итак, что мы  обычно используем на практике?

Оператор `rescue`. Именно он нужен для перехвата и обработки исключений.
Синтаксис всем хорошо известен:

```ruby
begin
  # code which raises exception
rescue RuntimeError => e
  # code to handle exception
end
```

Оператор `ensure`. Его можно увидеть в коде проектов лишь изредка.
Определенный в этом операторе код всегда вызывается **после** основного
блока даже если брошенное исключение **не перехвачено**. Здесь обычно
освобождают ресурсы, закрывают файлы итд

```ruby
begin
  @file = File.open('foo.txt', 'w')
  raise
ensure
  @file.close
end
```

Операторы `retry`/`redo`. Практически ни разу не видел, чтобы их
использовали вместе с `rescue`. Они работают только в `begin`/`end` и
`do`/`end` блоках соответственно. Вызов такого оператора означает
повторное выполнение всего внешнего блока:

```ruby
begin
  # ...
rescue
  # do something that may change the result of the begin block
  retry
end
```

Если думаете, что этим все и ограничивается, то вы не правы. Давайте
начнем.

### Оператор else

Думаю, мало кто видел оператор `else` в связке с `rescue` и тем более
использовал его. Тем не менее, в блоке можно задавать `else` секцию,
которая выполняется после основного блока **только если не было
исключения**. Таким образом, операторы `rescue` и `else` как бы
дополняют друг друга. Следовательно, полный синтаксис `begin`/`end` (как
и `do`/`end`) блока выглядит так:

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

До Ruby 2.6 можно было использовать `else` без секции `rescue`. Сейчас
это приводит к ошибке синтаксиса:

```ruby
begin
else
end
# SyntaxError ((irb):3: else without rescue is useless)
```

Если определены все секции в блоке (`rescue`, `else` и `ensure`),
то они выполняются в следующем порядке:

* `begin`/`end` блок
* `else`
* `ensure`

Если произошло исключение, то порядок следующий:

* `begin`/`end` блок
* `rescue`
* `ensure`

### `do`/`end` блок

Долго время операторы `rescue`/`ensure`/`else` можно было использовать
только внутри метода и `begin`/`end` блока. Начиная с Ruby 2.5 их можно
использовать также и в `do`/`end` блоке:

```ruby
['1', 'a'].map do |s|
  Integer(s)
rescue
  0
end
```

Но все еще нельзя использовать в блоке с `{}`

```ruby
['1', 'a'].map { |s|
  Integer(s)
rescue
}
# SyntaxError (syntax error, unexpected rescue, expecting '}')
```

### Список классов-исключений

Оператор `rescue` может перехватывать исключения сразу нескольких
классов:

```ruby
begin
  raise
rescue ArgumentError, RuntimeError
end
```

Тонкость в том, что такой список классов - это обычное выражение,
результатом которого является список:

```ruby
begin
  raise
rescue *[StandardError]
  puts $!.class
end
```

Более того, этот список может быть **динамическим** и зависеть от контекста:

```ruby
exception_list = [StandardError]
begin
  raise
rescue *exception_list
  puts $!.class
end
```

Есть еще одна особенность. Это выражение вычисляется **лениво** и только
если действительно было брошено исключение. Например, следующий код не
приводит к исключению, хотя в нем и вызывается метод `raise`:

```ruby
begin
rescue *[(raise), StandardError]
  puts $!.class
end
```

В `begin`/`end` блоке исключение не бросается, поэтому список классов в
`rescue` не вычисляется и метод `raise` не вызывается.

Согласно документации можно перехватывать исключение указывая его класс.
Но оказывается, можно указывать **любой** класс или модуль, а не только
класс-исключение (производный от класса `Exception`):

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

Если попытаться указать что-то отличное от класса или модуля, то получим
исключение `TypeError - class or module required for rescue clause`.

Не имеет особого смысла задавать класс, который не наследует от
`Exception` или его подклассы, ведь "бросать" можно только экземпляры
класса `Exception` или его подклассов. Иначе получим ошибку `TypeError
(exception class/object expected)`.

Но.

На самом деле смысл есть и это можно использовать с пользой.

Под капотом `rescue` проверяет соответствует ли объект-исключение классу
из списка `rescue` и использует для этого метод `===`. Поэтому можно
использовать класс **не производный** от класса `Exception` и определить
любое правило для сравнения с объектом-исключением:

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

В этом примере класс `Rescuer` не наследует класс `Exception`, но все же
может перехватывает исключение. В данном случае `===` всегда возвращает
`true`, поэтому будут перехватываться все исключения.

Как писали выше, бросать можно только объекты-исключения - т.е. в
метод `raise` можно передавать только экземпляры класса-исключения. Но
это не совсем верно. (Правда, можно передать аргументом просто класс
исключения или строчку-сообщение, но мы не рассматриваем эти вырожденные
случаи).

На самом деле Ruby может **сконвертировать** аргумент в экземпляр
класса-исключения. Для этого Ruby пробует вызвать на аргументе метод
`exception`. Возвращаемое значение должно быть экземпляром
класса-исключения:

```ruby
obj = Object.new

def obj.exception
  RuntimeError.new("Internal error")
end

raise obj
# RuntimeError (Internal error)
```

Из интереса можно заглянуть в реализацию метода `raise` в Rubinius
([source](https://github.com/rubinius/rubinius/blob/v4.6/core/zed.rb#L1454))

### Возвращаемое значение

Думаю, многие наступали на эти грабли и знают, что `rescue` влияет на
возвращаемое из метода/блока значение. Если произошло исключение, то
вернется результат последнего выражения из секции `rescue`.

```ruby
def foo
  1/0
rescue
  Float::INFINITY
end

foo
# => Infinity
```

### Применение в классах и модулях

Сложно представить когда это может пригодиться, но с помощью `rescue`
можно перехватывать исключения в декларации класса или модуля:

```ruby
class A
  raise
rescue
  puts "from rescue"
end
# from class A
```

### ensure и явный return

Интересно поиграться с явным `return` в секции `ensure`. Как мы знаем,
секция `ensure` не влияет на возвращаемое значение блока/метода. Но
явный `return` все меняет.

Во-первых, `return` перетирает возвращаемое из метода (или блока)
значение:

```ruby
def foo
  return 'from foo'
ensure
  return 'from ensure'
end

foo
# => "from ensure"
```

Во-вторых, если произошло исключение и оно было перехвачено, то `return`
перетирает значение, которое возвращалось из секции `rescue`:

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
И напоследок самое интересное. Если было брошено исключение, то явный
`return` в `ensure` его просто проглатывает.

```ruby
def foo
  raise
ensure
  return 'from ensure'
end

foo
# => "from ensure"
```

То же самое происходит, если исключение было брошено и в секции
`rescue`:

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

### Заключение

Уверен, что здесь перечислены не все особенности перехвата исключений. С
большинством из них я познакомился просматривая тесты в проекте
[RubySpec](https://github.com/ruby/spec). Кстати, настоятельно
рекомендую его как хорошую (но не исчерпывающую) спецификацию Ruby.

### Полезные ссылки

* [https://ruby-doc.org/core-2.5.3/doc/syntax/exceptions_rdoc.html](https://ruby-doc.org/core-2.5.3/doc/syntax/exceptions_rdoc.html)
* [https://ruby-doc.org/core-2.5.3/Exception.html](https://ruby-doc.org/core-2.5.3/Exception.html)
* [https://github.com/ruby/spec/blob/master/language/rescue_spec.rb](https://github.com/ruby/spec/blob/master/language/rescue_spec.rb)
* [Weird Ruby Part 2: Exceptional Ensurance](https://blog.newrelic.com/engineering/weird-ruby-2-rescue-interrupt-ensure)
* [Advanced Rescue & Raise](https://www.exceptionalcreatures.com/guides/advanced-rescue-and-raise.html#raising-non-exceptions)

[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
