---
layout: post
title:  "Что не так c документацией в Ruby"
date:   2019-07-06 23:35
categories: Ruby
---

_Updated on May 1, 2021_

Ruby это замечательный язык - он выразителен, мощен и эстетичен. Стандартная библиотека прекрасна - коллекции, замыкания и прочая функциональщина радуют глаз и ускоряют работу. А мощному и богатому языку нужна хорошая документация.

Взгляните на стандарт C++ ([draft](http://www.open-std.org/jtc1/sc22/wg21/docs/papers/2013/n3690.pdf)) - это же идеал перфекциониста. Полная и детальная спецификация библиотечных классов и функций. Описаны тончайшие детали поведения. И это следствие потребности индустрии - плохая документации обходится слишком дорого. Взгляните на документацию по Java ([Language Specification](https://docs.oracle.com/javase/specs/jls/se7/jls7.pdf), [API Specification](https://docs.oracle.com/javase/7/docs/api)) или в том же Python ([Language Reference](https://docs.python.org/3.4/reference/index.html), [Standard Library](https://docs.python.org/3/library)). Посмотрите на документацию по Go ([Language Reference](https://golang.org/ref/spec), [Standard Library](https://golang.org/pkg)) - там даже есть интерактивная _online_ консоль (в разделе [A Tour of Go](https://tour.golang.org/welcome/1)).

А теперь давайте вернемся к Ruby. Официальный ресурс проекта - [ruby-lang.org](https://www.ruby-lang.org). Хотя официальная документация по стандартной библиотеке находится на [docs.ruby-lang.org](https://docs.ruby-lang.org/), есть еще и независимый [ruby-doc.org](http://ruby-doc.org) с более приятным и функциональным дизайном и несколько других ресурсов ([apidock.com](https://apidock.com/), [rubydocs.org](https://rubydocs.org/)).

Недавно появился новый интересный сторонний проект [rubyapi.org](https://rubyapi.org) c RDoc документацией Ruby _Core-lib_ и _Std-lib_. Отличается приятным дизайном, удобным поиском с auto-suggestion. Примеры из документации можно запустить и выполнить прямо в браузере. Есть еще один экспериментальный подраздел, на который пока нет прямой ссылки с главной страницы, [онлайн Ruby REPL](https://rubyapi.org/repl), где можно поиграться с разными Ruby (CRuby 2.3-3.0, JRuby и даже Artichoke). Это самые настоящие Ruby, которые запускаются где-то в облаке (AWS Lambda, по-моему).

Официльный сайт ([ruby-lang.org](https://www.ruby-lang.org)) вроде бы современный и с приятным дизайном. Есть и документация по _Core-lib_ с _Std-lib_ и ссылки на _Getting Started_ и какие-то туториалы. Но если приглядеться повнимательнее, то появятся много "Но".


### Очевидные проблемы

1. Документация по _Std-lib_ сильно отстает по полноте и количеству примеров от _Core-lib_. За долгие года она превратилась в свалку странных подчас случайных и плохо документированных библиотек. И когда вам внезапно нужно сделать какую-то несложную вещь (например с OpenSSL) вы можете оказаться беспомощными и спасти может разве что эксперты на StackOverflow ([пример](https://stackoverflow.com/questions/1999096/digital-signature-verification-with-openssl) вопроса по OpenSSL).

2. Большая часть ссылок на туториалы и _Getting Started_ ведут на внешние ресурсы, которые годами не обновляются. Некоторые ссылки даже успели протухнуть.

3. Единственный раздел с синтаксисом языка, который находится на самом сайте [ruby-lang.org](https://www.ruby-lang.org), оказывается книгой ["Programming Ruby"](http://ruby-doc.com/docs/ProgrammingRuby/), первой редакцией, которая доступна в сети бесплатно. По полноте она недалеко ушла от туториалов и морально устарела еще лет 10 эдак назад.

4. Ruby можно потрогать _online_. Есть официальная страничка ["Try Ruby"](https://ruby.github.io/TryRuby/) с серией простых заданий, которые можно запускать прямо в браузере. Звучит отлично. Но это не настоящий Ruby. Это альтернативная реализация [Opal](https://opalrb.com/) сделанная на JavaScript, в которой доступно только подмножество как синтаксиса так и стандартных библиотек.


### Синтаксис

А теперь давайте откроем документацию по синтаксису Ruby.

Хм, не получается? Давайте поищем внимательнее.

Как это, нет такой документации?

Хмм. И вы совершенно правы. Официальной (и актуальной) документации по синтаксису Ruby не существует в природе. Единственный авторитетный источник который нам доступен - это книга Matz’а, автора языка, ["The Ruby Programming Language: Everything You Need to Know"](https://www.amazon.com/Ruby-Programming-Language-Everything-Need/dp/0596516177). Ее издали в далеком 2008 году еще до выхода Ruby 1.9, но тем не менее она покрывает и нововведения в 1.9. Сама книга прекрасна и определенно _must read_. Но это книжный формат, а не структурированная _online_ документация с перекрестными ссылками и поиском. К тому же это стоит денег. К тому же за последние 11 лет она ни разу не переиздавалась.

Кто-то может вспомнить, что существует стандарт Ruby [ISO/IEC 30170:2012](https://www.ipa.go.jp/files/000011432.pdf), который разрабатывали согласно требованиям японского правительства (т.е. их похоже вынудили, и это делалось не для, хм, сообщества). Он очень напоминает взрослые стандартны С++ и С, достаточно объемный (335 страниц) и описывает как синтаксис (формальная грамматика в виде [BNF](https://en.wikipedia.org/wiki/Backus%E2%80%93Naur_form)) так и _Core-lib_.

Но хотя стандарт принимался в 2012 году (а это было довольно давно), сам он создавался в 2010 и описывает только Ruby 1.8. За последние 9 лет (сейчас актуальная версия Ruby 2.6) и синтаксис и еще ,более _Core-lib_ заметно расширились сохраняя, правда, обратную совместимость. Больше половины сегодняшней _Core-lib_ в стандарте просто нет. Очевидно как и всей _Std-lib_.

Приведу пример BNF для `alias` оператора из этого стандарта:

```bnf
alias-statement ::
    alias new-name aliased-name

new-name ::
    defined-method-name
    | symbol

aliased-name ::
    defined-method-name
    | symbol
```

Если поискать в Google запрос "ruby syntax" то первой же ссылкой выдаст "Ruby Syntax - Ruby-Doc.org". Это [древний раздел](https://ruby-doc.org/docs/ruby-doc-bundle/Manual/man-1.4/syntax.html) "Ruby Language Reference Manual", который не обновлялся с 1998 года, и судя по URL описывает версию Ruby 1.4. Помню, именно по нему я когда-то сам знакомился Ruby. На удивление, он достаточно большой и пригодится даже спустя 20 лет. В конце есть даже [формальная грамматика](https://ruby-doc.org/docs/ruby-doc-bundle/Manual/man-1.4/yacc.html) в виде BNF. Ссылки на этот раздел нет ни на [ruby-doc.org](https://ruby-doc.org) ни на [ruby-lang.org](https://www.ruby-lang.org).

Есть еще один источник информации, на который обычно не обращают внимание, хотя он и представляет некоторый интерес. Прямо в _git_-репозитории Ruby в директории ["/doc"](https://github.com/ruby/ruby/tree/trunk/doc) лежат несколько разрозненных документов посвященных разным аспектам Ruby - синтаксис (_literals_, _assignment_, _modules and classes_ etc), стандартная библиотека (_regex_, _marshal_ etc) и общие вопросы (_security_, _globals_, _extensions_ etc). Эти статьи доступны как на [ruby-lang.org](https://docs.ruby-lang.org/en/2.6.0/) так и на [ruby-doc.org](https://ruby-doc.org/core-2.5.3/doc/).


### А зачем надо что-то еще?

Может возникнуть закономерная мысль: - "Я пишу на Rails и мне с головой хватает ее документации. И так все хорошо". Действительно, если решать шаблонные задачи собирая приложение из готовых _gem_'ов как из кубиков, тогда действительно хватит _Guide_'ов по Rails и документации по _Core-lib_ на всякий случай.

К сожалению, иногда этого мало и я сам не раз оказывался в тупике, когда не помогал ни Google, ни коллеги, ни чтение исходников.

Еще в далеком 2009 году я столкнулся с нехваткой документации. Это касалось обертки OpenSSL в Ruby _Std-lib_. Передо мной стояла простая задача - генерировать электронную подпись XML документов для исходящих запросов во внешнюю систему и проверять подпись во входящих ответах. Сложность была в том, что надо было использовать не стандартные SHA-256, MD5 или аналогичные хеш-функции, а сертификаты в специальных форматах и особые алгоритмы шифрования. Это было реализовано в OpenSSL и должно было быть доступным в Ruby. Но документация в _Std-lib_ оказалась практически [пустой](https://ruby-doc.org/stdlib-1.9.1/libdoc/openssl/rdoc/OpenSSL.html) и [бесполезной](https://ruby-doc.org/stdlib-1.9.1/libdoc/openssl/rdoc/OpenSSL/X509/Store.html), и поиск в Google не помог. В отчаянии была даже скачана книжка по OpenSSL но в итоге я отложил ее на неопределенный срок. Помощь пришла со StackOverflow, где я получил [отличный ответ](https://stackoverflow.com/questions/1999096/digital-signature-verification-with-openssl). Как и ожидалось, автор нашел нужную информацию в документации по самому OpenSSL. К слову, сейчас документация по OpenSSL в Ruby сильно дополнена и, хотя и не содержит готового ответа на мой вопрос, но есть [много примеров](https://ruby-doc.org/stdlib-2.6.3/libdoc/openssl/rdoc/OpenSSL.html) и уже есть от чего [отталкиваться](https://ruby-doc.org/stdlib-2.6.3/libdoc/openssl/rdoc/OpenSSL/X509/Store.html).

Я еще раз уткнулся носом в не задокументированное поведение уже не так давно, в 2016-м году, и уже в _Core-lib_. Мы стали получать странный _exception_ на тестовых серверах связанный с конкатенацией строк и несовместимыми кодировками, не вспомню уже точно детали. И оказалось, что в документации нигде не описано в каких случаях это исключение бросается. Засучив рукава я полез в исходники MRI и по дороге заблудился в дебрях Си-кода. Затем бросил взгляд на исходники Rubinius - там должны были быть чистые и красивые абстракции, понятный и простой код на  С++ и Ruby. Меня опять ждала неудача - наскоком не получилось найти место, где проверялась кодировка строк. Ответ я нашел только в проекте RubySpec, где четко и ясно простым английским языком были выписаны все варианты при конкатенации строк, в том числе и бросаемые исключения. Проблема была решена и баг побежден, но сколько на это ушло времени и сил…


### А теперь позитивные моменты

За последние годы документация по _Std-lib_ заметно дополнилась. Это видно невооруженным глазом на примере той же OpenSSL.

Начался процесс [_gem_-ификации](https://stdgems.org) - библиотеки из _Std-lib_ выносят в отдельные "стандартные" гемы, которые делятся в свою очередь на _default_ и _bundled_. Все "стандартные" _gem_-ы будут по прежнему доступны из коробки, но _default_ _gem_-ы будут разрабатываться Ruby _core team_, цикл разработки и релизов будет как у самого Ruby. А _bundled_ _gem_-ы будут поддерживаться непонятно кем, иметь свой цикл релизов и их можно будет обновлять вручную или даже удалять как самые обычные _gem_-ы. Думается, это должно снять нагрузку с Ruby _core team_ и может положительно повлиять и на качество документации.

Нельзя забывать, что появился проект [RubySpec](https://github.com/ruby/spec). Это набор тестов покрывающий синтаксис, _Core-lib_ и _Std-lib_. И хотя это не совсем обычная спецификация языка и предназначена она скорее для разработчиков самого Ruby, MRI и альтернативных реализаций (JRuby, TruffleRuby, Opal etc), тем не менее это полезный источник информации и для прикладных разработчиков. В данный момент в его поддержке и обновлении активно участвует Ruby _core team_.

Также среди всего хлама на [ruby-lang.org](https://www.ruby-lang.org) можно выделить ссылки на вполне годные ресурсы и статьи:

* [Practicing Ruby](https://practicingruby.com/)
* [Academic Research](https://rubybib.org/)
* [Ruby From Other Languages](https://www.ruby-lang.org/en/documentation/ruby-from-other-languages/)
* [Ruby Koans](http://rubykoans.com) ([Github-репозиторий](https://github.com/edgecase/ruby_koans))

К сожалению этот список очень неполный и не исчерпывает существующие отличные ресурсы посвященные Ruby.


### К чему же можно стремиться?

А теперь мои 5 копеек на тему, что же такое хорошая документация языка программирования.

Вместо кучи ссылок на сторонние устаревшие туториалы - новые актуальные обновляемые разделы:
1. _Getting started_ - раздел с кратким введением
2. _Language Reference_ - всеобъемлющий раздел с описанием синтаксиса и его семантики в строгом стиле ISO стандарта с примерами и пояснениями (в объеме книги Matz'а по Ruby)
3. Формальное описание грамматики в виде BNF

Любые примеры в документации должны быть _runnable_ _online_ на настоящей версии Ruby. Возможно ли запустить полноценную MRI на WebAssembly - это хороший вопрос. Такие попытки уже были, правда до конца ни одну не довели (например [runrb.io](https://runrb.io)).

Документация в _Core-lib_ и _Std-lib_ - в строгом стиле ISO стандарта. Сейчас это скорее правило опускать подробное формальное описание и взамен приводить только лаконичные примеры или краткие схемы ([пример](https://ruby-doc.org/core-2.5.3/Array.html#method-i-pack), [еще один](https://ruby-doc.org/core-2.5.3/Kernel.html#method-i-format) и [еще](https://ruby-doc.org/core-2.5.3/Kernel.html#method-i-spawn)). В документации _Std-lib_ заполнены пробелы примерами и пояснениями.


### Что можем сделать мы, Ruby сообщество

Во-первых, можно улучшить документацию по _Core-lib_ и _Std-lib_. Она генерируется из комментариев в исходниках Ruby используя _rdoc_. Чтобы обновить эти комментарии, как впрочем и сделать любое изменение в самом Ruby, нужно создать _issue_ и прикрепить _patch_ на [Ruby Issue Tracking System](https://bugs.ruby-lang.org/) ([_guide_](https://ruby-doc.org/core-2.5.3/doc/contributing_rdoc.html)). Есть даже специальный ресурс (ныне немного запрошенный) для предварительного _review_ изменений в документации [documenting-ruby.org](http://documenting-ruby.org/).

Во-вторых, можно принять участие в сторонних проектах по созданию нового _Language Reference_, например [_The Ruby Reference_](https://rubyreferences.github.io/rubyref/).

И наконец, можно поучаствовать в проекте [RubySpec](https://github.com/ruby/spec), добавляя новые или улучшая существующие тесты. Каждый год выходит новый релиз Ruby с многочисленными обновлениями библиотек, которые требуют и обновления тестов.


### Вместо послесловия

Нужно ли такие улучшения документации сообществу? Однозначно да. Нужно ли это индустрии? Мы видим, что пока не очень.

Увидим ли мы значительные улучшения в ближайшем будущем? Я сильно сомневаюсь в этом. И пока за Ruby не будет стоят какая-нибудь серьезная компания вроде Google/Facebook/Mozilla Foundation/Oracle или целый комитет по стандартизации ничего радикально не изменится.

Как-то так все грустно (.


[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
