---
layout: post
title:  Атомарность require в Ruby
date:   2022-03-10 18:00
categories: Ruby
---

Метод `Kernel#require` - это стандартный способ в Ruby подключить другой файл. За простотой на самом деле стоит нетривиальная логика. Принимаешь как должное, что он адекватно и надежно работает и не думаешь, например, а потоко ли безопасен `require`. А атомарен ли. А как справится с циклом в зависимостях.

А вот мне довелось столкнулся с проблемой атомарности _require_ и это взорвало мне мозг.

**TL;DR:** `require` не атомарен и в многопоточном коде использовать его опасно.



### Атомарность

Не нашел каноничное определение атомарности, поэтому процитирую [статью о транзакциях баз данных][1]

> An atomic transaction is an indivisible and irreducible series of database operations such that either all occurs, or nothing occurs. A guarantee of atomicity prevents updates to the database occurring only partially, which can cause greater problems than rejecting the whole series outright. As a consequence, the transaction cannot be observed to be in progress by another database client. At one moment in time, it has not yet happened, and at the next it has already occurred in whole (or nothing happened if the transaction was cancelled in progress).


Обратите внимание - если операция атомарна, то промежуточное состояние не видно стороннему наблюдателю. И этот наблюдатель выполняется параллельно - в другом потоке или процессе.

В компилируемых статически-типизированных языках подключают файлы еще при компиляции. В Ruby `require` на лету загружает указанный файл, парсит и выполняет синтаксический анализ. А затем исполняет, так как файл содержит не только декларации классов, методов и констант, но и код, который отрабатывает при загрузке файла.



### Эксперимент

Давайте проверим, а атомарен ли `require`. Может ли сторонний наблюдатель видеть файл частично загруженным и только часть классов и методов доступна?

Проведем эксперимент - загрузим файл и проверим какие декларации классов и методов доступны.

Загружаемый файл:

```ruby
# required_file.rb

puts "file beginning"
sleep 2

puts "class definition beginning"

class A

  puts "method definition beginning"
  sleep 2

  def foo
    :foo
  end

  puts "method definition ending"
  sleep 2
end

puts "class definition ending"
```

Декларируем класс `A` с методом `foo`. Перед декларациями класса и метода вставляем задержку в две секунды (`sleep 2`) и выводим в консоль текущую позицию в файле.

Файл с "наблюдателем":

```ruby
# observer.rb

Thread.new do
  loop do
    class_defined = Object.const_defined?(:A)
    method_defined = class_defined && A.instance_methods.include?(:foo)

    puts "A defined? -> #{class_defined} | foo defined? -> #{method_defined}"

    sleep 1
  end
end

Thread.new do
  require './required_file'
end.join
```

В одном потоке загружаем файл, а во втором в бесконечном цикле проверяем определена ли константа `A` (имя класса) и метод `foo`.

Возможны два варианта:
* `require` атомарен и наблюдатель увидит константу `A` и метод `foo` только после полной загрузки файла
* `require` не атомарен и наблюдатель увидит константу `A` до завершения загрузки файла. Затем увидит класс, но без метода `foo`.

Запускаем наблюдателя:

```shell
$ ruby ./observer.rb
A defined? -> false | foo defined? > false
file beginning
A defined? -> false | foo defined? > false
class definition beginning
A defined? -> true | foo defined? > false
A defined? -> true | foo defined? > false
method definition beginning
method definition ending
A defined? -> true | foo defined? > true
A defined? -> true | foo defined? > true
class definition ending
```

Видим, что класс доступен до окончания загрузки файла. А когда класс `A` уже доступен - `foo` еще не виден.

Может быть не все так страшно? Пусть foo еще нет в списке методов, но его можно вызвать? Меняем наблюдателя и проверяем. Вместо проверки `instance_methods` пробуем вызвать метод `foo`.

Было

```ruby
method_defined = class_defined && A.instance_methods.include?(:foo)
```

Стало

```ruby
method_defined = class_defined && (A.new.foo rescue false)
```

Запускаем, но результат тот же.



### Прерванная загрузка файла

Как следствие, если при загрузке файла произошла ошибка и бросилось исключение - декларации в файле обработаются частично. Часть классов и методов будет видна, а часть - нет. Если приложение продолжило работу после исключения - получаем кучу мусора в памяти.

Загружаемый файл:

```ruby
# required_file.rb

class A
  def foo
    :foo
  end

  raise 'Exception inside class definition'

  def bar
    :bar
  end
end
```

Файл с наблюдателем:

```ruby
# observer.rb

begin
  require './required_file'
rescue
  puts "exception was raised '#{$!}'"
end

class_defined = Object.const_defined?(:A)
foo_defined = class_defined && A.instance_methods.include?(:foo)
bar_defined = class_defined && A.instance_methods.include?(:bar)

puts "A defined? -> #{class_defined}"
puts "foo defined? -> #{foo_defined}"
puts "bar defined? -> #{bar_defined}"
```

Перехватываем исключение, поэтому программа не завершается.

Запустим наблюдателя:

```shell
$ ruby observer.rb
exception was raised 'Exception inside class definition'
A defined? -> true
foo defined? -> true
bar defined? -> false
```

Как видим, класс `A` объявлен. Но доступен только метод `foo`, который определен до исключения, а метод `bar` - недоступен.



### PS

Проблема высосона из пальца, скажете вы. Ну кто будет подключать файлы на лету да еще и в отдельном потоке? В приложениях файлы загружаются на старте. Ваша правда.

Я столкнулся с неатомарностью `require`, когда в Sidekiq при запуске начали падать ошибки `NoMethodError`. В разных местах. Разные методы. Но одного и того же класса. Виновником оказался `require` ([PR с фиксом][2]).

Sidekiq - это многопоточный сервер _background job_'ов. В приложении (вернее в _gem_'е, в котором падали ошибки) можно подключать плагины (адаптеры) указав имя в конфигурации. Адаптер - это _singleton_ (внутри все потокобезопасно, так что тут все в порядке) но инициализировался _лениво_ при первом обращении. Файл с адаптером загружался тоже _лениво_:

```ruby
def adapter
  @adapter ||= \
    begin
      adapter_class_name = Config.adapter_name.camelcase

      unless Object.const_defined?(adapter_class_name)
        require "plugins/#{Config.adapter_name}"
      end

      adapter_class = Object.const_get(adapter_class_name)
      adapter_class.new
    end
end
```

При первом обращении к адаптеру берем имя из конфигурации. Если класс адаптера еще не объявлен - загружаем файл. Далее инстанцируем объект класса адаптера.

Комбинация отложенной загрузки файла и многопоточности Sidekiq привела к тому, что после старта процесса сразу два потока Sidekiq обрабатывая параллельно _job_'ы обращаются к адаптеру, который еще не инстанцирован.

Первый поток вызывает `require` и начинает загружать файл. Второй поток видит, что адаптер еще не инстанцирован, и тоже начинает инициализацию. Предварительно перед загрузкой файла он проверяет, а объявлен ли уже класс адаптера. Если класс объявлен, то предполагается, что файл уже загружен и безопасно инстанцировать адаптер. Если первый поток уже дошел до объявления класса но еще не закончил загрузку файла - часть методов еще недоступны. Второй поток инстанцирует адаптер первым не дожидаясь загрузки файла и вызывает на нем методы. Если метод еще не виден в классе - бросается исключение `NoMethodError`.

Чтобы избежать проблем использовали примитивы конкурентности Atom и Compare-And-Set. Внутри адаптера использовался мьютекс. Но это не спасло от проблем с многопоточностью.



[1]: https://en.wikipedia.org/wiki/Atomicity_(database_systems
[2]: https://github.com/Dynamoid/dynamoid/pull/373

[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
