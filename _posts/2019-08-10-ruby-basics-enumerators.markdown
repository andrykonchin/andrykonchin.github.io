---
layout:     post
title:      "Ликбез по Enumerator"
date:       2019-08-10 20:04
categories: Ruby
---

Время стремительно бежит мимо просыпаясь песком сквозь пальцы и
насвистывая ветром в ушах. Переключаясь с одного окаменелого куска
легаси кода на другой совсем не замечаешь его течение. Не
замечаешь маленькие изменения, которые накапливаясь из года в год
выливаются в значительные сдвиги в языке и его идиомах.

Опять наблюдаю это на примере коллекций в Ruby (`Enumerable`/`Enumerator` из
стандартной библиотеки). Несмотря на то, что регулярно читаешь статьи и
блоги, следишь за Ruby _Release Notes_, понимание может устареть и
остаться на уровне Ruby 1.8. А с тех пор с `Enumerable` произошли очень
заметные изменения.

Все это описано в документации и многочисленных прекрасных статьях
поэтому повторять за ними глупо. Я постараюсь описать те нюансы, которые
могли ускользнуть от вашего внимания.

### Ruby без Enumerable

Давайте прочувствуем, насколько `Enumerable` важен и удобен. Представим,
что `Enumerable` внезапно пропал из Ruby, и попробуем решить простую
задачку используя обычные циклы.

Задачка следующая - надо отфильтровать из массива все положительные
числа. Решение может выглядеть так:

```ruby
positives = []
for i in [-5, 10, 0, 15, -2]
  positives << i if i.positive?
end
p positives
# => [10, 15]
```

Можно легко переделать это для других типов циклов - `while/do`, `until/do`
и базовый `loop`.

### Теперь добавим немного Enumerable

А теперь сделаем то же самое используя `Enumerable`:

```ruby
[-5, 10, 0, 15, -2].select(&:positive?)
# => [10, 15]
```

Получилось кратко выразительно и наглядно. От императивного подхода мы
перешли практически к декларативному.

В `Enumerable` реализовано очень много разнообразных операций над
коллекциями. Обычно в результате возвращается новая коллекция. Поэтому
легко получается создавать цепочки-конвейеры:

```ruby
(1 .. 100).select { |i| i.even? }.map { |i| i*i }.take(10)
=> [4, 16, 36, 64, 100, 144, 196, 256, 324, 400]
```

А теперь еще одна пара интересных примеров:

```ruby
array = ['a', 'b', 'c', 'd', 'e']

array.each.with_index.map { |name, i| name * i }
=> ["", "b", "cc", "ddd", "eeee"]

array.reverse_each.group_by.each_with_index { |item, i| i % 3 }
=> {0=>["e", "b"], 1=>["d", "a"], 2=>["c"]}
```

Неожиданно, правда?

Что `each.with_index.map` и `reverse_each.group_by.each_with_index`
вообще означают и как работают? Если вам это кажется бессмыслицей, как и
мне раньше, тогда читаем дальше.

### А дело все в Enumerator'ах.

Класс `Enumerator` появился в Ruby 1.9 и служил своеобразной оберткой
над коллекциями, давая интерфейс для итерации по ним. В то же время он
позволяет создать вычислимые псевдо-коллекции или даже ленивые
бесконечные коллекции.

Приведем пример такой псевдо-коллекции. Каждый ее элемент вычисляется на
лету при первом к нему обращении:

```ruby
enum = Enumerator.new do |y|
  y << 1
  y << 'foo'
  y << ['bar']
end
=> #<Enumerator: #<Enumerator::Generator:0x00007fa6a806a030>:each>
```

`enum` теперь можно использовать точно так же как и обычную коллекции из
трех элементов:

```ruby
enum.map { |a| a }
=> [1, "foo", ["bar"]]
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
fib.take(3)
=> [1, 1, 2]

fib.take(10)
=> [1, 1, 2, 3, 5, 8, 13, 21, 34, 55]

fib.take(20)
=> [1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 377, 610, 987, 1597, 2584, 4181, 6765]
```

### Enumerable тесно связан с Enumerator

Многие методы модуля `Enumerable`, которые вызываются с блоком и
возвращают новую коллекцию (например `map`, `select`, `find_all`), начиная с
Ruby 1.9, можно вызывать без блока. В этом случае они возвращают
_enumerator_.

Например, вызов `reverse_each` (из примера выше) без блока возвращает
следующее:

```ruby
['a', 'b', 'c', 'd', 'e'].reverse_each
=> #<Enumerator: ["a", "b", "c", "d", "e"]:reverse_each>
```

Все остальные методы (из примера выше) `with_index`, `map`, `group_by` и
`each_with_index` вызываются уже не на коллекции (массиве), а на
_enumerator_'е.

Вернемся к одному из примеров с цепочкой _enumerator_'ов:

```ruby
['a', 'b', 'c', 'd', 'e'].each.with_index.map { |name, index| name * index }
=> ["", "b", "cc", "ddd", "eeee"]
```

`each` возвращает _enumerator_, который итерирует по исходному массиву

```ruby
enum = ['a', 'b', 'c', 'd', 'e'].each
=> #<Enumerator: ["a", "b", "c", "d", "e"]:each>

enum.to_a
=> ["a", "b", "c", "d", "e"]
```

`each.with_index` тоже возвращает _enumerator_. Но он уже итерирует по
коллекции пар (элемент, индекс):

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

enum.map { |el, i| [el, i] }
=> [["a", 0], ["b", 1], ["c", 2], ["d", 3], ["e", 4]]
```

### Внутренние и внешние итераторы

Интересно сопоставить `Enumerable` и `Enumerator` со стандартными шаблонами.
И то и другое очень похоже на шаблон _Iterator_.

В классе `Enumerable` есть такие методы как `cycle`, `each_entry`, `each_with_index`,
`each_with_index` и `reverse_each`, которые можно назвать внутренними
итераторами. Ведь контроль за итерациями остается у коллекции и клиент
не управляет ни порядком обхода коллекции ни выбирает момент, когда
обработать очередной элемент:

```ruby
(1..3).reverse_each { |v| p v }
=> 3
=> 2
=> 1
```

В `Enumerator` же есть методы `next`, `peek` и `rewind`, которые позволяют
пройтись по коллекции, но контроль остается у клиента. Поэтому
`Enumerator` можно назвать внешним итератором.

```ruby
enum = [1, 2, 3].each
loop do
  puts a.next
end

=> 1
=> 2
=> 3
```

### Enumerator это Enumerable + внешний итератор

В самом классе `Enumerator` реализовано достаточно немного методов.
Перечислим основные из них. Для внутренней итерации: `each`, `each_with_index`, `each_with_object`,
`with_index`, `with_object`. Для внешней итерации: `next`, `next_values`, `peek`, `peek_values`, `rewind`.

Но пусть это не вводит вас в заблуждение. Класс `Enumerator` включает в
себя модуль `Enumerable`, поэтому нам доступен весь его богатый
функционал:

```ruby
enum = (0 .. 10).each
=> #<Enumerator: 0..10:each>
irb(main):036:0> enum.map { |i| i * 2  }.first(5)
=> [0, 2, 4, 6, 8]
```

### Enumerator'ы окружают нас везде

`Enumerator` может казаться незаметной и не нужной частью стандартной
библиотеки, но именно с его помощью можно получить:
* внешний итератор для коллекции
* ленивую коллекцию
* вычислимую псевдо-коллекцию
* бесконечную коллекцию

Более того, используя `Enumerator` можно легко и элегантно превратить
не-Enumerable сущность в _Enumerable_.

`Enumerator` является одновременно и внутренним итератором (метод `each`
и производные от него) и внешним (вспомним метод `next`).

Так как `Enumerable` используется практически в любой Ruby-программе нам
нужно хорошо разбираться и в тесно связанным с ним `Enumerator`.

### Любопытные ссылки:

* [https://ruby-doc.org/core-2.6/Enumerator.html
](https://ruby-doc.org/core-2.6/Enumerator.html)
* [Enumerator: Ruby’s Versatile Iterator](https://blog.carbonfive.com/2012/10/02/enumerator-rubys-versatile-iterator/)
* [Stop including Enumerable, return Enumerator instead](https://blog.arkency.com/2014/01/ruby-to-enum-for-enumerator/)
* [The Enumerable module in Ruby: Part I](https://medium.com/rubycademy/the-enumerable-module-in-ruby-part-i-745d561cfebf)
* [The Enumerable module in Ruby: Part II](https://medium.com/rubycademy/the-enumerable-module-in-ruby-part-ii-41f69b36360)
* [Building Enumerable & Enumerator in Ruby](https://practicingruby.com/articles/building-enumerable-and-enumerator)

[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
