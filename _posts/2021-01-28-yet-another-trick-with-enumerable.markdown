---
layout:     post
title:      Еще один трюк с Enumerator
date:       2021-01-28 23:56
categories: Ruby
---

Недавно открыл для себя один элегантный трюк в Ruby. Приятно узнавать
что-то новое о хорошо знакомом инструменте. Этот трюк, или даже идиома,
помогает создать _enumerator_ из существующего уже метода-итератора.
Довольно редкая задача если пилишь какой-то коммерческий проект -
поэтому трюк пригодится скорее при разработке библиотек.

<img src="/assets/images/2021-01-28-yet-another-trick-with-enumerable/logo.png" style="width: 100%; margin-left: auto; margin-right: auto;" />

### Конвенции Ruby

Вначале немножко теории. Особо нетерпеливым можно перескакивать сразу на
следующий раздел.

В Ruby метод, который принимает блок, называют методом-итератором.
Наверное потому, что такие методы как `each` или `each_slice`, которые
принимают блок, формально относятся к внутренним итераторам.
В противовес внешним итераторам, таким как класс `Enumerator` из
_corelib_. Вероятней всего поэтому термин и перешел на все методы с
аргументом блоком.

Так вот, в _corelib_ Ruby есть конвенция - любой метод-итератор можно
вызвать без блока. В результате вернется _enumerator_, который можно
отложить в сторону, подождать, а затем продолжить работать как с обычной
коллекцией.

Давайте разберем это на примере. Рассмотрим метод `each_slice`, который
разбивает массив на подмассивы заданной длины:

```ruby
(1..10).each_slice(3) { |a| p a }
[1, 2, 3]
[4, 5, 6]
[7, 8, 9]
[10]
=> nil
```

Если его вызвать без блока, то вернется _enumerator_, который можно
обработать позднее.

```ruby
enum = (1..10).each_slice(3)
=> #<Enumerator: 1..10:each_slice(3)>

enum.to_a
=> [[1, 2, 3], [4, 5, 6], [7, 8, 9], [10]]

enum.map(&:sum)
=> [6, 15, 24, 10]

enum.map { |e| e.to_a.reverse }.reduce(:+)
=> [3, 2, 1, 6, 5, 4, 9, 8, 7, 10]
```

Это настолько распространенная конвенция, что даже методы из `Enumerable`
для которых это бессмысленно, например `find`,`detect`, `group_by`,
`max_by`/`min_by` или `sort_by` тоже можно вызвать без блока.

Более того, эта практика вышла за пределы _corelib_. Ее можно встретить
и в сторонних библиотеках и фреймворках. Ей следуют, например, в Rails.

Вот несколько таких методов:
*  методы `find_each` и `find_in_batches` из [ActiveRecord](https://api.rubyonrails.org/classes/ActiveRecord/Batches.html), которые лениво загружают записи из таблицы
* `each_pair`, `each_value`, `transform_values`, `transform_keys` из [ActionController::Parameters](https://api.rubyonrails.org/classes/ActionController/Parameters.html)
* `index_by`, `index_with` из [Enumerable extension](https://api.rubyonrails.org/classes/Enumerable.html)
* `each_record`, `each` из [ActiveRecord::Batches::BatchEnumerator](https://api.rubyonrails.org/classes/ActiveRecord/Batches/BatchEnumerator.html)


### Заглянем под капот

Вернемся к нашему трюку. Наткнулся я на него не совсем случайно. Мне
нужно было разобраться как такие методы-итераторы реализованы в Rails. И
заглянув в исходники я далеко не сразу понял как это работает.

Давайте посмотрим на метод `transform_keys!` из
`ActionController::Parameters`
([source](https://github.com/rails/rails/blob/master/actionpack/lib/action_controller/metal/strong_parameters.rb#L731-L737)):

```ruby
# Performs keys transformation and returns the altered
# <tt>ActionController::Parameters</tt> instance.
def transform_keys!(&block)
  return to_enum(:transform_keys!) unless block_given?
  @parameters.transform_keys!(&block)
  self
end
```

Метод преобразует ключи в ассоциативном массиве
(`ActionController::Parameters`). Если метод вызвали с блоком, то
выполняется основное действие:

```ruby
@parameters.transform_keys!(&block)
```

Но если блок не передали, то метод возвращает _enumerator_:

```ruby
return to_enum(:transform_keys!) unless block_given?
```

Вот это и есть тот самый трюк. Метод `to_enum` создает _enumerator_,
который внутри себя вызывает метод с именем `:transform_keys!` но
уже передает блок. Просто и элегантно!


### Метод to_enum

`to_enum` - это метод класса `Object` и доступен везде, так как
практически все классы наследуются от Object. Используя `to_enum` можно
сделать `Enumerator` из любого метода-итератора.


#### Пример #1

Проиллюстрируем это на примере класса `String` и метода `each_byte`.
Этот метод работает с байтовым представлением строки и конечно же, если
не указал блок, он и сам вернет _enumerator_. Но в нашем примере ([взял
отсюда](https://ruby-doc.org/core-2.7.2/Object.html#method-i-to_enum))
мы добьемся того же используя `to_enum`:

```ruby
string = "xyz"

enum = string.to_enum(:each_byte)
enum.each { |b| puts b }
# => 120
# => 121
# => 122
```

Здесь происходит следующее. Нам дана строка и мы хотим работать с ее
байтовым представлением. Удобнее всего работать с коллекцией, которая
подключает модуль `Enumerable` и нам доступна целая куча удобных методов -
 `map`, `select`, `reduce` итд.

Но класс `String` это не только коллекция байт. Есть и другие
представления - символы, _codepoint_'ы итд. Поэтому в `String` есть
методы для работы с этими данными - `each_byte`, `each_char`,
`each_codepoint`, `each_line` и `each_grapheme_cluster`. Но нет метода
`each` так как нет основного представления, а есть несколько
равноправных.

Но ведь нам нужны байты. Нам нужен объект с методом `each`, который
будет итерировать по байтам строки. Именно с этим и помогает метод
`to_enum`.

#### Пример #2

Можно придумать и более изощренное применение. Например, возьмем
модель ActiveRecord. Метод `create` принимает опциональный блок, а
поэтому мы можем использовать `to_enum`.

Обычный вызов метода `create` с блоком:

```ruby
Account.create do |a|
  a.name = 'b'
end
```

А теперь пример с `to_enum`:

```ruby
enum = Account.to_enum(:create)
enum.each { |a| a.name = 'b' }
```

В чем же разница? В первую очередь разница в абстракции. Во втором
примере у нас есть коллекция пусть всего из одного элемента.

Более того _enumerator_ делает это выражение ленивым. Метод `create`
будет вызван и сохранит данные в базу только после вызова метода `each`:

```ruby
enum = Account.to_enum(:create)
=> #<Enumerator: Account(id: integer, name: string):create>

enum.each { |a| a.name = 'b' }
#  (0.2ms)  SAVEPOINT active_record_1
# Account Create (0.3ms)  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "b"]]
#  (0.1ms)  RELEASE SAVEPOINT active_record_1
=> #<Account id: 3, name: "b">
```


### Реализация to_enum

В методе `to_enum` нет никакой магии. Это просто обертка над
конструктором класса `Enumerator`. Приведу
[реализацию](https://github.com/oracle/truffleruby/blob/release/graal-vm/21.0/src/main/ruby/truffleruby/core/kernel.rb#L576-L581)
из проекта TruffleRuby:

```ruby
def to_enum(method=:each, *args, &block)
  Enumerator.new(self, method, *args).tap do |enum|
    enum.__send__ :size=, block if block_given?
  end
end
alias_method :enum_for, :to_enum
```

### Заключение

Я столкнулся c `to_enum` совершенно случайно, когда надо было добавить
метод-итератор (очередной each_smth) в своей библиотечке и я начал
искать примеры в исходниках Rails. Удивительно, но до сих пор не
встречал даже упоминания об этой технике. Это интересный и красивый
трюк, который поможет написать идиоматичный и выразительный код.


[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
