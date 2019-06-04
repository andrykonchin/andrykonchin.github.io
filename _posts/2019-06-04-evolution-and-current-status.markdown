---
layout:     post
title:      "Refinemets в Ruby: эволюция и текущий статус"
date:       2019-06-04 23:54
categories: Ruby
---

Refinements были добавлены в Ruby 2.0 в далеком 2013 году и должны были помочь улучшить модульность кода и сделать расширения классов и модулей более безопасными. Refinements позволяют задавать область видимости для _monkey-patch_, делать его локальным и скрывать для остального приложения. Это в первую очередь важно для разработчиков библиотек и позволяет избежать конфликтов между их _monkey-patch_'ами.

Следующий пример (из документации) иллюстрирует синтаксис:

```ruby
class C
end

module M
  refine C do
    def foo
      puts "C#foo in M"
    end
  end
end

using M

x = C.new
x.foo       # prints "C#foo in M"
```

#### Начальная концепция Shugo Maeda

Впервые Refinements были представлены на RubyConf 2010 в докладе Shugo Maeda ([видео](https://www.youtube.com/watch?v=4r-QUaOJlgA)). Качество звука плохое, докладчик не очень опытный и просто читает слайды, поэтому можно сразу к ним и перейти ([слайды](https://www.slideshare.net/ShugoMaeda/rc2010-refinements)). Стоит смотреть видео с 15:30 (33-й слайд), когда докладчик переходит к существующим аналогичным решениям в других языках и переходит, собственно, к синтаксису Refinements.

Shugo Maeda называет следующие существующие решения:
* _selector namespace_
    * SmallScript (.Net), ECMAScript 4
    * Lexically scoped
* _classboxes_
    * Squeak, Java (non-official extention)
    * Dynamically scoped (called local rebinding)

Семантика Refinements описывается следующим образом:

Module#refine:
* `refine(klass, &block)`
* additional or overriding methods of class are defined in block
    * a set of such methods is called a refinement
* activated only in the receiver module and scoped where the module is imported by `using`
* `refine` can also be invoked on classes

Module#using:
* `using(mod)`
* `using` imports refinements defined in mod
* refinements are activated only in a file, module, class or method where `using` is invoked
    * lexically scoped
* supports reopen and inheritance

Refinements предназначены для:
* Refinements of build-in classes
* Internal DSLs
* Nested methods

В основных чертах это не сильно отличается от финальной версии Refinements, хотя есть и мелкие несоответствия. На пример, в этой ранней версии:
* можно переоткрывать только классы,
* перед `using` нужно явно подключить модуль через `include`

#### Проработка концепции

Бурные обсуждение новой фичи, ее синтаксиса и особенностей начались в том же 2010 году. В этом приняли участие Shugo Maeda, Matz и другие сочувствующими лица. Отметился Jeremy Evans, разработчик Sequel и много чего другого, и Charles Nutter, ведущий разработчик JRuby. Все это вылилось в достаточно длинный [тред](https://bugs.ruby-lang.org/issues/4085), чтение которого весьма доставляет, хотя и требует времени.

Через два года в декабре 2012 стало окончательно понятно, что новая фича слишком сложна и с ней связано слишком много неясностей и нюансов. Как кто-то прокомментировал: "Если уж разработчики самого Ruby не понимают, как это должно работать, то как же быть обычным людям?". Например, были неясности в работе методов рефлексии, наследования и подключение модулей, области видимости. Трудно было оценить влияние на производительность.

Несмотря на предложения отложить релиз фичи на следующую версию Ruby 2.1 Matz настоял на включении Refinements в ближайший релиз Ruby 2.0 хотя и в сильно урезанном виде:
* `using` is only allowed at top level.
* refined methods are called only after `using`.
* or within blocks given to `refine`.
* if you pass the proc to `refine` e.g. `refine(C,&b)` refined methods may not be called from b. It's implementation dependent.
* refinements are not available in subclasses, nor in reopened classes/modules.
* refinements are not available from `module_eval`/`class_eval`.

В таком виде Refinements были зарелизины в Ruby 2.0 в 2012 году и в Release Notes попал следующий абзац:

> “In addition, albeit as an experimental feature, 2.0.0 includes Refinements, which adds a new concept to Ruby's modularity.”

#### Дальнейшее развитие

В череде следующих релизах регулярно появлялись доработки и исправления связанные с Refinements.

##### Ruby 2.1 (2013-12-25)

Refinements  перестала быть экспериментальной фичей. Убрали ограничение на использование `using` только в _top level_ контексте. Теперь Refinemets можно подключать в любом модуле и классе.

Из [_feature changes list_](https://github.com/ruby/ruby/blob/v2_1_0/NEWS):

*  The method (`main.using`) activates refinements in the ancestors of the argument module to support refinement inheritance by `Module#include`.
* (New method:) `Module#using`, which activates refinements of the specified module only in the current class or module definition

##### Ruby 2.4 (2016-12-25)

Значительным улучшением стала возможность _refine_'ить не только классы но и модули. _Core team_ перешла к полировке фичи. Начата (но не закончена) работа над поддержкой специфичных случаях - непрямые вызова методов (`Symbol#to_proc`, ...), `Kernel#binding` etc.

Из [_feature changes list_](https://github.com/ruby/ruby/blob/v2_4_0/NEWS):

* Refinements is enabled at method by `Symbol#to_proc`.
* Refinements is enabled with `Kernel#send` and `BasicObject#__send__`.
* `Module#refine` accepts a module as the argument now

##### Ruby 2.5 (2017-12-25)

Продолжена работа над поддержкой особых случаев - в этот раз добавлена только поддержка в интерполяции строк.

Из [_feature changes list_](https://github.com/ruby/ruby/blob/v2_5_0/NEWS):

* refinements take place in string interpolations.

##### Ruby 2.6 (2018-12-25)

Продолжена работа на поддержкой непрямых вызовов методов и передачи блока (`&:symbol`)

Из [_feature changes list_](https://github.com/ruby/ruby/blob/v2_6_0/NEWS):

* Refinements take place at block passing.
* Refinements take place at `Kernel#public_send`.
* Refinements take place at `Kernel#respond_to?`.

##### Ruby 2.7 (еще не зарелизен)

Хотя это и не попало в [список изменений](https://www.ruby-lang.org/en/news/2019/05/30/ruby-2-7-0-preview1-released/) для _preview_ версии, но были устранены последние недоработки. Добавили поддержку Refinements в следующих методах:

* `Kernel#method`
* `Kernel#instance_method`

С выходом Ruby 2.7 мы получим наконец завершенную фичу готовую к использованию, несмотря на ряд известных багов ([#14744](https://bugs.ruby-lang.org/issues/14744), [#14012](https://bugs.ruby-lang.org/issues/14012), [#13752](https://bugs.ruby-lang.org/issues/13752), [#13446](https://bugs.ruby-lang.org/issues/13446), [#11704](https://bugs.ruby-lang.org/issues/11704), [#9580](https://bugs.ruby-lang.org/issues/9580))

#### Заключение

Как видим, фича получилась весьма сложной. Достаточно только посмотреть на тесты проекта RubySpec ([`Module#using`](https://github.com/ruby/spec/blob/master/core/module/using_spec.rb), [`Module#refine`](https://github.com/ruby/spec/blob/master/core/module/refine_spec.rb)) и станет ясно, как много разных сложных комбинаций и вариантов применения можно найти и _Principle Of Least Surprise_ здесь ни разу не помогает. Предположить навскидку, как должны вести себя Refinements в нетривиальной ситуации достаточно непростая задача. К счастью Refinements нужны в очень редких случаях.

Если прикинуть, то понадобилось 8 лет, чтобы закончить эту фичу, хотя все еще есть некоторые шероховатости. В JRuby Refinements были добавлены только в последнем [релизе](https://www.jruby.org/2019/04/09/jruby-9-2-7-0.html). А в коде Rails `refine`/`using` [применили сравнительно недавно](https://github.com/rails/rails/blob/571f0f32c645a563b915ac8fcb1f9b3eb764da11/activesupport/lib/active_support/core_ext/enumerable.rb#L119) - в версии Rails 5.1 вышедшей в 2017 году.

Таким образом, Refinements до сих пор не нашла широкого применения даже среди популярных библиотек и остается редко используемой маргинальной фичей языка.

#### Полезные ссылки

* [Yehuda Katz "Ruby 2.0 Refinements in Practice"](https://yehudakatz.com/2010/11/29/ruby-2-0-refinements-in-practice/)
* [Актуальная документация (Ruby 2.6)](http://ruby-doc.org/core-2.6/doc/syntax/refinements_rdoc.html)
* [Alexandre Bergel. Scoping Changes with Method Namespaces](http://bergel.eu/download/SelectorNamespaceEssay.pdf)
* [Alexandre Bergel, Stephane Ducasse, and Roel Wuyts. Classboxes: A Minimal Module Model Supporting Local Rebinding](http://scg.unibe.ch/archive/papers/Berg03aClassboxes.pdf)
* [Тред #4085 с обсуждением с Matz](https://bugs.ruby-lang.org/issues/4085)
* [RubySpec: Module#using](https://github.com/ruby/spec/blob/master/core/module/using_spec.rb)
* [RubySpec: Module#refine](https://github.com/ruby/spec/blob/master/core/module/refine_spec.rb)

[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
