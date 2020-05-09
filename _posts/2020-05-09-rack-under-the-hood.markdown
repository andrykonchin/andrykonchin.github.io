---
layout:     post
title:      Препарируем Rack
date:       2020-05-09 00:01
categories: Ruby
---

Давайте поговорим немного о Rack. Rack - это важная часть Ruby веб-стека
и, де-факто, стандарт общения между веб-сервером и приложением. Все
Ruby-сервера, например Puma, Unicorn или Thin, передают HTTP запросы
приложению и получают обратно ответы именно по Rack интерфейсу. Обычно,
правда, приложение ничего об этом не знает - обо всем уже позаботился
какой-нибудь фреймворк вроде Rails или Sinatra.

Но если Rack это просто спецификация, контракт между сервером и
приложением, тогда зачем нужен еще и _gem_ `rack`? Какая у него роль и
почему его подключают веб-сервера и фреймворки? Давайте разбираться. Но
сначала немного матчасти.


### Содержание
{:.no_toc}

* A markdown unordered list which will be replaced with the ToC, excluding the "Contents header" from above
{:toc}


### Спецификация Rack

Rack-интерфейс на самом деле довольно прост. Приложение - это объект с
методом `call`. Метод `call` принимает HTTP-запрос и возвращает
HTTP-ответ. Веб-сервер отдает запрос приложению в виде `Hash`'а, который
по конвенции называют `env`. Ответ должен быть в виде массива из трех
элементов - статус (200 или 500, к примеру), заголовки и тело ответа.
Заголовки возвращаются в виде списка пар имя-значение, а тело ответа -
это список строк (такой подход с телом запроса иногда нужен, чтобы
стримить данные - отправлять их клиенту по частям).

Полную спецификацию можно найти
[здесь](https://github.com/rack/rack/blob/2-2-stable/SPEC.rdoc).


#### Пример middleware

Давайте напишем простое Rack-приложение.

Мы создадим файл `config.ru` - это стартовая точка любого
Rack-приложения. Имя файла может быть любым, но по конвенции веб-сервер
ожидает найти именно такой файл. Определим наше приложение в виде
_lambda_. У нее как у любого объекта класса `Proc` есть метод `call` и
поэтому она подходит для нашей цели:

```ruby
app = lambda do |env|
  [200, { 'Content-Type' => 'text/plain' }, ['Hello']]
end

run app
```

Это приложение на любой запрос возвращает статус 200, строчку 'Hello' и
заголовок 'Content-Type'. Запустить это приложение можно в консоле
командой `rackup`, которая идет в составе _gem_'а:

```
$ rackup --port 5000
```

Если выполнить следующий HTTP запрос в консоли командой `curl`, то
приложение, ожидаемо, ответит нам "Hello":

```
$ curl http://0.0.0.0:5000/foo/bar\?q\=qwerty -d 'Hi'
Hello
```

А теперь посмотрим, как же выглядит HTTP запрос:

```ruby
{
  "rack.version"=>[1, 3],
  "rack.errors"=>"#<Rack::Lint::ErrorWrapper:0x00007fc0e2166a98>",
  "rack.multithread"=>true,
  "rack.multiprocess"=>false,
  "rack.run_once"=>false,
  "SCRIPT_NAME"=>"",
  "QUERY_STRING"=>"q=qwerty",
  "SERVER_PROTOCOL"=>"HTTP/1.1",
  "SERVER_SOFTWARE"=>"puma 4.3.3 Mysterious Traveller",
  "GATEWAY_INTERFACE"=>"CGI/1.2",
  "REQUEST_METHOD"=>"POST",
  "REQUEST_PATH"=>"/foo/bar",
  "REQUEST_URI"=>"/foo/bar?q=qwerty",
  "HTTP_VERSION"=>"HTTP/1.1",
  "HTTP_HOST"=>"0.0.0.0:5000",
  "HTTP_USER_AGENT"=>"curl/7.54.0",
  "HTTP_ACCEPT"=>"*/*",
  "CONTENT_LENGTH"=>19,
  "CONTENT_TYPE"=>"application/x-www-form-urlencoded",
  "SERVER_NAME"=>"0.0.0.0",
  "SERVER_PORT"=>5000,
  "PATH_INFO"=>"/foo/bar",
  "REMOTE_ADDR"=>"127.0.0.1",
  "rack.hijack?"=>true,
  "rack.hijack"=>
   "#<Proc:0x00007fc0e2166c78 .../ruby/gems/2.7.0/gems/rack-2.2.2/lib/rack/lint.rb:567>",
  "rack.input"=>"#<Rack::Lint::InputWrapper:0x00007fc0e2166ae8>",
  "rack.url_scheme"=>"http",
  "rack.after_reply"=>[],
  "rack.tempfiles"=>[]
}
```

Здесь смешаны несколько групп параметров:
* мета-переменные
* заголовки
* служебные параметры

Мета-переменные запроса - это версия HTTP протокола, метод (POST, GET
итд), путь и _query_-параметры из URL:

* `"HTTP_VERSION"=>"HTTP/1.1"`
* `"SCRIPT_NAME"=>""`
* `"QUERY_STRING"=>"q=qwerty"`
* `"SERVER_PROTOCOL"=>"HTTP/1.1"`
* `"SERVER_SOFTWARE"=>"puma 4.3.3 Mysterious Traveller"`
* `"GATEWAY_INTERFACE"=>"CGI/1.2"`
* `"REQUEST_METHOD"=>"POST"`
* `"REQUEST_PATH"=>"/foo/bar"`
* `"REQUEST_URI"=>"/foo/bar?q=qwerty"`
* `"SERVER_NAME"=>"0.0.0.0"`
* `"SERVER_PORT"=>9292`
* `"PATH_INFO"=>"/foo/bar"`
* `"REMOTE_ADDR"=>"127.0.0.1"`
* `"CONTENT_LENGTH”=>19`
* `"CONTENT_TYPE"=>"application/x-www-form-urlencoded"`

Еще передаются HTTP-заголовки с характерной приставкой `HTTP_` в имени.
Хотя мы и не указывали заголовки, `curl` добавил их сам:

* `"HTTP_HOST"=>"0.0.0.0:9292"`
* `"HTTP_USER_AGENT"=>"curl/7.54.0"`
* `"HTTP_ACCEPT"=>"*/*"`

Может казаться странным, что `CONTENT_LENGTH` и `CONTENT_TYPE`
передаются как мета-переменные, а не заголовки с приставкой `HTTP_`.
Rack здесь следует стандарту CGI, который описан в [RFC
3875](https://tools.ietf.org/html/rfc3875#section-4.1).

Есть еще одна группа служебных параметров с приставкой `rack.`:

* `"rack.version"=>[1, 3]`
* `"rack.errors"=>"#<Rack::Lint::ErrorWrapper:0x00007fc0e2166a98>"`
* `"rack.multithread"=>true`
* `"rack.multiprocess"=>false`
* `"rack.run_once"=>false`
* `"rack.hijack?"=>true`
* `"rack.hijack"=>"#<Proc:0x00007fc0e2166c78 .../ruby/gems/2.7.0/gems/rack-2.2.2/lib/rack/lint.rb:567>"`
* `"rack.input"=>"#<Rack::Lint::InputWrapper:0x00007fc0e2166ae8>"`
* `"rack.url_scheme"=>"http"`
* `"rack.after_reply"=>[]`

К примеру, `rack.input` - это тело запроса. А параметры `rack.hijack?` и
`rack.hijack` связаны с очень необычной фичей _socket hijacking_.
Приложение может работать с сетевым сокетом напрямую и как читать так и
писать в него. Таким образом, оно может использовать другой отличный от
HTTP протокол, например _websocket_'ы. Детальнее об этом написано
[здесь](https://github.com/rack/rack/blob/2-2-stable/SPEC.rdoc#label-Hijacking).


#### Интерфейсы в спецификации

Наверняка вы заметили один нюанс. Тело запроса это не строка и не
массив, а какой-то странный объект `Rack::Lint::InputWrapper`. В самом
деле, Rack-спецификация не требует использовать конкретные классы
(`Hash` или, например, `Array`). Спецификация описывает интерфейс
объектов, т.е. какие методы они должны поддерживать. Например, тело
запроса должно быть `IO`-like объектом и реализовывать методы `gets`,
`each`, `read` and `rewind`. Это может быть, к примеру, `StringIO` или
`File` или любой произвольный класс, удовлетворяющий этому интерфейсу.

Спецификация требует, чтобы:
* статус ответа поддерживал метод `to_i`, который возвращает числовое
  значение (например, 200 или 404)
* заголовки в ответе не обязательно возвращать в виде `Hash`'а. Этот
  объект должен реализовать только метод `each` и итерировать по парам
  ключ-значение
* тело ответа тоже не обязано быть именно массивом, объектом класса
  `Array`. Этот объект должен поддерживать метод `each` и итерировать по строкам -
  частям тела ответа. Опционально этот объект может иметь и
  другие методы - `to_path` и `close`.


### Gem rack

Перейдем теперь к самому _gem_'у `rack`. Один из его авторов, Leah
Neukirchen, в статье [Introducing
Rack](http://leahneukirchen.org/blog/archive/2007/02/introducing-rack.html)
пишет, что Rack это с одной стороны спецификация, а с другой - решения
стандартных задач веб-приложения и способ их комбинации.

Если заглянуть в
[исходники](https://github.com/rack/rack/tree/2-2-stable/lib/rack)
_gem_'а, то можно выделить несколько категорий файлов, которые, к
сожалению, не подчеркнуты структурой директорий:
* middlewares
* инструменты для веб-серверов и фреймворков
* инструменты для разработки новых middlewares


#### Middlewares

Rack предлагает подход, когда приложение использует уже готовые
компоненты для обработки запроса. Эти компоненты (фильтры или
_middleware_) образуют цепочку и по очереди обрабатывают входящий запрос
перед тем как передать его приложению. _Middleware_ имеют стандартный
интерфейс. Если вынести какую-то логику приложения в отдельное
_middleware_, то его можно повторно использовать в другом приложении на
другим фреймворке и запускать на другом веб-сервере.

Рассмотрим простое _middleware_. Оно ничего не делает и просто вызывает
следующий _middleware_ (`app`):

```ruby
class SimpleMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    # analize request
    status, headers, body = @app.call(env)
    # analize response

    [status, headers, body]
  end
end
```

В _gem_ `rack` входит большая коллекция уже готовых _middleware_.
Приведем несколько примеров:
* Rack::CommonLogger - логирует все входящие запросы в формате
  веб-сервера Apache
* ConditionalGet - возвращает ответ с 304 HTTP статусом без тела, если у браузера уже
  закешированна актуальная версия документа, после проверки заголовков
  `If-None-Match` и `If-Modified-Since`
* ContentLength - выставляет заголовок ContentLength если приложение
  это не сделало
* Directory - файловый браузер для заданной директории на сервере -
  можно просматривать содержимое директорий и файлов
* ETag - вычисляет хеш-сумму используя SHA256 и добавляет заголовок
  `ETag`
* Lock - предотвращает параллельное выполнение запросов - теперь они
  выполняются по очереди один за одним. Это полезно если запускать
  потоко-небезопасное приложение на многопоточном веб-сервере, таком как
  Puma.

Этот подход с цепочкой _middleware_ используют не только в приложениях
но также и во фреймворках. Например, в Rails реализовали [целую
пачку](https://github.com/rails/rails/tree/master/actionpack/lib/action_dispatch/middleware)
_middleware_. Rails также использует несколько _middleware_ из состава
`rack`:
* Rack::Sendfile
* Rack::Cache
* Rack::Lock
* Rack::Runtime
* Rack::MethodOverride
* Rack::Head
* Rack::ConditionalGet
* Rack::ETag
* Rack::TempfileReaper

Кроме коллекции _middlewares_ в Rack и Rails есть множество готовых
_middleware_ в виде отдельных _gem_'ов. Перечислим несколько самых
популярных:
* `warden` (аутентификация, используется в Devise)
* `rack-timeout`
* `rack-attack`
* `rack-reverse-proxy`
* `rack-cors`


#### Интеграция с серверами и фреймворками


Перейдем к следующей группе - инструменты для разработчиков веб-серверов
и фреймворков.


##### Rack::Server
<https://github.com/rack/rack/blob/2-2-stable/lib/rack/server.rb>

Вы не задумывались, как команда `rackup` запускает приложение?  Ведь
должен запускаться полноценный веб-сервер. Конечно же, есть `Webrick` из
стандартной библиотеки Ruby. Но он не поддерживает Rack-спецификацию.

Для этого в составе `rack` есть класс `Rack::Server`, который и
запускает приложение на, к примеру, сервере `Webrick`. Под капотом
команда `rackup` как раз и использует `Rack::Server`
([source](https://github.com/rack/rack/blob/2-2-stable/bin/rackup)):

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require "rack"
Rack::Server.start
```

Сервер анализирует параметры командной строки, которые передали в
`rackup`. Он поддерживает много опций, например `--daemonize` для
запуска сервера в фоновом режиме. Можно указать порт (`--port`) и хост
(`--host`), на которых запустить веб-сервер. Можно даже указать какой
именно веб-сервер использовать опцией `--server`.

Сервер можно запустить и программно. По-умолчанию он пытается загрузить
приложение из файла `config.ru` (путь к файлу и имя можно задать опцией
`:config`).  Можно указать приложение явно передав опцию `:app` (пример
из [документации](https://www.rubydoc.info/gems/rack/Rack/Server)):

```ruby
Rack::Server.start(
  :app => lambda do |e|
    [200, {'Content-Type' => 'text/html'}, ['hello world']]
  end
)
```

Сервер также можно использовать и для отладки _middleware_ (например
`Rack::ShowExceptions`) используя приложение-заглушку:

```ruby
require 'rack'

app = lambda do |e|
  [200, {'Content-Type' => 'text/html'}, ['hello world']]
end

Rack::Server.start(
  app: Rack::ShowExceptions.new(app), Port: 9292
)
```

Занятно, что команда Rails `rails server` под капотом тоже использует
`Rack::Server`
([source](https://github.com/rails/rails/blob/6-0-stable/railties/lib/rails/commands/server/server_command.rb)).


##### Rask::Handler
<https://github.com/rack/rack/blob/2-2-stable/lib/rack/handler.rb>

Мы уже знаем, что `Rack::Server` может запускать разные веб-серверы. Для
этого в Rack есть адаптеры (или иначе - _handler_'ы) для поддерживаемых
веб-серверов. Адаптеры программно настраивают и запускают веб-сервер
передавая ему конфигурацию и само приложение.

Из коробки доступны следующие адаптеры:
* [CGI](https://github.com/rack/rack/blob/2-2-stable/lib/rack/handler/cgi.rb)
* [FastCGI](https://github.com/rack/rack/blob/2-2-stable/lib/rack/handler/fastcgi.rb)
* [SCGI](https://github.com/rack/rack/blob/2-2-stable/lib/rack/handler/scgi.rb)
* [Thin](https://github.com/rack/rack/blob/2-2-stable/lib/rack/handler/thin.rb)
* [Webrick](https://github.com/rack/rack/blob/2-2-stable/lib/rack/handler/webrick.rb)
* [LiteSpeed Web Server](https://github.com/rack/rack/blob/2-2-stable/lib/rack/handler/lsws.rb)

Так же есть адаптеры к другим веб-серверам в отдельных _gem_'ах. Например, для:
* [Puma](https://github.com/puma/puma/blob/master/lib/rack/handler/puma.rb)
* [PhusionPassenger](https://github.com/phusion/passenger/blob/stable-6.0/src/ruby_supportlib/phusion_passenger/rack_handler.rb)
* [Falcon](https://github.com/socketry/falcon/blob/master/lib/rack/handler/falcon.rb)
* [iodine](https://github.com/boazsegev/iodine/blob/master/lib/rack/handler/iodine.rb)
* [Unicorn](https://github.com/samuelkadolph/unicorn-rails/blob/master/lib/unicorn_rails.rb)
* и других [Unicorn-like серверов](https://github.com/godfat/rack-handlers/tree/master/lib/rack/handler).

Если сервер явно указан, то `Rack::Server` пытается загрузить его
адаптер из следующего списка - Puma, Thin, Falcon и Webrick. Обратите
внимание, что в этом списке нет Unicorn'а.

```ruby
Rack::Server.start(app: app, server: :puma)
```

Запустить веб-сервер программно с определенным адаптером можно и
напрямую без `Rack::Server`:

```ruby
require 'rack'

app = lambda do |e|
  [200, {'Content-Type' => 'text/html'}, ['hello world']]
end

Rack::Handler::Thin.run app
```


##### Rack::Builder
<https://github.com/rack/rack/blob/2-2-stable/lib/rack/builder.rb>

Наверняка, глядя на примеры файла `config.ru`, вы задавались вопросом, а
что это за метод `run app`:

```ruby
app = lambda do |env|
  [200, { 'Content-Type' => 'text/plain' }, ['Hello']]
end

run app
```

Очевидно, что это не стандартный метод из класса `Object`, раз он
запускает Rack-приложение. На самом деле метод `run` - это метод класса
`Rack::Builder`, а код из файла `config.ru` выполняется в контексте
объекта этого класса. `Rack::Builder` используют для сборки
Rack-приложения из составляющих - приложения и _middleware_.

В нем доступны следующие методы:

__#use__

Добавляет еще одно _middleware_ в цепочку. Теперь любой HTTP запрос
сначала будет обработан этим _middleware_ и только потом дойдет до
приложения.

```ruby
use Rack::ShowExceptions
run lambda { |env| [200, { "Content-Type" => "text/plain" }, ["OK"]] }
```

__#run__

Задает конечное приложение

```ruby
run lambda { |env| [200, { "Content-Type" => "text/plain" }, ["OK"]] }
```

__#map__

Это такой себе наколенный роутинг. Можно задать _path_ и
Rack-приложение, которое будет обрабатывать все запросы по этому
_path_'у.

```ruby
Rack::Builder.app do
  map '/heartbeat' do
    run Heartbeat
  end
  run App
end
```

Для вложенного приложения можно настроить свой независимый стек
_middleware_ используя `use`.

__#warmup__

Разогревает приложение перед началом обработки запросов.

```ruby
warmup do |app|
  client = Rack::MockRequest.new(app)
  client.get('/')
end
```

__#freeze_app__

Замораживает (вызывает метод `freeze`) приложение и все
входящие в него _middleware_.

```ruby
freeze_app
```

Никто не запрещает использовать `Rack::Builder` напрямую в `config.ru`,
например вот так:

```ruby
app = Rack::Builder.app do
  use Rack::CommonLogger
  run lambda { |env| [200, {'Content-Type' => 'text/plain'}, ['OK']] }
end

run app
```

Думаю, что `Rack::Builder` удобен разве что для маленьких
Rack-приложений без использования какого-либо фреймворка. Уже для Rails
его не хватает и там используют свой навороченный билдер
`ActionDispatch::MiddlewareStack`
([source](https://github.com/rails/rails/blob/master/actionpack/lib/action_dispatch/middleware/stack.rb)).

Давайте посмотрим, как загружается файл `config.ru`. До текущей версии
Rack v2.2 использовали следующую примитивную реализацию
([source](https://github.com/rack/rack/blob/2-1-stable/lib/rack/builder.rb#L64-L67)):

```ruby
def self.new_from_string(builder_script, file = "(rackup)")
  eval "Rack::Builder.new {\n" + builder_script + "\n}.to_app",
    TOPLEVEL_BINDING, file, 0
end
```

Сейчас уже используют более хитрый способ
([source](https://github.com/rack/rack/blob/2-2-stable/lib/rack/builder.rb#L110-L118)):

```ruby
# Evaluate the given +builder_script+ string in the context of
# a Rack::Builder block, returning a Rack application.
def self.new_from_string(builder_script, file = "(rackup)")
  # We want to build a variant of TOPLEVEL_BINDING with self as
  # a Rack::Builder instance.
  # We cannot use instance_eval(String) as that would resolve constants
  # differently.

  binding, builder = TOPLEVEL_BINDING.eval(
    'Rack::Builder.new.instance_eval { [binding, self] }'
  )
  eval builder_script, binding, file
  builder.to_app
end
```

Интересно, как же `Rack::Builder` используют веб-серверы. Он нужен как
минимум, чтобы загрузить файл `config.ru`.

Посмотрим на Unicorn. Он файл загружают самостоятельно и делает
вызов `Rack::Builder.new`
([source](https://github.com/defunkt/unicorn/blob/5.4-stable/lib/unicorn.rb#L56)):

```ruby
eval("Rack::Builder.new {(\n#{raw}\n)}.to_app", TOPLEVEL_BINDING, ru)
```

В Puma наоборот используют вспомогательный метод `Rack::Builder.parse_file`,
который появился в `rack` уже довольно давно
([source](https://github.com/puma/puma/blob/4.3.3/lib/puma/configuration.rb#L321)):

```ruby
rack_app, rack_options = rack_builder.parse_file(rackup)
```

Непонятно зачем, но в Puma есть своя обрезанная копия `Rack::Builder`
([source](https://github.com/puma/puma/blob/4.3.3/lib/puma/rack/builder.rb#L129-L300)).
Ее используют, если не получается подключить файл с `Rack::Builder`
([source](https://github.com/puma/puma/blob/4.3.3/lib/puma/configuration.rb#L295-L316)).


#### Разработка middleware

В состав _gem_'а входят также вспомогательные классы, которые упрощают
разработку и тестирование новых _middleware_. Давайте их кратко
разберем.


##### Rack::Request
<https://github.com/rack/rack/blob/2-2-stable/lib/rack/request.rb>

Это всем нам знакомый по Rails объект `request`. `Rack::Request` - это
тонкая обертка над исходным `env` и позволяет работать ним как с
объектом используя многочисленные _getter_'ы. Также у него есть
несколько удобных предикатов.

Наприме, следующий HTTP-запрос

```
curl http://0.0.0.0:5000/foo/bar\?q\=qwerty -d 'Hi'
```

превращается в такой `request`:

```ruby
request = Rack::Request.new(env)

request.body            # => #<Rack::Lint::InputWrapper:0x00007ffa193313d0>
request.body.read       # => Hi
request.path            # => /foo/bar
request.request_method  # => POST
request.query_string    # => q=qwerty
request.content_length  # => 2
request.user_agent      # => curl/7.54.0
request.scheme          # => http
request.host            # => 0.0.0.0
request.post?           # => true
request.get?            # => false
request.GET             # => {"q"=>"qwerty"}
request.POST            # => {"Hi"=>nil}
request.params          # => {"q"=>"qwerty", "Hi"=>nil}
```

Из полезного он еще умеет парсить:
* _Query_ строку,
* POST-параметры
* _Multipart_ тело запроса
* _Cookies_
* а также заголовки `Accept-Encoding` и `Accept-Language`.

`Rack::Request` учитывает `X_FORWARDED_` заголовки и используют довольно
сложную логику, чтобы получить IP адрес HTTP клиента.


##### Rack::Response
<https://github.com/rack/rack/blob/2-2-stable/lib/rack/response.rb>


`Rack::Response` помогает сформировать HTTP-ответ - можно удобно задать
заголовки и тело ответа. Также есть _setter_'ы для некоторых заголовков.

Приведем пример:

```ruby
response = Rack::Response.new(['Hello'], 200, {})
response.content_type = 'text/plain'
response.etag = 'v58.1.0'
response.set_header('Expires', 'Wed, 21 Oct 2015 07:28:00 GMT')
response.set_header('Age', '24')
response.set_cookie('id', '56817838490203423')
response.finish # => [status, headers, body]
```

В результате выходит вот такой HTTP ответ:

```
HTTP/1.1 200 OK
Content-Type: text/plain
ETag: v58.1.0
Expires: Wed, 21 Oct 2015 07:28:00 GMT
Age: 24
Set-Cookie: id=56817838490203423
Content-Length: 5

Hello
```

Еще можно сформировать ответ с редиректом:

```ruby
response = Rack::Response.new
response.redirect('https://wikipedia.org/wiki/CGI')
response.finish # => [status, headers, body]
```

Он выставляет статус 302 по-умолчанию и заголовок `Location`:

```
HTTP/1.1 302 Found
Location: https://wikipedia.org/wiki/CGI
Content-Length: 0
```

Rack из коробки поддерживает стриминг данных, когда очередной фрагмент
вычисляется на лету, а общая длина ответа заранее не известна. В
`Rack::Response` для этого есть метод `finish`, который принимать
опционально блок, и используя метод `write` можно досылать клиенту
очередной фрагмент ответа.

В примере ниже приложение отдает ответ с заголовком `Transfer-Encoding:
chunked` - он выставляется автоматически если не задали тело ответа до
вызова `finish`. Чтобы стриминг действительно заработал и не
буферизировался сервером, сервер должен поддерживать стриминг. Puma как
раз один из таких серверов.

Здесь мы шлем несколько строчек в специальном _chunked_-формате с
задержкой в 1 секунду перед отправкой каждой строки:

```ruby
response = Rack::Response.new

response.finish do |r|
  (1..10).each do |i|
    message = "line ##{i}"
    size = message.size.to_s(16)

    r.write("#{size}\r\n")
    r.write("#{message}\r\n")

    sleep 1
  end

  r.write("0\r\n")
  r.write("\r\n")
end
```

Запустим Puma вот такой командой (с `rackup` по какой-то причине
стриминг не заработал):

```
$ puma --port 5000 config.ru
```

Чтобы `curl` не буферизировал ответ и выводил каждый фрагмент сразу при
получении надо указать опцию `--no-buffer`:

```
$ curl --no-buffer http://0.0.0.0:5000
7
line #1
7
line #2
7
line #3
7
line #4
7
line #5
7
line #6
7
line #7
7
line #8
7
line #9
8
line #10
0
```

Каждая строка выводится с интервалом в 1 секунду.


##### Rack::BodyProxy
<https://github.com/rack/rack/blob/2-2-stable/lib/rack/body_proxy.rb>

Это простой декоратор для тела ответа. Он позволяет вызвать _callback_ в
конце после отправки всего тела ответа.

Так, например, можно освободить блокировку в `Rack::Lock`
([source](https://github.com/rack/rack/blob/v2.2.2/lib/rack/lock.rb#L19)):

```ruby
returned = response << BodyProxy.new(response.pop) { unlock }
```

или прологировать запрос в `Rack::CommonLogger`
([source](https://github.com/rack/rack/blob/v2.2.2/lib/rack/common_logger.rb#L40)):

```ruby
body = BodyProxy.new(body) { log(env, status, headers, began_at) }
```

Обычно его используют, чтобы просто закрыть оригинальный _body_ если его
подменяют другим, как требует спецификация:

```ruby
body = Rack::BodyProxy.new(new_body) do
  original_body.close if original_body.respond_to?(:close)
end
```


##### Rack::Utils::HeaderHash
<https://github.com/rack/rack/blob/v2.2.2/lib/rack/utils.rb#L413-L497>

`Rack::Utils::HeaderHash` это _case-insensitive_ `Hash`. Несмотря на то,
что он помечен как приватное _api_, он весьма полезен при разработке
_middleware_.

По стандарту имя HTTP-заголовка может быть в любом регистре. И это
совершенно корректно, если приложение вернет вместо `Content-Type`
что-нибудь вроде `content-type` или `CONTENT-TYPE`. Об этом легко забыть
и ожидать в ответе заголовки в традиционном _camel case_ формате.
`Rack::Utils::HeaderHash` как раз и решает эту проблему. Если обернуть
заголовки ответа в этот класс, то можно забыть о проблеме с регистром.

```ruby
headers = Rack::Utils::HeaderHash.new(
  "content-type" => "application.json", "Etag" => "v1"
)
headers # => {"content-type"=>"application.json", "Etag"=>"v1"}

headers["content-type"] # => "application.json"
headers["CONTENT-TYPE"] # => "application.json"

headers["content-TYPE"] = "application/xml"
headers["content-type"] # => "application/xml"
```

Более того, по спецификации объект с заголовками ответа должен
реализовывать только метод `each` и, следовательно, с ним нельзя
работать как с обычным `Hash`'ом.  Здесь опять приходит на помощь
`Rack::Utils::HeaderHash` - он реализует несколько методов обычного
`Hash`'а - `[]`, `[]=`, `key?`, `has_key?`, `include?` и др.

`Rack::Utils::HeaderHash` поддерживает еще одну возможность. Если
приложению нужно вернуть несколько значений одного и того же
заголовка (например, для `Set-Cookies`) то можно вернуть одну строку,
которая содержит все значения заголовка разделенные символом новой
строки "\n". А уже веб-сервер сам это разделит обратно и сформирует
корректный ответ. `Rack::Utils::HeaderHash` помогает задать
такое множественное значение заголовка в виде массива, который в итоге
конвертируется в строку с символом разделителем "\n":

```ruby
h = Rack::Utils::HeaderHash[{}]
h['Set-Cookes'] = ['a', 'b']

h.to_hash # => {"Set-Cookes"=>"a\nb"}
```


##### Rack::Lint
<https://github.com/rack/rack/blob/2-2-stable/lib/rack/lint.rb>

Это обычный _middleware_, который проверяет корректность приложения или
_middleware_ и соответствие Rack-спецификации. Используется в
юнит-тестах на _middleware_.

`Rack::Lint` проверяет запрос (объект `env`) по следующим критериям:
* Это объект класса `Hash`
* Не _frozen_
* Должен содержать все мета-переменные с валидными значениями
* `rack.input` (тело запроса) должен:
    * реализовывать все обязательные методы (`gets`, `each`, `read`,
    `rewind`)
    * `gets`/`read` должны возвращать строки
    * `each` должен итерировать по строкам
* `rack.error` должен реализовывать методы `puts`, `write`, `flush`

`Rack::Lint` проверяет ответ по следующим критериям:
* Это `Array` из трех элементов
* Статус конвертируется в число методом `to_i` и находится в допустимом
  диапазоне значений (> 100)
* Заголовки:
    * Объект с заголовками поддерживает метод `each`
    * Все ключи - строки
    * Имена заголовков не содержат префикс `rack.`
    * Имена заголовков должны соответствовать
      [RFC7230](https://tools.ietf.org/html/rfc7230), состоять только из
      печатный символов и не содержать запрещенные спецсимволы
      ((),/:;<=>?@[\]{})
    * Значения - строками
    * В ответе нет заголовков `Content-Type` и `Content-Length` если
      статус ответа 1xx, 204 или 304
* Тело ответа:
    * Реализует метод `each`
    * Состоит из коллекции строк
    * Общая длина в байтах соответствует заголовку `Content-Length`
    * Если реализован метод `to_path`, то этот файл существует


##### Rack::MockRequest
<https://github.com/rack/rack/blob/2-2-stable/lib/rack/mock.rb#L22>

Используется в юнит-тестах _middleware_.

Предполагается тестировать _middleware_ двумя способами. В одном из них
используя метод `env_for` можно сгенерировать запрос (`env`-объект) со
всеми обязательными параметрами и заголовками. Далее можно вызвать метод
`call` на тестируемом _middleware_ и проверить ответ и изменения в
`env`:

```ruby
env = Rack::MockRequest.env_for("/?_method=delete", method: "GET")
status, headers, body = app.call env

env["REQUEST_METHOD"].must_equal "GET"
```

Во втором подходе `Rack::MockRequest` оборачивает собой _middleware_
(`app`) и имитирует HTTP-запросы. В результате возвращается объект
класса `Rack:MockResponse`. Тот в свою очередь содержит в себе ответ
_middleware_ и позволяет работать с ним через удобные _getter_'ы:

```ruby
res = Rack::MockRequest.new(app).get("/foo")

res.must_be :ok?
res["X-ScriptName"].must_equal "/foo"
res["X-PathInfo"].must_equal ""
res.body.must_equal ""
```


#### Утилиты

В _gem_'е есть также вспомогательные классы:
* `Rack::Mime` - определяет MIME type (например, "image/png”) по
  расширению файла
* `Rack::MediaType` - парсит `Content-Type` заголовок и возвращает MIME
  type и параметры. Например для "text/plain;charset=utf-8" вернется MIME
  type "text/plain" и параметры `{'charset' => 'utf-8'}`
* `Rack::Multipart` - парсит _multipart_ запрос
* `Rack::QueryParser` - парсит _query_ параметры из URL; поддерживает
  вложенные параметры, например `"foo[]=1&foo[]=2"`
* `Rack::RewindableInput` - обертка над `rack.input` объектом;
  `rack.input` обязан поддерживать метод `rewind`, перемотку в самое
  начало тела запроса; `Rack::RewindableInput` реализует `rewind`
  буферизируя данные и, таким образом, можно превратить не-*rewindable*
  объект в корректный *rewindable*.
* `Rack::Utils` - коллекция вспомогательных методов.


#### Демо

И напоследок. В состав _gem_'а входит маленькая демка - Rack-приложение
`Rack::Lobster`
([source](https://github.com/rack/rack/blob/v2.2.2/lib/rack/lobster.rb)),
которое выводит изображение лобстера (морского рака - видимо это такой
каламбур) в ASCII-арте. Если нажать на ссылку "flip", то лобстер
повернется в другую сторону.

Чтобы запустить демку надо клонировать git-репозиторий и выполнить
команду:

```shell
$ rackup example/lobster.ru
```

В результате получим вот такую страницу:

<img src="/assets/images/2020-05-09-rack-under-the-hood/lobster.png" style="width: 80%; margin-left: auto; margin-right: auto;" />


### Резюме

Давайте подытожим, зачем же нужен _gem_ `rack`. Во-первых, это большая
коллекция Rack _middleware_. Во-вторых, он нужен для загрузки файла
`config.ru`, стартовой точки Rack-приложения. И в-третьих, в нем
есть инструменты для разработки и тестирования новых _middlewares_.


### Ссылки

- <https://github.com/rack/rack/blob/2-2-stable/SPEC.rdoc>
- <https://tools.ietf.org/html/rfc3875>
- <http://leahneukirchen.org/blog/archive/2007/02/introducing-rack.html>
- <https://guides.rubyonrails.org/rails_on_rack.html>
- <https://blog.sqreen.com/fixing-a-critical-issue-a-journey-into-ruby-web-server-startup-sequences-part-two/>


[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
