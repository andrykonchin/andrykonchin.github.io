---
layout: post
title:  "ActiveModel::Dirty без ActiveRecord"
date:   2019-07-22 22:01
categories: Rails
---

Ковыряясь недавно в модуле [`ActiveModel::Dirty`](
https://api.rubyonrails.org/v4.2/classes/ActiveModel/Dirty.html)
в Rails я наткнулся на ряд интересных моментов, о чем дальше и пойдет
речь. Мне надо было разобраться как подключить `ActiveModel::Dirty` в
обычный Ruby класс без ActiveRecord. Процедура эта хорошо описана в
документации, но в моем случае возникли неожиданные подводные камни. Обо
всем по порядку.

### Зачем нужен ActiveModel::Dirty

В модуле `ActiveModel::Dirty` реализовано [отслеживание изменений атрибутов
модели](https://guides.rubyonrails.org/active_model_basics.html#dirty).
С небольшими хаками он интегрирован и в ActiveRecord.
Когда вы в Rails вызываете методы модели `changes`,
`previous_changes` или `changed?`, вы используете методы из
`ActiveModel::Dirty`.

Если кратко, то с `ActiveModel::Dirty` можно определить какие
несохраненные в базу изменения были сделаны. Если развернуто, то
доступны следующие методы:
* `changed?` - есть ли несохраненные изменения атрибутов?
* `changed` - имена измененных атрибутов
* `changed_attributes` - старые значения измененных атрибутов в виде хеша
* `changes` - старые и новые значения измененных атрибутов
* `previous_changes` - старые и новые значения атрибутов перед последним
сохранением
* _attribute based accessor methods_ - все то же но для конкретного атрибута

Но лучше один раз увидеть чем сто раз услышать:

```ruby
a = Account.create(name: 'Google')
a.changed?           # => false

a.name = 'Facebook'
a.changed?           # => true
a.changed_attributes # => {"name"=>"Google"}
a.changes            # => {"name"=>["Google", "Facebook"]}
a.name_changed?      # => true
a.name_change        # => ["Google", "Facebook"]
a.name_was           # => "Google"
```

Здесь мы видим видим основные методы из `ActiveModel::Dirty` вызываемые на
ActiveRecord модели. В ActiveRecord модуль значительно расширяется
([ActiveRecord::AttributeMethods::Dirty](https://api.rubyonrails.org/classes/ActiveRecord/AttributeMethods/Dirty.html)).

### Подключение вне ActiveRecord

Согласно документации весь функционал доступный в ActiveRecord можно
получить практически бесплатно. Надо просто подключить модуль
`ActiveModel::Dirty` в свой класс и сделать некоторые дополнительные
шаги. Перечислим шаги интеграции:
1. все отслеживаемые атрибуты надо задекларировать вызовом метода
   `define_attribute_methods`
2. при изменении значения атрибуты надо вызывать метод
   `[attr_name]_will_change!` (до изменения значения)
3. в аналоге метода `save` нужно вызывать `changes_applied`
4. в аналоге метода `reload` нужно вызывать `clear_changes_information`

ActiveRecord, кстати, подключает `ActiveModel::Dirty` ровно таким же
способом
([source](https://github.com/rails/rails/blob/4-2-stable/activerecord/lib/active_record/attribute_methods/dirty.rb#L19-L39)).

Приведу пример из [Rails Guides](https://guides.rubyonrails.org/active_model_basics.html#dirty):

```ruby
class Person
  include ActiveModel::Dirty
  define_attribute_methods :first_name, :last_name # <--- 1)

  def first_name
    @first_name
  end

  def first_name=(value)
    first_name_will_change! # <--- 2)
    @first_name = value
  end

  def last_name
    @last_name
  end

  def last_name=(value)
    last_name_will_change!
    @last_name = value
  end

  def save
    # do save work...
    changes_applied # <--- 3)
  end
end
```

Пример без изменений работает и на стареньких Rails 4.2 и на текущих
Rails 5.2. Все выглядит легко до тех пор пока не пытаешься
проделать это не с простеньким классом `Person`, а с огромным классом с
кучей методов и сложной логикой и связями. Здесь и начинаются сюрпризы.

Но давайте вначале разберемся как именно работает `ActiveModel::Dirty`.
В последние годы реализация значительно менялась несколько раз - в Rails
5.2 и в Rails 6.0 (пока доступен только RC1).

### ActiveModel::Dirty в Rails 4.2

`ActiveModel::Dirty` работает следующим образом - все изменения модели
сохраняются в виде `Hash`'а в переменной `@changed_attributes`.
Изначально пустой `Hash` обновляется при вызовах `*_will_change!`
метода, который, напомню, должен вызываться перед каждым изменением
атрибута. Сохраняется имя атрибута и его текущее (т.е. до изменения)
значение
([source](https://github.com/rails/rails/blob/4-2-stable/activemodel/lib/active_model/dirty.rb#L226-L237)).
`*_will_change!` сохраняет значение атрибута только при первом вызове,
когда атрибут еще не был изменен. Следовательно, если атрибуту присвоить
несколько значений, то сохранится только оригинальное, которое он имел
при первой модификации. При вызовах методов `clear_changes_information`
([source](https://github.com/rails/rails/blob/4-2-stable/activemodel/lib/active_model/dirty.rb#L206-L210))
и `changes_applied`
([source](https://github.com/rails/rails/blob/4-2-stable/activemodel/lib/active_model/dirty.rb#L200-L204))
`Hash` `@changed_attributes` очищается.

Вместе с этим доступны и предыдущие изменения, который сохраняются в
переменной `@previously_changed` тоже в виде `Hash`'а. В него
переносятся текущие несохраненные изменения при вызове метода
`changes_applied`, который должен вызываться при сохранении данных в
базу данных. При вызове `clear_changes_information` изменения аналогично
очищаются.

При вызове `restore_attributes` всем измененным атрибутам присваиваются
оригинальные значения, которые были сохранены в `@changed_attributes`, и
изменения очищаются (вызывается метод `clear_changes_information`)
([source](https://github.com/rails/rails/blob/4-2-stable/activemodel/lib/active_model/dirty.rb#L188-L191)).

Все остальные публичные методы, как общие так и специфичные для
атрибутов, основываются на этих двух `Hash`'ах - `@changed_attributes` и
`@previously_changed`.

`ActiveModel::Dirty` также ожидает, что для атрибутов доступны и _getter_'ы, и
_setter_'ы (`attr_name` и `attr_name=`).

#### Специфичные для атрибута методы

Любопытно каким способом генерируются специфичные для атрибутов методы.
Например, для атрибута `title` будут доступны:
* `title_changed?`
* `title_change`
* `title_will_change!`
* `title_was`
* `restore_title!`

`ActiveModel::Dirty` опирается на другой модуль
[`ActiveModel::AttributeMethods`](
https://api.rubyonrails.org/v4.2/classes/ActiveModel/AttributeMethods.html),
который умеет генерировать методы для атрибута, добавляя префиксы и
суффиксы к его имени. Метод `define_attribute_methods` из
описания подключения `ActiveModel::Dirty` как раз и реализован в
`ActiveModel::AttributeMethods.` Все методы производные от имени атрибутов
генерируются в нем. `ActiveModel::Dirty` просто декларирует какие префиксы
и суффиксы надо использовать:

```ruby
module ActiveModel
  module Dirty
    include ActiveModel::AttributeMethods

    # ...
    included do
      attribute_method_suffix '_changed?', '_change', '_will_change!', '_was'
      attribute_method_affix prefix: 'restore_', suffix: '!'
    end

    # ...
  end
end
```

[source](https://github.com/rails/rails/blob/4-2-stable/activemodel/lib/active_model/dirty.rb#L121-L125)

Методы сгенерированные `define_attribute_methods` всего лишь проксируют
вызов специфичного для атрибута метода к универсальному методу ([source](
https://github.com/rails/rails/blob/4-2-stable/activemodel/lib/active_model/attribute_methods.rb#L284-L299)).
Например `title_changed?` будет вызывать метод `attribute_changed?(attr, options = {})`
([source](https://github.com/rails/rails/blob/4-2-stable/activemodel/lib/active_model/dirty.rb#L176-L181)),
а `title_will_change!` - `attribute_will_change!(attr)`
([source](https://github.com/rails/rails/blob/4-2-stable/activemodel/lib/active_model/dirty.rb#L227-L237)).
Эти универсальные методы реализованы в `ActiveModel::Dirty` и выполняют
всю работу.

Это не описано явно в документации `ActiveModel::AttributeMethods`, но
можно не декларировать атрибуты вызовом `define_attribute_methods` если
добавить метод `#attributes`. `#attributes` должен возвращать `Hash`,
ключи в котором - имена атрибутов. В этом случае сработает механизм
основанный на `method_missing`
([source](https://github.com/rails/rails/blob/4-2-stable/activemodel/lib/active_model/attribute_methods.rb#L428-L435)).
Несмотря на то, что методы для атрибутов не будут сгенерированы, если
имя вызываемого несуществующего метода соответствует имени атрибута
возвращаемого методом `#attributes` и зарегистрированному шаблону (с
суффиксом или префиксом
([source](https://github.com/rails/rails/blob/4-2-stable/activemodel/lib/active_model/attribute_methods.rb#L390-L416))),
то вызов будет проксирован к соответствующему общему методу
([source](https://github.com/rails/rails/blob/4-2-stable/activemodel/lib/active_model/attribute_methods.rb#L437-L443)).

Приведем пример. Допустим есть только один атрибут `title`,
`#attribute_methods` возвращает `{ 'title' => 'Manager' }` с текущим его
значением и зарегистрирован суффикс `_changed?`. В этом случае вызов
метода `title_changed?` будет обработан в `method_missing` и будет
вызван метод `attribute_changed?('title')`.

#### Генерация методов

Интерес представляет еще один трюк с генерацией методов. Все специфичные
атрибутам генерируемые методы при вызове `define_attribute_methods`
добавляются не в текущий класс или модуль, а в специальный анонимный
модуль (переменная `@generated_attribute_methods`), который подключается
в уже в сам `ActiveModel::AttributeMethods`
([source](https://github.com/rails/rails/blob/4-2-stable/activemodel/lib/active_model/attribute_methods.rb#L331-L335)).

Таким образом _method lookup_ выполняется по следующей схеме:

<img src="/assets/images/2019-07-22-activemodel-dirty-outside-of-activerecord/method_lookup_diagram.svg" />

Из-за этого трюка становится возможным переопределить сгенерированные
методы в других модулях, которые подключаются позже (между `Person` и
`ActiveModel::AttributeMethods` в нашем примере), или даже в самом
конечном классе. В противном случае методы бы добавлялись
непосредственно в конечный класс (`Person`).

Приведем пример кастомизации генерируемого метода. Допустим, мы хотим
изменить метод `[attr_name]_change` для атрибута `first_name` но не
непосредственно в самом классе `Person`, в отдельном модуле. Это сделать
достаточно просто:

```ruby
module PersonConcern
  # override generated by ActiveModel::Dirty method
  def first_name_change
    super.tap do |pair| # [old, new]
      pair[1] += ' [Customised]'
    end
  end
end

class Person
  include ActiveModel::Dirty
  include PersonConcern

  define_attribute_methods :first_name

  # ...

  def first_name=(value)
    first_name_will_change!
    @first_name = value
  end

  # ...
end

person = Person.new
person.first_name = "First Name"
person.first_name_change # => [nil, "First Name [Customised]"]
```

Если бы метод `first_name_change` при вызове `define_attribute_methods`
добавлялся непосредственно в класс `Person`, он был бы недоступен в
других модулях подключенных в `Person` (например в `PersonConcern`).

Такой же подход используется и в ActiveRecord - все генерируемые методы,
_getter_'ы
([source](https://github.com/rails/rails/blob/4-2-stable/activerecord/lib/active_record/attribute_methods/read.rb#L53-L56))
и _setter_'ы
([source](https://github.com/rails/rails/blob/4-2-stable/activerecord/lib/active_record/attribute_methods/write.rb#L29-L34))
в том числе, добавляются в этот же самый анонимный модуль
(`@generated_attribute_methods`).

### ActiveModel::Dirty в Rails 5.2

В Rails 5.0 появилось так называемое [Attributes API](
https://guides.rubyonrails.org/5_0_release_notes.html#active-record-attributes-api).
Это позволяло изменять тип атрибута ActiveRecord модели, вводить новые
пользовательские типы и создавать новый атрибуты без соответствующей
колонки в таблице базы данных.

В Rails 5.2 этот функционал перенесли из ActiveRecord в ActiveModel
(в этом [_pull request_'е](https://github.com/rails/rails/pull/30985)) что привело
к значительным изменениям в `ActiveModel::Dirty`. Теперь начали
отслеживаться как изменения обычных атрибутов зарегистрированных через
`ActiveModel::AttributeMethods` модуль (вызовом метода
`define_attribute_methods`) так и изменения атрибутов созданных через
Attributes API (вызовом метода `attribute` из модуля
`ActiveModel::Attributes`). То есть вызовы `changes` или
`previous_changes`, например, вернут вперемешку и изменения атрибутов из
`ActiveModel::AttributeMethods` и атрибутов из `ActiveModel::Attributes`
([source](https://github.com/rails/rails/blob/5-2-stable/activemodel/lib/active_model/dirty.rb#L224)).

Изменения атрибутов `ActiveModel::AttributeMethods` аккумулируются все
так же в переменных `@attributes_changed_by_setter` и
`@previously_changed`. Если в моделе подключен модуль
`ActiveModel::Attributes`, то изменения в атрибутах Attributes API
сохраняются в переменных `@mutations_from_database` и
`@mutations_before_last_save`
([source](https://github.com/rails/rails/blob/5-2-stable/activemodel/lib/active_model/dirty.rb#L323)).
В них хранится не обычный `Hash`, а трекер изменений - экземпляр класса
`ActiveModel::AttributeMutationTracker`
([source](https://github.com/rails/rails/blob/5-2-stable/activemodel/lib/active_model/attribute_mutation_tracker.rb#L6-L83)).
Так как трекер теперь вычисляет сделанные изменения на лету, изменения
кешируются в переменной `@cached_changed_attributes`
([source](https://github.com/rails/rails/blob/5-2-stable/activemodel/lib/active_model/dirty.rb#L234-L238)).

Факт подключения `ActiveModel::Attributes` определяется весьма
прямолинейным образом - проверяется существование переменной
`@attributes`
([source](https://github.com/rails/rails/blob/5-2-stable/activemodel/lib/active_model/dirty.rb#L264)),
экземпляра класса `ActiveModel::AttributeSet`
([source](https://github.com/rails/rails/blob/5-2-stable/activemodel/lib/active_model/attribute_set.rb)).
В отличии от старого подхода с `Hash`'ами атрибутов и оригинальных
значений, в `ActiveModel::AttributeSet` вместо непосредственных значений
атрибутов хранятся объекты класса `ActiveModel::Attribute`
([source](https://github.com/rails/rails/blob/5-2-stable/activemodel/lib/active_model/attribute.rb)),
каждый из которых содержит как оригинальное так и измененное значение
атрибута, может определить _change in place_, выполнять _type casting_
итд.

В Rails 5.0 появилось еще одно небольшое изменение в
`ActiveModel::Dirty` - добавили пару специфичных для атрибутов методов -
`<name>_previously_changed?` и `<name>_previous_change` (
[source](https://github.com/rails/rails/blob/5-2-stable/activemodel/lib/active_model/dirty.rb#L130)).

Таким образом мы получили две независимые реализации одного и того же
механизма. Поскольку ActiveRecord использует только новый, старый
механизм с `@attributes_changed_by_setter` и `@previously_changed` был
оставлен скорее для совместимости, так как `ActiveModel::Dirty` это
публичный интерфейс и может использоваться вне ActiveRecord другими
библиотеками. В дальнейшем в Rails 6 были сделаны еще более серьезные
изменения.

### ActiveModel::Dirty в Rails 6.0

В Rails 6.0 один добрый фей пришел и сделал всем хорошо. Была
значительно улучшена производительность методов из модуля
`ActiveModel::Dirty` и согласно приведенным в _PR_'е измерениям
ускорение получилось порядка 2х-10х ([pull
request](https://github.com/rails/rails/pull/35933)). Старый механизм
отслеживание изменений атрибутов (сгенерированных используя
`ActiveModel::AttributeMethods`) был вынесен в отдельный компонент -
`ForcedMutationTracker`
([source](https://github.com/rails/rails/blob/6-0-stable/activemodel/lib/active_model/attribute_mutation_tracker.rb#L84-L143)).

Ускорение было достигнуто из-за того, что теперь работает только один из
механизмов отслеживания изменений атрибутов - либо старый либо новый.
Если подключен модуль `ActiveModel::Attributes`, то отслеживаются только
его атрибуты. В противном случае - только атрибуты
`ActiveModel::AttributeMethods`
([source](https://github.com/rails/rails/blob/6-0-stable/activemodel/lib/active_model/dirty.rb#L240-L246)).
Следовательно, теперь нельзя использовать `ActiveModel::Dirty` в классе,
в котором атрибуты декларировались используя оба подхода.

### Заключение

Можно только приветствовать развитие Rails и модуля `ActiveModel::Dirty`
в частности. Это естественно, что периодическое усложнение функционала
сопровождается последующим рефакторингом и упрощением кода. Единственное
в чем можно упрекнуть разработчиков Rails - это неполнота описания
контракта на использование `ActiveModel::Dirty`.

Было задекларировано, что `ActiveModel::Dirty` можно использовать
отдельно от ActiveRecord, но долгое время они были сильно связаны. В
документации по `ActiveModel::Dirty` ничего не сказано о методе
`attributes`, но во всех версиях Rails модуль
`ActiveModel::AttributeMethods` (который используется в
`ActiveModel::Dirty`) меняет свое поведение если метод `attributes`
определен.

В Rails 5.2 наличие переменной `@attributes` значительно влияет на
поведение `ActiveModel::Dirty`. Он включает механизм отслеживания для
`ActiveModel::Attributes`. Хотя эта переменная может быть совершенно
несвязанной с `ActiveModel::Attributes` и ActiveRecord.

Изменение в Rails 6.0 вообще радикально меняет поведение. При наличие
переменной `@attributes` `ActiveModel::Dirty` перестает отслеживать
атрибуты `ActiveModel::AttributeMethods`.

Как очевидно, проблема не в нарушении обратной совместимости, а в том,
что это нарушение не документируется и делается неявно.

### Эпилог

В моем конкретном случае все было несколько сложнее.

Возясь с поддержкой _gem_'а
[Dynamoid](https://github.com/Dynamoid/dynamoid) (это ORM для AWS
DynamoDB) всплыла проблема с поддержкой еще не вышедшей Rails 6. Уже был
доступен RC1 и зарепортили issue - при сохранении модели выбрасывается
_exeption_.

Из _backtrace_ сразу было видно, что что-то сломалось в подключенном
модуле `ActiveModel::Dirty`. Dynamoid использовал его для повторения
интерфейса ActiveRecord. Заглянув в модуль отвечающий за подключение
Dirty API я увидел пачку _monkey-patch_'ей для разных версий Rails. К
своему стыду вспомнилось, что один из них с год назад налепил я сам.

Подавив в себе малодушный порыв добавить еще один _monkey-patch_ уже для
Rails 6 засучив рукава я принялся выправлять кривое и выравнивать
неровное. Например, в Dynamoid в модели была своя переменная
`@attributes`, которая конфликтовала с `ActiveModel::AttributeMethods`.
Наконец, на Rails 4.2 все завелось без костылей и _monkey-patch_'ей.
Написанная пачка тестов (ага - это практически не было покрыто тестами)
успешно прошла. Кстати, запустив эти тесты я обнаружил, что в старой
реализации некоторые публичные методы из Dirty API работали неправильно.

Затем я запустил тесты на Rails 5.2 и все сломалось. Начав разбираться с
изменениями в ActiveModel в Rails 5.2 я приуныл и весь энтузиазм
испарился. В Dynamoid в модели для переменной `@attributes` был объявлен
`getter`, который ломал работу `ActiveModel::Dirty`. Конфликт именования
методов очень не хотелось разрешать глобальным переименовываем метода
`attributes` по всему проекте. Из вариантов я вначале рассматривал
добавление вспомогательного минималистичного объекта-трекера, в который
бы подмешивался `ActiveModel::Dirty` и который бы отслеживал все
изменения атрибутов для связанной модели. А методы Dirty API можно было
просто делегировать из каждой модели к своему объекту-трекеру. Это
полностью бы решало вопрос с конфликтами имен и методов и совместимостью
с любыми изменениями в будущих версиях Rails. Останавливала только
сложность взаимодействия модели и этого объекта-трекера. С одной стороны
модель делегирует Dirty API методы трекеру. Но с другой стороны трекер
должен читать и менять значения атрибутов самой модели.

Ради интереса я посмотрел на схожий проект Mongoid (ORM для MongoDB),
еще один источник вдохновения. К удивлению, я увидел, что у них своя
независимая реализация трекинга изменений атрибутов, которая не
использует `ActiveModel::Dirty`. Я не рассматривал раньше эту идею в
серьез, но к этому времени уже достаточно хорошо разобрался в реализации
`ActiveModel::Dirty` в Rails. Поэтому просто перенести в Dynamoid
реализацию `ActiveModel::Dirty` из Rails 4.2 с некоторой адаптацией уже
не казалось сложной задачей. И тесты уже есть... Один свободный вечер
спустя _copy-paste_ версия `ActiveModel::Dirty` заработала в Dynamoid на
всех основных версиях Rails - 4.2, 5.2 и 6.0rc1.

Таким образом я получил поддержку Rails 6, независимость от
`ActiveModel::Dirty` и будущих изменений в нем и заодно исправил ошибки
в старой реализации в Dynamoid.

### Ссылки

* [https://api.rubyonrails.org/classes/ActiveModel/Dirty.html](https://api.rubyonrails.org/classes/ActiveModel/Dirty.html)
* [https://api.rubyonrails.org/classes/ActiveModel/AttributeMethods.html
](https://api.rubyonrails.org/classes/ActiveModel/AttributeMethods.html)
* [https://guides.rubyonrails.org/5_0_release_notes.html
](https://guides.rubyonrails.org/5_0_release_notes.html#active-record-attributes-api)
* [https://github.com/rails/rails/pull/30985](https://github.com/rails/rails/pull/30985)
* [https://github.com/rails/rails/pull/35933](https://github.com/rails/rails/pull/35933)

[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
