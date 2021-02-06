---
layout:     post
title:      Проблема с keyword arguments в Ruby 3.0
date:       2021-02-06 22:34
categories: Ruby
---

После недавнего выхода Ruby 3.0 я решил проверить, что _gem_ Dynamoid
нормально на нем заводится. И в процессе столкнулся с любопытными
проблемами. Matz зарелизил Ruby 3.0 по традиции на католическое
Рождество и вместе с тем выкатил обратно несовместимые изменения в
_keyword arguments_. Еще в предыдущей версии Ruby 2.7 начали сыпаться
_deprecation warning_'и, но руки не дошли это исправить. Теперь
_warning_'и превратились в _exception_'ы и пришлось таки этим заняться.


### Keyword arguments

Давайте разберемся, что поменяли в _keyword arguments_, и вначале
проговорим, что это такое. _Keyword arguments_ ввели давным давно - еще
в Ruby 2.0. Формально это [именованные
параметры](https://en.wikipedia.org/wiki/Named_parameter), которые
поддерживают такие языки как Scala, Kotlin и даже PHP.

```ruby
def foo(a:, b:, c:)
  [a, b, c]
end

foo(c: 3, b: 2, a: 1)
=> [1, 2, 3]
```

Думаю, что чаще всего _keyword arguments_ в Ruby использовали вместо
параметра _options_ вместе с оператором `**`:

```ruby
# как было
def bar(a, options)
  [a, options[:b], options[:c]]
end

# как стало
def bar(a, **options)
  [a, options[:b], options[:c]]
end
```


### Обратно несовместимые изменения

Изначально не было разницы между передачей параметров как _keyword
arguments_ и как _hash_. Вероятно чтобы облегчить переход. _Keyword
arguments_ автоматически конвертировались в _hash_ и наоборот.

Но начиная с Ruby 3.0 началось разделение _keyword arguments_ и
позиционных аргументов. Это с подробностями описано в статье [The
Delegation Challenge of Ruby
2.7](https://eregon.me/blog/2019/11/10/the-delegation-challenge-of-ruby27.html).
Хотя статья и примечательная, она слишком объемная. Попробую кратко
пересказать ее.

Изменилось поведение операторов `*args` и `**options`. Если раньше
`*args` захватывал _keyword arguments_ и они передавались как
завершающий _hash_-параметр, то теперь позиционные параметры и _keyword
arguments_ разделяются строже. Приведу пример:

```ruby
def foo(*a, **kw)
  [a, kw]
end
```

Вызов `foo` с _keyword argument_ работает по старому:

```ruby
# Ruby 2.6
foo(a: 1)
=> [[], {:a=>1}]

# Ruby 3.0
foo(a: 1)
=> [[], {:a=>1}]
```

Но если вместо этого передать _hash_ - поведение меняется:

```ruby
# Ruby 2.6
foo({a: 1})
=> [[], {:a=>1}]

# Ruby 3.0
foo({a: 1})
=> [[{:a=>1}], {}]
```

Завершающий _hash_-параметр раньше захватывался оператором `**` и
передавался как _keyword argument_. Теперь он захватывается оператором
`*` и передается как позиционный аргумент.

В этом нет ничего страшного ни для разработчиков приложений, ни для
разработчиков библиотек. Но возникает неприятный нюанс с делегированием
параметров. Это распространенная практика делегировать вызов метода
другому объекту:

```ruby
class A
  def initialize(target)
    @target = target
  end

  def method_missing(name, *args, &block)
    @target.send(name, *args, &block)
  end
end

proxy = A.new("")
=> #<A:0x00007fe570028bd8 @target="">

proxy << "abc"

proxy
=> #<A:0x00007fe570028bd8 @target="abc">
```

И в чем же проблема, спросите вы? Проблема в том, что теперь в Ruby 3.0
хотя `*args` и захватит _keyword arguments_, при передаче параметров они
так и остаются позиционным параметром. Следовательно, метод ожидающий
_keyword arguments_ их не получит и отработает некорректно:

```ruby
obj = Object.new
def obj.foo(*args, **kw)
  [args, kw]
end
proxy = A.new(obj)

obj.foo(1, a: 2)
=> [[1], {:a=>2}] # <=== правильный результат

proxy.foo(1, a: 2)
=> [[1, {:a=>2}], {}] # <=== некорректный результат
```


### Какие варианты решения?

Если добавим явный `**kw` параметр, это не решит проблему.

```ruby
def method_missing(name, *args, **kw, &block)
  @target.send(name, *args, **kw, &block)
end
```

Такой подход работает в Ruby 3.0 но в Ruby 2.6 и младше будет
добавляться дополнительный параметр `{}` для _keyword arguments_, даже
если их не передали и _target_ метод их не ожидает:

```ruby
# Ruby 2.6

obj = Object.new

def obj.foo(*args)
  args
end

proxy = A.new(obj)

proxy.foo(1)
=> [1, {}]
```

А это уже серьезная проблема. Если _target_ метод не ожидает
дополнительный параметр, то будет бросаться исключение:

```ruby
def obj.bar
end

proxy.bar
# Traceback (most recent call last):
#         4: from .../bin/irb:11:in `<main>'
#         3: from (irb):21
#         2: from (irb):7:in `method_missing'
#         1: from (irb):19:in `bar'
# ArgumentError (wrong number of arguments (given 1, expected 0))
```

В Ruby 2.7 добавили костыль в виде метода
`ruby2_keywords`. Он переключает механизм делегирования для конкретного
метода обратно на режим Ruby 2.6:

```ruby
ruby2_keywords(:method_missing) if respond_to?(:ruby2_keywords, true)
```

Это рабочий подход и он облегчает переход на новые версии Ruby. Его
используют даже в Rails
([примеры](https://github.com/rails/rails/search?p=2&q=ruby2_keywords)).
Проблема только в том, что это временное решение. Через несколько лет
метод `ruby2_keywords` уберут и придется отказаться от поддержки Ruby
2.6 и ранних версий.

Любопытно, что кроме `Module#ruby2_keywords` и `Proc#ruby2_keywords`, в
публичное API попали и другие костыльные методы, которые отмечены в
документации как "not for casual use":
* `Hash.ruby2_keywords_hash?`
* `Hash.ruby2_keywords_hash `

В Ruby 2.7 добавили новый идеологически правильный способ делегировать
параметры - оператор `...`:

```ruby
def method_missing(name, ...)
  @target.send(name, ...)
end
```

Это работает но только начиная с Ruby 2.7, а в более ранних версиях недоступно.

Для разработчика приложения это не вызовет проблем.
Версия Ruby зафиксирована. Берем подходящий способ делегирования и все
работает. А вот я как разработчик библиотеки оказался в тупике.


### Итоговое решение в Dynamoid

Dynamoid поддерживает старые версии Ruby (начиная с Ruby 2.3) и пока от
этого отказываться не планирую. И в Dynamoid часто используется
делегирование. Поэтому нужно поддерживать делегирование как в режиме
Ruby 2.6, так и в режиме Ruby 2.7 и теперь в режиме Ruby 3.0. Dynamoid
продолжит поддерживать старые версии Ruby даже после прекращения
официальной поддержки Ruby _core team_. Согласно статистике <https://stats.rubygems.org/>
Ruby 2.3, которая вышла 7 лет назад и перестала поддерживаться 2 года
назад, занимает долю в 45%:

<img src="/assets/images/2021-02-06-issue-with-keyword-arguments-in-ruby-3/versions_statistics.png" style="width: 100%; margin-left: auto; margin-right: auto;" />

Так как же быть? Поддерживать Ruby 3.0 надо. Делегирование в 3.0
ломается. Вариант с оператором `...` не подходит однозначно - это не
работает в Ruby 2.6 и младше. Вариант с методом `ruby2_keywords` не
решает проблему для Dynamoid, а откладывает ее. Откладывает до момента,
когда прекратится поддержка Ruby 2.6, а будет это скоро.

Поэтому я рассматривал два варианта
* или убрать делегирование из Dynamoid
* или не использовать _keyword arguments_ в методах, которые вызывают
  через делегирование.

Второй вариант оказался намного проще. Хотя _keyword arguments_
используются в Dynamoid, только один приватный метод вызывался через
делегирование. Исправление одной строчки кода и нескольких строчек в
тестах и вуаля - тесты проходят на Ruby 3.0.


### PS

Если посмотреть со стороны, то такое решение больше похоже на бегство от
проблемы, чем на решение. С другой же стороны мы не попали в капкан,
который расставили на бедных разработчиков Matz и Ruby _core team_.

Меня каждый раз удивляет, как легко Matz накидывает _breaking changes_.
Сразу вспоминается переход с Ruby 1.8 на 1.9, в котором было много таких
изменений. И россыпь `if`-ов раскиданных по коду _gem_'ов с проверкой
версии Ruby.

Если думаете, что мелкие _breaking changes_ безобидны - это не так. Я
переводил коммерческий проект с Ruby 2.2 на Ruby 2.5 и на это ушла
неделя. В основном на обновление зависимостей, чтобы найти минимальную
версию _gem_'а с поддержкой Ruby 2.5 и минимизировать _breaking changes_
уже самого _gem_'а.


### Ссылки

* <https://eregon.me/blog/2021/02/13/correct-delegation-in-ruby-2-27-3.html>
* <https://eregon.me/blog/2019/11/10/the-delegation-challenge-of-ruby27.html>
* <https://www.ruby-lang.org/en/news/2019/12/12/separation-of-positional-and-keyword-arguments-in-ruby-3-0/>
* <https://github.com/ruby/spec/pull/821>


[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
