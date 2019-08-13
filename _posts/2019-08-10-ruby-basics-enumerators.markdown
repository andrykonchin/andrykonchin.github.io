---
layout:     post
title:      "Ликбез по Enumerator"
date:       2019-08-10 20:04
categories: Ruby
---

В очередной раз обнаружил пробел в своих знаниях Ruby и пришлось срочно
его заполнить. На этот раз объект изучения это класс `Enumerator`.

Все это описано в документации и отличных статьях поэтому повторять за
ними глупо. Но есть определенный смысл в кратком и сжатом изложении с
акцентами на нюансах и тонкостях.


### Класс Enumerator

`Enumerator` это объект для итерации по другому объекту-коллекции. Он
подмешивает модуль `Enumerable` (т.е. с ним можно работать как с
коллекцией) и в то же время является внешним итератором.

Вот так _Matz_ точно и емко описывает его в своей книге:

> Enumerator objects are Enumerable objects with an each method that is based on some other iterator method of some other object.
>
> The Ruby programming language. Matz

Enumerator можно использовать:
  - как внутренний итератор,
  - как внешний итератор,
  - для создания псевдо-коллекции

Каждый элемент псевдо-коллекции будет вычисляться при первом обращении к
нему. Такая псевдо-коллекция является ленивой и может быть бесконечной.


### Создание enumerator'а

Создать `Enumerator` из `Enumerable` очень легко. Надо просто вызвать метод
`to_enum` (`Object#to_enum`). И поскольку `Enumerator` подмешивает модуль
`Enumerable`, нам доступны все его методы:

```ruby
enum = [1, 2, 3].to_enum
=> #<Enumerator: [1, 2, 3]:each>

enum.map { |n| n * 2 }
=> [2, 4, 6]
```

По умолчанию `Enumerator` обходит коллекцию используя метод `each`, но
можно использовать и другие методы. Например, можно создать
_enumerator_ для обхода коллекции в обратном порядке используя метод
`reverse_each`:

```ruby
enum = [1, 2, 3].to_enum(:reverse_each)
=> #<Enumerator: [1, 2, 3]:reverse_each>

enum.map { |n| n * 2 }
=> [6, 4, 2]
```
Или, например, можно обойти не элементы самой коллекции, а пройтись по
подмассивам сгенерированными методом `each_cons`:

```ruby
enum = [1, 2, 3, 4, 5].to_enum(:each_cons, 2)
=> #<Enumerator: [1, 2, 3, 4, 5]:each_cons(2)>

enum.take(3)
=> [[1, 2], [2, 3], [3, 4]]
```

В последнем примере раскрывается идея `Enumerator`'а - имея объект (не
обязательно `Enumerable`) и метод для итерации (`each_cons`) можно
создать `Enumerable`, вычислимый и эфемерный. Ведь на самом деле
никакого массива пар `[[1, 2], ...]` не существует - каждый элемент
последовательности вычисляется на лету в методе `each_cons`.

`Enumerable` и `Enumerator` очень тесно связаны. Многие методы модуля
`Enumerable`, вызванные без блока, возвращают _enumerator_. Например,
вызов `reverse_each` без блока:

```ruby
['a', 'b', 'c', 'd', 'e'].reverse_each
=> #<Enumerator: ["a", "b", "c", "d", "e"]:reverse_each>
```

### Внешние и внутреннии итераторы

Остановимся на концепции итераторов подробнее.

`Enumerator` реализует свой метод `each`, а в `Enumerable` есть
производные от `each` методы `cycle`, `each_entry`, `each_with_index`,
`each_with_index` и `reverse_each`. Они позволяют обойти коллекцию и
обработать ее элементы. Это можно назвать внутренним итератором. Ведь
контроль за итерациями остается у коллекции и клиент не управляет
порядком обхода и не выбирает момент, когда обработать очередной
элемент:

```ruby
(1..3).to_enum.reverse_each { |v| p v }
3
2
1
```

`Enumerator` также реализует методы `next`, `peek` и `rewind`, которые
позволяют пройтись по коллекции, но контроль остается у клиента. Поэтому
`Enumerator` можно назвать и внешним итератором.

```ruby
enum = [1, 2, 3].each
=> #<Enumerator: [1, 2, 3]:each>

loop do
  p enum.next
end
1
2
3
=> [1, 2, 3]
```

### Создание псевдо-коллекций

`Enumerator` помогает создать псевдо-коллекции - вычисляемые
последовательности элементов.

Можно рассмотреть такие коллекции на примере `Enumerable` и методов
`each_cons` и `each_slice`. Эти методы создают новую последовательность
на основе базовой коллекции и итерируют по ней. При этом
последовательность не материализуется в виде массива - она вычислима и
эфемерна.

Создать новую псевдо-последовательность можно вручную либо реализовав
метод аналогичный `each_cons` либо используя `Enumerator`.

Реализованный вручную метод должен принимать блок, генерировать
очередной элемент последовательности и передавать его как параметр в
блок. Для примера реализуем метод подобный `Integer#times`:

```ruby
def times(n)
  i = 0
  while i < n
    yield i
    i += 1
  end
end

times(3) { |i| puts i }
0
1
2

to_enum(:times, 5).to_a
=> [0, 1, 2]
```

Можно также посмотреть на реализацию метода `each_cons` в Rubinius
([source](https://github.com/rubinius/rubinius/blob/master/core/enumerable.rb#L485-L510))

Но что делать, если нет подходящего класса, в котором можно реализовать
такой метод? Посмотрим, как с этим нам поможет `Enumerator`:

```ruby
enum = Enumerator.new do |y|
  y << 1
  y << 'foo'
  y << ['bar']
end
=> #<Enumerator: #<Enumerator::Generator:0x00007fa6a806a030>:each>
```

`enum` теперь можно использовать точно так же как и обычный `Enumerable`
состоящий из трех элементов:

```ruby
enum.map { |a| a }
=> [1, "foo", ["bar"]]
```

Метод `to_enum`, который мы использовали ранее, это всего лишь короткая
запись для:

```ruby
enum = Enumerator.new(['a'], :each)
=> #<Enumerator: ["a"]:each>
```


### Бесконечные последовательности

Псевдо-коллекция может быть бесконечной. Давайте рассмотрим такие
коллекции на примере `Enumerable` и `Range`. Метод `Enumerable#cycle`
может обходить коллекцию по кругу бесконечно, а `Range` можно создать
бесконечным.

```ruby
[1, 2, 3].to_enum(:cycle).take(10)
=> [1, 2, 3, 1, 2, 3, 1, 2, 3, 1]

(1 .. nil).to_enum.take(10)
=> [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
```

Приведем, наверное, классический для `Enumerator`'а пример бесконечной
коллекции - числа Фибоначчи:

```ruby
fib = Enumerator.new do |y|
  a = b = 1
  loop do
    y << a
    a, b = b, a + b
  end
end
```

Теперь `fib` ничем не отличается от обычной ленивой бесконечной коллекции:

```ruby
fib.take(10)
=> [1, 1, 2, 3, 5, 8, 13, 21, 34, 55]
```


### Цепочки enumerator'ов


Поскольку `Enumerator` подмешивает `Enumerable`, а методы `Enumerable` могут
возвращать новые _enumerator_'ы, можно создавать целые цепочки
_enumerator_'ов. Иногда это оказывается очень полезным. Приведем примеры:

```ruby
array = ['a', 'b', 'c', 'd', 'e']
=> ["a", "b", "c", "d", "e"]

array.each.with_index.map { |name, i| name * i }
=> ["", "b", "cc", "ddd", "eeee"]

array.reverse_each.group_by.each_with_index { |item, i| i % 3 }
=> {0=>["e", "b"], 1=>["d", "a"], 2=>["c"]}
```

Если первый вызов (`each` и `reverse_each`) делается на массиве, то все
остальные методы `with_index`, `map`, `group_by` и `each_with_index`
вызываются уже на _enumerator_'е.

Рассмотрим первый пример с цепочкой:

```ruby
['a', 'b', 'c', 'd', 'e'].each.with_index.map { |name, i| name * i }
```

`each` возвращает _enumerator_, который итерирует по исходному массиву

```ruby
enum = ['a', 'b', 'c', 'd', 'e'].each
=> #<Enumerator: ["a", "b", "c", "d", "e"]:each>

enum.to_a
=> ["a", "b", "c", "d", "e"]
```

`each.with_index` тоже возвращает _enumerator_. Но он уже итерирует по
последовательности пар (элемент, индекс):

```ruby
enum = ['a', 'b', 'c', 'd', 'e'].each.with_index
=> #<Enumerator: #<Enumerator: ["a", "b", "c", "d", "e"]:each>:with_index>

enum.to_a
=> [["a", 0], ["b", 1], ["c", 2], ["d", 3], ["e", 4]]
```

И теперь все становится на свои места - вызывая `map` на этом _enumerator_'е
в блок будут передаваться пары (элемент, индекс):

```ruby
enum = ['a', 'b', 'c', 'd', 'e'].each.with_index
=> #<Enumerator: #<Enumerator: ["a", "b", "c", "d", "e"]:each>:with_index>

enum.map { |name, i| [name, i] }
=> [["a", 0], ["b", 1], ["c", 2], ["d", 3], ["e", 4]]
```


### Заключение

`Enumerator` может казаться незаметной и не очень полезной частью
стандартной библиотеки, но именно с его помощью можно получить:
* внешний итератор для коллекции
* ленивую коллекцию
* вычислимую псевдо-коллекцию
* бесконечную коллекцию

Более того, используя `Enumerator` можно легко и элегантно превратить
не-Enumerable сущность в _Enumerable_.

`Enumerator` является одновременно и внутренним итератором и внешним.

Так как `Enumerable` используется практически в любой Ruby-программе нам
нужно хорошо разбираться и в тесно связанным с ним `Enumerator`.


### Ссылки по теме:

* [The Enumerable module in Ruby: Part I](https://medium.com/rubycademy/the-enumerable-module-in-ruby-part-i-745d561cfebf)
* [The Enumerable module in Ruby: Part II](https://medium.com/rubycademy/the-enumerable-module-in-ruby-part-ii-41f69b36360)
* [Enumerator: Ruby's Versatile Iterator](https://blog.carbonfive.com/2012/10/02/enumerator-rubys-versatile-iterator/)
* [Stop including Enumerable, return Enumerator instead](https://blog.arkency.com/2014/01/ruby-to-enum-for-enumerator/)
* [Building Enumerable & Enumerator in Ruby](https://practicingruby.com/articles/building-enumerable-and-enumerator)

[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
