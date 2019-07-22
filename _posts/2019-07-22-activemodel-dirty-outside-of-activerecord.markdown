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
документации но в моем случае возникли неожиданные подводные камни. Но
все по порядку.

### Зачем нужен ActiveModel::Dirty

В модуле `ActiveModel::Dirty` реализовано [отслеживание изменений атрибутов
модели](https://guides.rubyonrails.org/active_model_basics.html#dirty).
С небольшими хаками он интегрирован и в ActiveRecord.
Когда вы в Rails вызываете методы модели `changes`,
`previous_changes` или `changed?`, вы используете методы из
`ActiveModel::Dirty`.

Если кратко, то с `ActiveModel::Dirty` можно определить какие
несохраненные в базу изменения были сделаны. Если развернуто, то можно:
* определить есть ли несохраненные изменения атрибутов (метод `changed?`)
* получить массив имен измененных атрибутов (метод `changed`)
* получить старые значения измененных атрибутов в виде хеша
(метод `changed_attributes`)
* получить старые и новые значения измененных атрибутов (метод `changes`)
* получить предыдущие старые и новые значения атрибутов до последнего
сохранения модели в базу (метод `previous_changes`)
* все то же но для конкретного атрибута (_attribute based accessor methods_)

Но лучше один раз увидеть чем сто раз услышать:

```ruby
Account.create(name: 'Google')
a = Account.last
a.changed?
# => false
a.name = 'Facebook'
a.changed?
# => true
a.changed_attributes
# => {"name"=>"Google"}
a.changes
# => {"name"=>["Google", "Facebook"]}
a.name_changed?
# => true
a.name_change
# => ["Google", "Facebook"]
a.name_was
# => "Google"
```

Здесь мы видим видим основные методы из `ActiveModel::Dirty` вызываемые на
ActiveRecord модели. В ActiveRecord модуль значительно расширяется
([ActiveRecord::AttributeMethods::Dirty](https://api.rubyonrails.org/classes/ActiveRecord/AttributeMethods/Dirty.html)).

ActiveRecord, кстати, подключает `ActiveModel::Dirty` ровно таким же
способом
([source](https://github.com/rails/rails/blob/4-2-stable/activerecord/lib/active_record/attribute_methods/dirty.rb#L19-L39)).

### Подключение вне ActiveRecord

В документации говорится, что весь функционал доступный в ActiveRecord
можно получить практически бесплатно просто подключив модуль
`ActiveModel::Dirty` в свой класс и сделав
некоторые дополнительные шаги. Для интеграции нужно выполнить следующие
условия:
1. все отслеживаемые атрибуты надо задекларировать вызовом метода
`define_attribute_methods`
2. при изменении значения атрибуты надо вызывать метод
`[attr_name]_will_change!` (перед самим изменением значения)
3. если в классе есть операции сохранения данных куда-то в хранилище
(аналог `save`), нужно в нем вызывать метод `changes_applied`
4. Если в классе есть метод аналогичный `reload` - в нем надо вызывать
метод `clear_changes_information`

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
В последние годы реализация менялась несколько раз - в Rails 5.2 и в
Rails 6.0 (пока доступен только RC1).

### ActiveModel::Dirty в Rails 4.2

`ActiveModel::Dirty` работает следующим образом - все изменения модели
сохраняются в виде `Hash`'а в переменной `@changed_attributes`.
Изначально пустой `Hash`, он обновляется при каждом вызове `*_will_change!`
метода, который, напомню, должен вызываться перед каждым изменением
значения атрибута. Сохраняется имя атрибута и его текущее (т.е. старое,
до изменения) значение
([source](https://github.com/rails/rails/blob/4-2-stable/activemodel/lib/active_model/dirty.rb#L226-L237)).
По факту, `*_will_change!` сохраняет оригинальное значение только в
первый раз, когда атрибут еще не был изменен.
Следовательно, если атрибуту присвоить несколько разных значений,
то сохранится только оригинальное значение атрибута, которое он имел при
первой модификации. При вызовах методов `clear_changes_information`
([source](https://github.com/rails/rails/blob/4-2-stable/activemodel/lib/active_model/dirty.rb#L206-L210))
и `changes_applied`
([source](https://github.com/rails/rails/blob/4-2-stable/activemodel/lib/active_model/dirty.rb#L200-L204))
наш `Hash` `@changed_attributes` очищается и становится пустым.

Одновременно с этим сохраняются и предыдущие изменения в переменной
`@previously_changed` тоже в виде `Hash`'а. В него переносятся текущие
несохраненные изменения при вызове метода `changes_applied`, который
должен вызываться при сохранении данных в базу данных. При вызове
`clear_changes_information` изменения аналогично очищаются.

При вызове `restore_attributes` всем измененным атрибутам присваиваются
оригинальные значения, которые были сохранены в `@changed_attributes`, и
изменения очищаются (вызывается метод `clear_changes_information`)
([source](https://github.com/rails/rails/blob/4-2-stable/activemodel/lib/active_model/dirty.rb#L188-L191)).

Все остальные публичные методы, как общие так и специфичные для
атрибутов, основываются на этих двух `Hash`'ах - `@changed_attributes` и
`@previously_changed`.

`ActiveModel::Dirty` также ожидает, что для атрибутов доступны и _getter'_ы, и
_setter'_ы (`attr_name` и `attr_name=`).

#### Проксирование специфичных для атрибута методов

Любопытно каким способом генерируются специфичные для атрибутов методы.
Например, для атрибута `title` будут доступны следующие методы:
* `title_changed?`
* `title_change`
* `title_will_change!`
* `title_was`
* `restore_title!`

Здесь `ActiveModel::Dirty` опирается на другой модуль
[`ActiveModel::AttributeMethods`](
https://api.rubyonrails.org/v4.2/classes/ActiveModel/AttributeMethods.html),
который умеет генерировать методы для атрибута, добавляя префиксы и
суффиксы к его имени. Собственно, метод `define_attribute_methods` из
инструкции по подключению `ActiveModel::Dirty` как раз и реализован в
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
а `title_will_change!` - к `attribute_will_change!(attr)`
([source](https://github.com/rails/rails/blob/4-2-stable/activemodel/lib/active_model/dirty.rb#L227-L237)).
Эти универсальные методы реализованы в `ActiveModel::Dirty` и выполняют
всю работу.

Это не описано явно в документации `ActiveModel::AttributeMethods`, но
можно не декларировать атрибуты вызовом `define_attribute_methods` если
добавить метод `#attributes`, который будет возвращать `Hash`, ключи в
котором - имена атрибутов. В этом случае сработает механизм основанный
на `method_missing`
([source](https://github.com/rails/rails/blob/4-2-stable/activemodel/lib/active_model/attribute_methods.rb#L428-L435)).
Несмотря на то, что методы для атрибутов не будут сгенерированы, если
имя вызываемого несуществующего метода соответствует имени атрибута
возвращаемого методом `#attributes` и зарегистрированному шаблону (с
суффиксом или префиксом
([source](https://github.com/rails/rails/blob/4-2-stable/activemodel/lib/active_model/attribute_methods.rb#L390-L416))),
то вызов будет проксирован к соответствующему общему методу
([source](https://github.com/rails/rails/blob/4-2-stable/activemodel/lib/active_model/attribute_methods.rb#L437-L443))
.

#### Генерация методов

Интерес представляет еще один трюк с генерацией методов. Все специфичные
атрибутам генерируемые методы при вызове `define_attribute_methods`
добавляются не в текущий класс или модуль, а в специальный анонимный
модуль (переменная `@generated_attribute_methods`), который подключается
в уже в сам модуль `ActiveModel::AttributeMethods`
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
    super.tap do |pair|
      pair[1] += ' [Customised]' if pair[1].present?
    end
  end
end

class Person
  include ActiveModel::Dirty
  include PersonConcern
  define_attribute_methods :first_name, :last_name

  def first_name
    @first_name
  end

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

Но если бы метод `first_name_change` при вызове
`define_attribute_methods` генерировался обычным способом, например
вызовом `define_method`, он бы добавлялся непосредственно в класс
`Person`и был бы недоступен в других модулях подключенных в `Person`.

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
Это позволяло переопределять тип атрибута ActiveRecord модели, вводить
новые пользовательские типы и регистрировать виртуальные атрибуты без
соответствующей колонки в таблице базы данных.

В Rails 5.2 этот функционал был перенесен из ActiveRecord в ActiveModel
(в этом [_pull request_'е](https://github.com/rails/rails/pull/30985)) что привело
к значительным изменениям в `ActiveModel::Dirty`. Теперь начали
отслеживаться как изменения обычных атрибутов зарегистрированных через
`ActiveModel::AttributeMethods` (вызовом метода
`define_attribute_methods`) так и изменения атрибутов созданных через
Attributes API (вызовом метода `attribute` из модуля
`ActiveModel::Attributes`). То есть вызовы `changes` или
`previous_changes`, например, вернут вперемешку и изменения атрибутов из
`ActiveModel::AttributeMethods` и атрибутов из `ActiveModel::Attributes`
([source](https://github.com/rails/rails/blob/5-2-stable/activemodel/lib/active_model/dirty.rb#L224)).

Изменения атрибутов `ActiveModel::AttributeMethods` аккумулируются все
так же в переменных `@attributes_changed_by_setter` и
`@previously_changed`. Если в итоговом классе подключен модуль
`ActiveModel::Attributes`, то изменения в атрибутах Attributes API
сохраняются в переменных `@mutations_from_database` и
`@mutations_before_last_save`
([source](https://github.com/rails/rails/blob/5-2-stable/activemodel/lib/active_model/dirty.rb#L323)).
В них хранится не обычных `Hash`, а трекер изменений - экземпляр класса
`ActiveModel::AttributeMutationTracker`
([source](https://github.com/rails/rails/blob/5-2-stable/activemodel/lib/active_model/attribute_mutation_tracker.rb#L6-L83)).
Так как трекер теперь вычисляет сделанные изменения на лету, это может
быть закешировано (в переменной `@cached_changed_attributes`
([source](https://github.com/rails/rails/blob/5-2-stable/activemodel/lib/active_model/dirty.rb#L234-L238))).

Факт подключения `ActiveModel::Attributes` определяется довольно
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

В Rails 5.0 появилось еще одно небольшое изменение в `ActiveModel::Dirty` -
добавили пару специфичных для атрибутов методов -
`<name>_previously_changed?` и `<name>_previous_change`:

```ruby
module ActiveModel
  module Dirty

    # ...
    included do
      attribute_method_suffix "_previously_changed?", "_previous_change"
    end

    # ...
  end
end
```
[source](https://github.com/rails/rails/blob/5-2-stable/activemodel/lib/active_model/dirty.rb#L130)

Таким образом мы получили две независимые реализации одного и того же
механизма. Поскольку ActiveRecord использует только новый, старый
механизм с `@attributes_changed_by_setter` и `@previously_changed` был
оставлен скорее для совместимости, так как `ActiveModel::Dirty` это
публичный интерфейс и он может использоваться вне ActiveRecord другими
библиотеками. В дальнейшем в Rails 6 были сделаны еще более серьезные
изменения.

### ActiveModel::Dirty в Rails 6.0

В Rails 6.0 один добрый фей пришел и сделал всем хорошо. Была
значительно улучшена производительность методов из модуля
`ActiveModel::Dirty` и согласно приведенным в _PR_ измерениям ускорение
получилось порядка 2х-10х ([pull
request](https://github.com/rails/rails/pull/35933)). Старый механизм
отслеживание изменений атрибутов (сгенерированных используя
`ActiveModel::AttributeMethods`) был вынесен в отдельный компонент -
`ForcedMutationTracker`
([source](https://github.com/rails/rails/blob/6-0-stable/activemodel/lib/active_model/attribute_mutation_tracker.rb#L84-L143)).

Ускорение было достигнуто за счет отказа от одновременного отслеживания
и атрибутов `ActiveModel::AttributeMethods` и атрибутов
`ActiveModel::Attributes`. Теперь если подключен модуль
`ActiveModel::Attributes`, то отслеживаются только его атрибуты. В
противном случае - только атрибуты `ActiveModel::AttributeMethods`
([source](https://github.com/rails/rails/blob/6-0-stable/activemodel/lib/active_model/dirty.rb#L240-L246)).
Следовательно стало невозможным использовать `ActiveModel::Dirty` в
классе, в котором для декларации атрибутов используются оба подхода - и
новый и старый.

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
несвязанной с `ActiveModel::Attributes` в произвольном классе не
связанном с ActiveRecord.

Изменение в Rails 6.0 вообще радикально меняет поведение. При наличие
переменной `@attributes` `ActiveModel::Dirty` перестает отслеживать
атрибуты `ActiveModel::AttributeMethods`.

Как очевидно, проблема не в нарушении обратной совместимости, а в том,
что это не документируется и делается неявно.

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
