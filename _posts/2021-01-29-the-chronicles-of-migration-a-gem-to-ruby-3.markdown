---
layout:     post
title:      Хроника перевода gem'а на Ruby 3.0
date:       2021-02-16 00:53
categories: Ruby
---

На новогодние праздники я традиционно беру неделю отпуска и, как
правило, не выдерживаю столько свободного времени сразу и нахожу что
поковырять и попилить. В этот раз я уделил время своим проектам -
Dynamoid и RubySpec. Всегда надо что-то доделать, дополировать или
дописать в документации. Давно пора было выкатывать новую версию
Dynamoid ведь последний релиз вышел еще полгода назад, а обычно
версии выходят каждые 3-4 месяца.

На днях вышел Ruby 3.0 да и свежая версия Rails (6.1) только месяц как
появилась. Хотелось быстренько позапускать на них тесты и добавить в
Changelog строчку о поддержке и совместимости. Новые версии Ruby обычно
заводятся без проблем ведь _breaking changes_ довольно редки. С Rails
возникала сложности, но постепенно Dynamoid все меньше и меньше зависит от
Rails.

Ничего не предвещало беды и я планировал быстро все закончить - добавить
новые версии в матрицу конфига CI, дождаться пока пройдет билд и
обновить Changelog. Но меня ждали сюрпризы.


### Проблема с keyword arguments

Сразу же всплыла проблема с _keyword arguments_. В Ruby 3.0 сломали
обратную совместимость и немного изменили этот механизм. Это
исчерпывающе описано в статье [The Delegation Challenge of Ruby
2.7](https://eregon.me/blog/2019/11/10/the-delegation-challenge-of-ruby27.html).
К сожалению просмотрев материал наискосок несколько раз я так до конца и
не разобрался в теме. За что пришлось заплатить временем и понаступать
на описанные там грабли. После нескольких заходов у меня наконец
сложился пазл и родилось финальное решение.

Можно сколько угодно упрекать Matz'а в костыльности подхода с новым
методом `ruby2_keywords`, но это закрывает бОльшую часть вариантов
использования. К сожалению этот подход не работает для Dynamoid.
Интересно почему Matz не посмотрел в сторону аннотаций в комментариях,
как это варят в Java?


### Проблема с RSpec

Также выяснилось, что RSpec не готов к переходу на Ruby 3, хотя
_deprecation warning_'и появились еще в Ruby 2.7 и времени хватало.

Один тест в Dynamoid упал на Ruby 3.0 и виновником оказался
`rspec-mock`. Ошибку легко воспроизвести комбинацией вызовов `receive` и
`and_call_original`:

```ruby
expect(object).to receive(:foo).and_call_original
```

Более полный пример:

```ruby
it 'reproduces the issue' do
  object = Object.new
  def object.foo(a:, b:)
    [a, b]
  end

  expect(object).to receive(:foo).and_call_original
  object.foo(a:1, b: 2)
end
```

Это падает где-то в недрах `rspec-mock`:

```
ArgumentError:
  wrong number of arguments (given 1, expected 0; required keywords: a, b)
# ..._spec.rb:428:in `foo'
# .../gems/3.0.0/gems/rspec-mocks-3.10.1/lib/rspec/mocks/message_expectation.rb:101:in `call'
# .../gems/3.0.0/gems/rspec-mocks-3.10.1/lib/rspec/mocks/message_expectation.rb:101:in `block in and_call_original'
# .../gems/3.0.0/gems/rspec-mocks-3.10.1/lib/rspec/mocks/message_expectation.rb:740:in `call'
# .../gems/3.0.0/gems/rspec-mocks-3.10.1/lib/rspec/mocks/message_expectation.rb:572:in `invoke_incrementing_actual_calls_by'
...
```

Этот конкретный баг уже починен [вот
здесь](https://github.com/rspec/rspec-mocks/pull/1385). Вчера. Хотя
[issue](https://github.com/rspec/rspec-mocks/issues/1306) открыли еще
год назад. Парень из _core team_ пояснил в комментариях, что не хватает
тестов на сам RSpec, которые бы проверяли работу с _keyword arguments_.
А _core team_ занимается следующим мажорным релизом RSpec 4. Как это
возможно, спросите? Я тоже не понимаю.

Писали в _issues_ и о других местах, где RSpec падает на Ruby 3.0.
Остается только ждать релиза с фиксами или даже исправлять самому.


### Проблема со старыми версиями Rails

Последние версии Rails 6.0.x и 6.1.x без проблем взлетели на Ruby 3.0. А
вот с Rails 5 уже сложнее. Rails 5.2 и Rails 5.1 не работают на Ruby 3.0
([issue](https://github.com/rails/rails/issues/40938)).

Согласно [политике
поддержки](https://guides.rubyonrails.org/maintenance_policy.html) _core
team_ Rails исправляют баги только в текущей минорной версии (Rails 6.1).
Правки к остальным версиям примут только в
особых случаях. Поэтому если Rails 5.2 и Rails 5.1 не работают на Ruby
3.0, то уже ничего не поделаешь. Учитывая, что минорные версии Rails
выходят в среднем раз в год, выходит, что баги в текущей версии будут
чиниться только один год пока не выйдет следующая минорная версия.

Я бы упрекнул _core team_ Rails только в том, что нет явной таблицы
совместимости версий Rails и Ruby. Единственное что поможет - это на
каких версиях запускают тесты на CI. До Rails 6.1 использовали TravisCI
([конфига](https://github.com/rails/rails/blob/6-0-stable/.travis.yml#L69-L71))
и затем перешли на <https://buildkite.com/rails/rails>.


### Проблема с Rails 4.2

Заодно решил вернуться к Rails 4.2 и перепроверить с какими версиями
Ruby Rails совместимы. До сих пор Rails 4.2 гонялся на CI только на
версиях Ruby с 2.3 по 2.6. Возможно я добьюсь, чтобы Rails 4.2 завелось
и на поздних версиях?

На Ruby 2.7 Rails 4.2 сломалась. В Ruby удалили метод
`BigDecimal.new`, который использовали в Rails. Так как
Rails 4.2 уже не поддерживалась, это не исправили. Выяснилось, что это
решается без _monkey-patch_'а. `BigDecimal` вынесли в
самостоятельный _default bundled gem_, который поставляется вместе с
Ruby по умолчанию но релизится по независимому графику. Нашел версию `bigdecimal`, в
котором метод `BigDecimal.new` еще не удалили, и подключил вместо
штатной версии.

Согласно [документации](https://github.com/ruby/bigdecimal) нужная
версия `bigdecimal` (без _breaking changes_, 1.4.x) работает только до
Ruby 2.6. Но Rails 4.2 завелась и на Ruby 2.7 в том числе. А
вот на Ruby 3.0 уже вылетает на уровне бинарников:

```
dyld: lazy symbol binding failed: Symbol not found: _rb_check_safe_obj
  Referenced from: .../lib/ruby/gems/3.0.0/gems/bigdecimal-1.4.4/lib/bigdecimal.bundle
  Expected in: flat namespace

dyld: Symbol not found: _rb_check_safe_obj
  Referenced from: .../lib/ruby/gems/3.0.0/gems/bigdecimal-1.4.4/lib/bigdecimal.bundle
  Expected in: flat namespace
```

Любопытна ситуация с JRuby. Dynamoid поддерживает JRuby но запускаем
тесты только на текущей версии, которая соответствует Ruby 2.6. Поэтому
проблемы с Rails 4.2 пока нет и не нужно устанавливать нештатную версию
`bigdecimal`. Так как `bigdecimal` содержит _native extension_ - его
нельзя завести на JRuby. Для удобства и совместимости файлов
*.gemspec/Gemfile пользователям JRuby нужна версия _gem_'а на RubyGems и
для JRuby. Хотя бы в виде заглушки.

Этому посвящен отдельный
[тикет](https://bugs.ruby-lang.org/issues/6590) на багтрекере Ruby.
Любопытно, что Ruby _core team_ игнорирует его последние 8 лет. Не
ответили ничего по существу ни лиду из JRuby 8 лет назад, ни лиду из
TruffleRuby год назад. Более того, они позволяют себе следующее:

> So, No. Please drop f*cking insane idea. It doesn work at all.

Чтобы прекратить поддержку какой-либо версии Rails надо анализировать
статистику использования или хотя бы скачиваний с RubyGems. Но даже не
глядя на числа очевидно, что Rails 4.2 используется в проектах. Не так
давно даже выкатывали [релиз с security
фиксом](https://weblog.rubyonrails.org/2020/5/15/Rails-4-2-11-2-has-been-released/).
А с год назад видел в одном проекте Rails 4.2 на продакшене. И не смотря
ни на что команда не спешила обновлять Rails.


### PS

На то, чтобы разобраться в теме, ушел день. И в
результате Dynamoid заводится на Ruby 3.0 и на Rails 6.1. Также
начал тестировать _gem_ с Rails 4.2 на Ruby 2.7 и JRuby. И хотя разборки
с _keyword arguments_ я откладывал до последнего момента все-таки
пришлось погружаться.

Ситуация с поддержкой старых версий Rails конечно неожиданная и сильно
меня удивила. Желающих законтрибутить в Rails много и я думал, что у
_core team_ хватает ресурсов на поддержку старых версий. У Ruby
_core team_ получается поддерживать релизы по 3-4 года, а у Rails _core
team_ - только 1 год.


[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
