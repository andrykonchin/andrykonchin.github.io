---
layout:     post
title:      Типичные ошибки в Rack middleware
date:       2020-05-17 00:01
categories: Ruby
---

В последнее время пришлось вплотную поработать с Rack и стандартными
_middleware_. И хотя сама спецификация Rack весьма ясна и конкретна в
ней все равно есть нюансы которые легко можно упустить и понаделать
ошибок работая над своим _middleware_.

Просматривая исходники rack и rack-contrib раз за разом я обнаруживал
одни и те же ошибки стабильно кочующие из одного _middleware_ в другой.
И здесь я перечислю вот такие стандартные ошибки.


Итак, как же не надо писать _middleware_.

<img src="/assets/images/2020-05-17-common-mistakes-in-rack-mddlewares/logo.png"  />



### Thread safety

Не используйте _request-scoped_ _instance_-переменные, которые живут только
при обработке запроса.

Объект каждого _middleware_ создается в приложении только один раз и
обрабатывает все входящие запросы. Если веб-сервер использует
многопоточную модель (например, Puma), то метод _middleware_ `call`
(который и обрабатывает запрос) может вызваться одновременно в двух
потоках.  Объект _middleware_ не должен иметь состояние (в примере ниже
_instance_-переменную `@host`). Если в одном потоке присвоить
_instance_-переменной одно значение, то второй поток может присвоить
другое. Первый поток еще не завершился и может увидеть второе значение
выставленное другим потоком.

Вот пример такой ошибки в _middleware_ Rack::CommonCookies:

```ruby
module Rack
  # Rack _middleware_ to use common cookies across domain and subdomains.
  class CommonCookies
    DOMAIN_REGEXP = /([^.]*)\.([^.]*|..\...|...\...|..\....)$/
    LOCALHOST_OR_IP_REGEXP = /^([\d.]+|localhost)$/
    PORT = /:\d+$/

    def initialize(app)
      @app = app
    end

    def call(env)
      @app.call(env).tap do |(status, headers, response)|
        @host = env['HTTP_HOST'].sub PORT, ''
        share_cookie headers
      end
    end

    private

    def domain
      @host =~ DOMAIN_REGEXP
      ".#{$1}.#{$2}"
    end

    def share_cookie(headers)
      headers['Set-Cookie'] &&= common_cookie(headers) if @host !~ LOCALHOST_OR_IP_REGEXP
    end

    def cookie(headers)
      cookies = headers['Set-Cookie']
      cookies.is_a?(Array) ? cookies.join("\n") : cookies
    end

    def common_cookie(headers)
      cookie(headers).gsub(/; domain=[^;]*/, '').gsub(/$/, "; domain=#{domain}")
    end
  end
end
```
([source](https://github.com/rack/rack-contrib/blob/v2.2.0/lib/rack/contrib/common_cookies.rb))

В переменную `@host` сохраняют данные для текущего запроса. Далее ее
значение используют в обработке запроса. В корректной реализации
значение _host_ должно передаваться везде как параметр:

```ruby
def call(env)
  host = env['HTTP_HOST'].sub PORT, ''
  share_cookie(headers, host)
end
```

Еще одна рекомендация. Если используете "глобальные"
_instance_-переменные, то надо обеспечить синхронизацию доступа к ним.
Это предотвратит _race condition_. Рассмотрим пример из
Rack::LazyConditionalGet:

```ruby
def initialize app, cache={}
  # ...
  @cache = cache
end

def call env
  # ...
  update_cache
  # ...
end

def update_cache
  # ...
  @cache[KEY] = stamp
  # ...
end
```
([source](https://github.com/rack/rack-contrib/blob/v2.2.0/lib/rack/contrib/lazy_conditional_get.rb))

Здесь используется переменную `@cache`, куда сохраняются ответы
приложения. Эта переменная, назовем ее "глобальной", разделяется всеми
потоками и если два потока одновременно попытаются обновить кеш, то
может возникнуть race condition и данные могут потеряться. По-умолчанию
в качестве кеша используется объект `Hash`, а метод `[]=` для него не
атомарный - поэтому операции с кешом нужно синхронизировать. Несмотря на
то, что кеш может обеспечивать _thread-safety_ сам, здесь, думаю, это
ответственность именно _middleware_. Например, можно использовать классы
`Mutex` или `Monitor` для пессимистичной блокировки:

```ruby
def initialize app, options = {}
  @mutex = Mutex.new

  # ...
end

def call
  # ...
  @mutex.synchronize do
    @cache[KEY] = stamp
  end

  # ...
end
```


### Заголовки запроса с префиксом HTTP_

По спецификации все заголовки (на самом деле почти все) приходят в
верхнем регистре и с приставкой HTTP_, например HTTP_ACCEPT_ENCODING.
Надо помнить об этом и не использовать канонические имена заголовков
(такие как Accept-Encoding). Такую ошибку, например, сделали в
Rack::ExpectationCascade - в `env` никогда не придет ключ Expect, а
только HTTP_EXPECT:

```ruby
Expect = "Expect".freeze

def call(env)
  env[Expect] != ContinueExpectation
  # ...
  env.delete(Expect)
end
```
([source](https://github.com/rack/rack-contrib/blob/v2.2.0/lib/rack/contrib/expectation_cascade.rb))



### Забытый rewind для rack.input

В объекте запроса `env` в параметре `rack.input` приходит тело запроса.
Это IO-like объект, который можно "прочитать" вызывая методы `each`,
`read` или `gets` и перемотать в начало методом `rewind`. Так вот, если
вы прочитали что-то из тела запроса, то всегда надо отматывать его
назад, ведь и приложение и другие _middleware_ могут тоже работать с
телом запроса. А если прочитать тело запроса и не вызвать метод `rewind`
то все последующие попытки прочитать данные вернут только пустую строку.

В этом примере в Rack::JSONBodyParser читают тело запроса и отматывают
его назад:

```ruby
body = env[Rack::RACK_INPUT]
body_content = body.read # ...
body.rewind # somebody might try to read this stream
```
([source](https://github.com/rack/rack-contrib/blob/v2.2.0/lib/rack/contrib/json_body_parser.rb))



### Статус ответа - это не Integer

Не используйте статус ответа будто это целое число. Спецификация
требует, чтобы статус имел только метод `to_i`. Приложение может вернуть
строку или какой-то совсем кастомный класс, который при вызове метода
`to_i` вернет уже числовое значение.

```ruby
def call(env)
  # ...
  status, headers, body = @app.call(env)

  if status == 200
  # ...
end
```
([source](https://github.com/rack/rack/blob/v2.2.2/lib/rack/conditional_get.rb))

Согласно спецификации нужно всегда приводить статус к целому числу:

```ruby
status.to_i == 200
```



### Заголовки ответа -  это не Hash

Не используйте объект с заголовками ответа как `Hash`. Не вызывайте
методы `[]`, `[]=`, `has_key` или `merge` ведь спецификация требует от
объекта заголовков только реализовать метод `each`.

Вот несколько примеров такой ошибки в Rack::CSSHTTPRequest и Rack::Cors.
Здесь с `headers` работают как с `Hash`'ом, выставляя заголовки
Content-Length и Content-Type.

```ruby
def call(env)
  status, headers, response = @app.call(env)
  # ...
  modify_headers!(headers, response)
  # ...
end

def modify_headers!(headers, encoded_response)
  headers['Content-Length'] = encoded_response.bytesize.to_s
  headers['Content-Type'] = 'text/css'
  nil
end
```
([source](https://github.com/rack/rack-contrib/blob/v2.2.0/lib/rack/contrib/csshttprequest.rb))


А вот здесь заголовки `headers` мержат с другим `Hash`'ом `add_headers`,
что не корректно и вызовет исключение, если `headers` окажется не
объектом класса `Hash`:

```ruby
def call(env)
  # ...
  status, headers, body = @app.call env

  # ...
  if add_headers
    headers = add_headers.merge(headers)

  # ...
end
```
([source](https://github.com/cyu/rack-cors/blob/v1.1.1/lib/rack/cors.rb#L103))



### Регистр заголовков ответа

Не полагайтесь на формат имени заголовка в ответе, например
Content-Type, Vary итд.

Спецификация протокола HTTP определяет, что имя заголовка -
_case-insensitive_, т.е. и заголовок content-type и CONTENT-TYPE
совершенно корректны. А спецификация Rack не накладывают никаких
дополнительных ограничений на имя заголовка ответа.

```ruby
def call env
  # ..
  status, headers, body = @app.call env
  # ..
  headers['Last-Modified'] = cached_value
  # ..
end
```
([source](https://github.com/rack/rack-contrib/blob/v2.2.0/lib/rack/contrib/lazy_conditional_get.rb))

Если приложение в примере выше вернет заголовок `'last-modified'`, то
`headers['Last-Modified'] = cached_value` добавить дублирующее значение:

```ruby
{
  'last-modified' => '...',
  'Last-Modified' => '...'
}
```

И что именно вернется приложению уже не известно, так как это зависит от
веб-сервера. Сервер может вернуть как оба заголовка, так и удалить один
из них.

Корректный способ работы с заголовками ответа - это использовать класс
`Rack::Response`. Он решает обе проблема - и позволяет работать с
заголовками как с `Hash`'ом и игнорирует регистр имен заголовков:

```ruby
response = Rack::Response.new([], 204, {'Content-Type' => 0})
response['Content-Type'] # => 0
response.headers['Content-Type'] # => 0

response.finish => [status, headers, body]
```

Можно также использовать приватный класс `Rack::Utils::HeaderHash`. Под
капотом `Rack::Response` тоже использует `Rack::Utils::HeaderHash` для
работы с заголовками.

```ruby
status, headers, body = @app.call(env)
headers = Utils::HeaderHash[headers]
Headers['Content-Type'] # => 0
```


### Вызывайте close для оригинального тела ответа

Если _middleware_ игнорирует тело ответа приложения и отдает свой ответ
(например при _conditional get_), всегда закрывайте _body_ из ответа
приложения. Это может быть файл или другой IO-объект, который нужно
закрыть и его дескриптор не утечет.

Спецификация Rack требует, чтобы вызвали метод `close`, если объект тела
ответа его поддерживает. Обычно его вызывает уже сам веб-сервер после
того, как отошлет тело ответа клиенту. Но если _body_ из ответа
приложения игнорируется и возвращается совсем другой ответ, то
_middleware_  должно вызвать метод `close` самостоятельно.

Обычно для этого используют вспомогательный класс `Rack::BodyProxy`,
который вызывает блок кода когда веб-сервер вызывает `close` для него
самого:

```ruby
def call(env)
  # ...
  status, headers, Rack::BodyProxy.new([]) do
    body.close if body.respond_to? :close
  end
end
```
([source](https://github.com/rack/rack/blob/v2.2.2/lib/rack/head.rb))



### Тестируйте с Rack::Lint

Всегда тестируйте ваш _middleware_. Не только простыми _unit_-тестами,
но и используя _middleware_ Rack::Lint. Rack::Lint проверяет ваше
_middleware_ на совместимость со спецификацией Rack и может поймать
целый класс ошибки. Приведу пример из тестов в _gem_'е `rack`:

```ruby
def conditional_get(app)
  Rack::Lint.new Rack::ConditionalGet.new(app)
end

it "set a 304 status and truncate body when If-Modified-Since hits" do
  timestamp = Time.now.httpdate
  app = conditional_get(lambda { |env|
    [200, { 'Last-Modified' => timestamp }, ['TEST']] })

  response = Rack::MockRequest.new(app).
    get("/", 'HTTP_IF_MODIFIED_SINCE' => timestamp)

  response.status.must_equal 304
  response.body.must_be :empty?
end
```
([source](https://github.com/rack/rack/blob/v2.2.2/test/spec_conditional_get.rb#L7-L21))

В тесте строиться цепочка _middleware_, которая состоит из Rack::Lint,
Rack::ConditionalGet и самого приложения:

```ruby
Rack::Lint.new(
  Rack::ConditionalGet.new(
    lambda { |env| [200, { 'Last-Modified' => timestamp }, ['TEST']] }
  )
)
```



### Используйте тестовые helper'ы

В дикой природе встречаются несколько подходов к тестированию
_middleware_:
* голые _unit_-тесты
* тесты с использованием `Rack::MockRequest.env_for`
* тесты с использованием `Rack::MockRequest.new`

Итак, голый _unit_-тест выглядит примерно так:

```ruby
specify "exists and sets X-Runtime header" do
  app = lambda { |env| [200, {'Content-Type' => 'text/plain'}, "Hello!"] }
  status, headers, body = Rack::Runtime.new(app).call({})
  _(headers['X-Runtime']).must_match /[\d\.]+/
end
```

Передается параметром `env` пустой `Hash`, затем вызывается метод `call`
на _middleware_ и в результате получаем массива из трех элементов -
статус, заголовки и тело ответа.

Это абсолютно корректный подход, но в нем есть один недостаток - он не
работает с Rack::Lint, так как там проверяется в том числе и сам запрос
(объект env). Запрос должен содержать несколько обязательных параметров,
таких как `REQUEST_METHOD`, `SERVER_NAME`, `QUERY_STRING` или
`rack.input`.

Чтобы получить полноценный объект `env`, который удовлетворит
`Rack::Lint`, можно использовать класс `Rack::MockRequest` из состава
_gem_'а `rack`. И приведенный выше тест будет выглядеть вот так:

```ruby
specify "exists and sets X-Runtime header" do
  app = lambda { |env| [200, {'Content-Type' => 'text/plain'}, "Hello!"] }
  env = Rack::MockRequest.env_for("/")
  status, headers, body = Rack::Runtime.new(app).call(env)
  _(headers['X-Runtime']).must_match /[\d\.]+/
end
```

Опять таки, здесь уже все хорошо, но остаются неудобства с проверкой
результата. Тело возвращается в виде списка строк. А если используется
Rack::Lint, то тело вернется в виде объекта класса Rack::Lint и, чтобы
получить тело в виде строки, надо немного поизворачиваться:

```ruby
_(body.join).must_equal "" # если body это Array
_(body.to_enum.to_a.join).must_equal "" # если body это Rack::Lint
```

В любом случае намного удобней работать с ответом, если обернуть его в
`Rack::MockResponse`:

```ruby
r = Rack::MockResponse.new(200, { 'Content-Type' => 'application/json'}, ['Hi'])
r.status # => 200
r.body # => "Hi"
r.headers['Content-Type'] # => "application/json"
r['Content-Type'] # => "application/json"
```

Теперь тест выглядит уже так:

```ruby
specify "exists and sets X-Runtime header" do
  app = lambda { |env| [200, {'Content-Type' => 'text/plain'}, "Hello!"] }
  env = Rack::MockRequest.env_for("/")
  status, headers, body = Rack::Runtime.new(app).call(env)
  response = Rack::MockResponse.new(status, headers, body)
  _(response['X-Runtime']).must_match /[\d\.]+/
end
```

Чтобы избавиться от рутинного повторяющегося кода можно вынести его в
отдельный _helper_. Но такой _helper_ уже есть и реализован в
`Rack::MockRequest`:

```ruby
specify "exists and sets X-Runtime header" do
  app = lambda { |env| [200, {'Content-Type' => 'text/plain'}, "Hello!"] }
  response = Rack::MockRequest.new(Rack::Runtime.new(app)).get('/')
  _(response['X-Runtime']).must_match /[\d\.]+/
end
```

За методом `get('/')` стоит и создание полноценного объекта `env`
вызовом `Rack::MockRequest.env_for` и создание объекта класса
`Rack::MockResponse`. Так что это самый предпочтительный способ
протестировать _middleware_.

Не будем забывать о Rack::Lint. Вот так должен выглядеть наш тест в
итоге:

```ruby
specify "exists and sets X-Runtime header" do
  app = lambda { |env| [200, {'Content-Type' => 'text/plain'}, "Hello!"] }
  response = Rack::MockRequest.new(Rack::Lint.new(Rack::Runtime.new(app))).get('/')
  _(response['X-Runtime']).must_match /[\d\.]+/
end
```


### Заключение

В рамках ревью _gem_'а `rack-contrib` все (надеюсь, что все)
перечисленные типы ошибок были исправлены
([фиксы](https://github.com/rack/rack-contrib/pulls?q=is%3Apr+is%3Aclosed+author%3Aandrykonchin)).
Конечно же, еще осталась проблема с тестами - надо дописать недостающие
и порефакторить те что уже есть. Тесты писались разными людьми в разное
время и как следствие в разном стиле.

В отличии от `rack-contrib` основной _gem_ `rack` находится в очень
хорошем состоянии. Хотя и там я нашел несколько проблемных мест
([фиксы](https://github.com/rack/rack/pulls?q=is%3Apr+is%3Aclosed+author%3Aandrykonchin)).

Сейчас обсуждают изменения в самой спецификации Rack - по большей части
мелкие упрощения. Например, предлагают, чтобы статус ответа был целым
числом и не надо было его конвертировать вызовом метода `to_i`. Чтобы
заголовки ответа возвращались в виде `Hash`'а, а имена заголовков должны
быть только в нижнем регистре - это решает проблему с _case-insensitive_
именами. Посмотрим чем это закончится.



[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
