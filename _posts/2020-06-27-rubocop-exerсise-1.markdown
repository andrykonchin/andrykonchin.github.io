---
layout:     post
title:      Rubocop. Фиксим баг
date:       2020-06-27 14:01
categories: Ruby Rubocop
---

На днях у меня получилось влезть коготком в один из самых интересных
проектов на Ruby - Rubocop. Если кто-то не сталкивался - это
Ruby-линтер. Нет, не совсем так. Это целый фреймворк для разработки
своих правил и проверок - он умеет статически анализировать исходных код
на Ruby, проверяет (по умолчанию) правила из [Ruby Style
Guide](https://rubystyle.guide/) и может даже автоматически
корректировать/исправлять исходники - убирать лишние пробелы, заменять
`unless` на `if` итд.

Парсеры, лексеры, синтаксический анализ, AST итд интересовали меня еще
со времен университета и сейчас появилась возможность немножко
позаниматься этой темой.

Для разработчиков новых правил и автокоррекций (_cop_'ов в терминах
Rubocop) есть [официальная
документация](https://docs.rubocop.org/rubocop/0.85/development.html).
Но она, как обычно, весьма краткая и бедному разработчику приходится
лезть в потроха и разбираться самому. Неудивительно, что в сети
периодически появляются статьи с примерами разработки новых _cop_'ов.
Привел ссылки на такие статьи в конце поста.

В этом посте я расскажу о своем первом опыте с Rubocop. Я исправил багу
в одном из _cop_'ов для Minitest - есть такая библиотека _unit_-тестов,
конкурент RSpec'а. И пришлось немного повозиться и поразбираться как же
работают Rubocop, _cop_'ы, шаблоны и как это тестировать.

И так, начнем.

### Предыстория

В одном из open source проектов, которыми я занимался, для тестов
использовали Minitest. Это странный выбор как по мне, так как RSpec
умеет и больше и лучше. Да и вообще - кто слышал об этом Minitest? Я
хотел исправить многочисленные _deprecation warning_'и, которые
появились после выхода очередной минорной версии Minitest, и попробовал
автокоррекцию RuboCop. Для Minitest в Rubocop есть отдельный плагин
`rubocop-minitest`.

К моему удивлению, автокоррекция исправила далеко не все места, где
выдавались _warning_'и. Это определенно была бага. "Отличная возможность
познакомиться с Rubocop” - подумал я. И вместо того, чтобы зарепортить
_issue_ в проекте, начал фиксить багу сам.

Автокоррекцию выполнял _cop_ `Minitest/GlobalExpectations`. Он находит
вызовы _deprecated_ методов (глобальных матчеров `must_equal`,
`wont_match` итд) и заменяет на новый DSL, например:

```ruby
# bad
musts.must_equal expected_musts

# good
_(musts).must_equal expected_musts
```

Давайте разберем как `Minitest/GlobalExpectations` работает.


### Cop Minitest/GlobalExpectations

Точка входа в _cop_
([source](https://github.com/rubocop-hq/rubocop-minitest/blob/v0.8.0/lib/rubocop/cop/minitest/global_expectations.rb)) -
это _callback_ `on_send`:

```ruby
def on_send(node)
  return unless global_expectation?(node)

  message = format(MSG, preferred: preferred_receiver(node))
  add_offense(node, location: node.receiver.source_range, message: message)
end
```

Rubocop использует паттерн Visitor, а каждый _cop_ реализует один или
несколько _callback_'ов для конкретных типов узлов AST дерева. Rubocop
обходит AST дерево и по очереди вызывает _callback_'и из всех _cop_'ов
которые соответствуют текущему узлу. `on_send` _callback_ будет вызван
для всех узлов типа _send_. Узел _send_, как можно догадаться,
соответствует вызову Ruby-метода. Узел передается в _callback_
аргументом `node`.

Каждому токену в Ruby коде соответствует свой тип узла AST дерева и,
соответственно, свой _callback_. Приведем примеры:
* on_def - узел с определением метода
* on_class - узел с определением класса
* on_module - узел с определением модуля
* on_block - узел с литералом блока `{}` или `do`/`end`
* on_if - узел с `if` выражением
* on_ensure - узел с секцией `ensure`
* on_const - узел с константой (`FooBar`)
* on_hash - узел с литералом `Hash`
* on_array - узел с литералом `Array`

Полный список _callback_'ов можно найти в документации _gem_'а `parser`
([тыц](https://whitequark.github.io/parser/Parser/AST/Processor.html#on_send-instance_method))

AST дерево для узла _send_ выглядит примерно так:

<img src="/assets/images/2020-06-27-rubocop-exerсise-1/send-node.svg"/>

В этом дереве корень - узел _send_. У него есть дочерние узлы:
- объект, на котором вызван метод, _receiver_
- имя метода
- аргумент (или список аргументов)

Например, для выражения `obj.must_equal expected` с вызовом метода и
передачей аргумента получится следующее AST дерево:

```
(send
  (send nil :obj)
  :must_equal
  (send nil :expected))
```

где:
- _receiver_ - это `(send nil :obj)`
- имя метода - `:must_equal`
- и аргумент - `(send nil :expected))`

<img src="/assets/images/2020-06-27-rubocop-exerсise-1/matcher-node.svg"/>

Логика метода `on_send` очень проста. Он проверяет является ли текущий
_send_-узел вызовом глобального матчера - `must_be_empty`, `must_equal`,
`must_be_close_to`,  `must_be_within_delta` ...

```ruby
return unless global_expectation?(node)
```

Если проверка успешная и найден _deprecated_ метод, то _cop_
регистрирует ошибку (_offence_):

```ruby
add_offense(node, location: node.receiver.source_range, message: message)
```

Метод `global_expectation?` довольно интересный. Он определен необычным
способом используя "макрос" `def_node_matcher`:

```ruby
def_node_matcher :global_expectation?, <<~PATTERN
  (send {
    (send _ _)
    ({lvar ivar cvar gvar} _)
    (send {(send _ _) ({lvar ivar cvar gvar} _)} _ _)
  } {#{MATCHERS_STR}} ...)
PATTERN
```

Где `MATCHERS_STR` - это перечисленные через пробел Minitest матчеры -
`:must_be_empty`, `:must_equal`, `:must_be_close_to`...

Этот макроc генерирует метод с именем `global_expectation?`, который
проверяет соответствует ли узел заданному шаблону. В Rubocop реализован
свой собственный механизм шаблонов, похожий на регулярные выражения,
который применяется к AST дереву.

Приведенный шаблон соответствует узлу _send_, у которого _receiver_
соответствует следующему шаблону:

```
{
  (send _ _)
  ({lvar ivar cvar gvar} _)
  (send {(send _ _) ({lvar ivar cvar gvar} _)} _ _)
}
```

`{}` означает логическое ИЛИ т.е. _receiver_ это или вызов метода (без
аргумента) или переменная (`foo`, `@foo`, `@@foo`) или цепочка из
нескольких вызовов.

Далее идет шаблон для имени метода:

```
{#{MATCHERS_STR}}
```

Это разворачивается в следующий список имен матчеров:

```
{:must_be_empty :must_equal :must_be_close_to ...}
```

Далее идут аргументы. Они должны соответствовать подшаблону `...`, что
означает любая последовательность узлов в том числе и пустая.


### В чем же была ошибка?

Приведенный выше шаблон для _receiver_ слишком специфичный и упускает
целый ряд выражений. Для следующих выражения, например, он не сработает:

```ruby
response[1]['X-Runtime'].must_match /[\d\.]+/

::File.read(::File.join(@def_disk_cache, 'path', 'to', 'blah.html')).must_equal @def_value.first

Rack::Contrib.must_respond_to(:release)
```

Рассмотрим последний из примеров выше:

```ruby
Rack::Contrib.must_respond_to(:release)
```

Ему соответствует следующее AST дерево:

```
(send
  (const
    (const nil :Rack) :Contrib)
  :must_respond_to
  (sym :release))
```

_Receiver_ `(const (const nil :Rack) :Contrib)` ни коим образом не
соответствует подшаблону для _receiver_'а. Это и не вызов метода, и не
переменная и не цепочка вызовов.


### Решение

Решение было достаточно простым. Самый тривиальный и общий шаблон вполне
неплохо справляется:

```
(send !(send nil? :_ _) {#{MATCHERS_STR}} ...)
```

Он проверяет, что вызывается глобальный матчер и _receiver_ не похож на
новый DSL в формате `_(musts).must_equal expected_musts`.

Конечно, дальше возникают нюансы и не все так уж просто. Есть два типа
матчеров - для результата выражения и для блока кода. Например:

```ruby
obj.foo.must_equal :bar
```

и

```ruby
-> { obj.foo }.must_raise ArgumentError
```

AST деревья для этих выражений сильно отличаются и для них нужны разные
шаблоны:

```
(send
  (send
    (send nil :obj) :foo) :must_equal
  (sym :bar))
```

и

```
(send
  (block
    (lambda)
    (args)
    (send
      (send nil :obj) :foo)) :must_raise
  (const nil :ArgumentError))
```

В новом DSL надо оборачивать проверяемое выражение в `_(obj)`. Но
поддерживаются и алиасы для `_` - методы `value` и `expect`, которые
могут сделать код нагляднее и читабельнее:

```ruby
_(obj.foo).must_equal :bar
value(obj.foo).must_equal :bar
expect(obj.foo).must_equal :bar
```

Поэтому итоговые решение выглядело немного сложнее:

```ruby
# There are aliases for the `_` method - `expect` and `value`
DSL_METHODS_LIST = %w[_ value expect].map do |n|
  ":#{n}"
end.join(' ').freeze

def_node_matcher :value_global_expectation?, <<~PATTERN
  (send !(send nil? {#{DSL_METHODS_LIST}} _) {#{VALUE_MATCHERS_STR}} _)
PATTERN

def_node_matcher :block_global_expectation?, <<~PATTERN
  (send
    [
      !(send nil? {#{DSL_METHODS_LIST}} _)
      !(block (send nil? {#{DSL_METHODS_LIST}}) _ _)
    ]
    {#{BLOCK_MATCHERS_STR}}
    _
  )
PATTERN

def on_send(node)
  return unless value_global_expectation?(node) || block_global_expectation?(node)

  message = format(MSG, preferred: preferred_receiver(node))
  add_offense(node, location: node.receiver.source_range, message: message)
end
```

### Шаблоны для AST

Давайте немного поговорим о механизме шаблонов. Документация рекомендует
использовать именно его для работы с AST, хотя всегда остается
возможность манипулировать узлами напрямую. Интерпретатор шаблонов
реализован в классе `NodePattern`
([source](https://github.com/rubocop-hq/rubocop-ast/blob/master/lib/rubocop/ast/node_pattern.rb))
и был недавно вынесен в отдельный gem `rubocop-ast`.

По шаблонам на данный момент можно почитать только два официальных
документа:
- <https://www.rubydoc.info/gems/rubocop-ast/0.0.3/RuboCop/AST/NodePattern> и
- <https://github.com/rubocop-hq/rubocop-ast/blob/1899234a41c399aa9a445b9bb44716815fda5559/docs/modules/ROOT/pages/node_pattern.adoc>

В них очень мало примеров и мне пришлось потыкаться вслепую и
экспериментировать занимаясь новым шаблоном. Покопавшись в документации
и исходниках я набросал вот такой скриптик, чтобы проверять
соответствует ли шаблон Ruby коду или нет:

```ruby
require 'rubocop'

source = "-> { obj.foo }.must_raise ArgumentError"
pattern = '(send _ :must_raise _)'

processed_source = RuboCop::AST::ProcessedSource.new(source, 2.7)
node_pattern = RuboCop::NodePattern.new(pattern)
node_pattern.match(processed_source.ast) # => true | nil
```

С помощью класса `RuboCop::AST::ProcessedSource` парсим Ruby код.
Результирующее AST дерево можно получить вызвав метод `ast`. Создаем
шаблон `RuboCop::NodePattern` и далее вызов метода `match` вернет `true`
в случае успеха и `nil` иначе.

### Заключение

Багу я пофиксил и [мой
PR](https://github.com/rubocop-hq/rubocop-minitest/pull/72) вмержили.
Пусть это и не основной репозиторий Rubocop'а, а всего лишь официальный
плагин, все равно это маленький _win_.

Несмотря на то, что я таки познакомился с Rubocop, не получилось
поманипулировать AST узлами напрямую без шаблонов. Остались вопросы по
типам AST-узлов, порядку обхода AST-дерева итд. Это все не описано в
документации и здесь Rubocop сильно полагается на _gem_ `parser`.
Абстракции все таки текут и в таком популярном проекте как Rubocop.

### Статьи о разработке новых cop'ов:

- <https://downey.io/blog/writing-rubocop-linters-for-database-migrations/>
- <https://mwallba.io/custom-rubocops-to-support-code-reviews/>
- <https://blog.sideci.com/overview-and-implementation-of-performance-regexpmatch-cop-afe58d2c5ed3>
- <https://medium.com/@DmytroVasin/how-to-add-a-custom-cop-to-rubocop-47abf82f820a>
- <https://kirshatrov.com/2016/12/18/rewrite-code-with-rubocop/>

### Ссылки

- <https://docs.rubocop.org/rubocop/0.85/development.html>
- <https://www.rubydoc.info/gems/rubocop-ast/0.0.3/RuboCop/AST/NodePattern>
- <https://github.com/rubocop-hq/rubocop-ast/blob/1899234a41c399aa9a445b9bb44716815fda5559/docs/modules/ROOT/pages/node_pattern.adoc>
- <https://github.com/whitequark/parser/blob/master/doc/AST_FORMAT.md>


[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
