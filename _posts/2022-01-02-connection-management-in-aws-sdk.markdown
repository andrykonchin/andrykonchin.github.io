---
layout: post
title:  Ruby AWS SDK и сетевые соединения
date:   2022-01-14 17:23
categories: Ruby AWS
---

Вопросом переиспользует ли AWS SDK TCP-соединения я задавался уже давно.
Официальная документация об этом молчит. Но это важно понимать, ведь
накладные расходы на открытие соединения влияют на время отправки
HTTP-запроса. И если AWS SDK это не поддерживает, тогда приложению
придется переиспользовать клиентов, а не создавать каждый раз на лету.

Аналогичная ситуация и с потокобезопасностью. Многопоточные сервера,
такие как Puma и Sidekiq, популярны поэтому вопрос не праздный.

И вот наконец у меня дошли руки разобраться самому.

**TL;DR:** AWS SDK эффективно использует TCP-соединения. Делая запросы
клиент не тратит время каждый раз на открытие нового соединения и
переиспользует уже созданное. Также, соединение может быть
переиспользовано другим клиентом в том же Ruby-процессе. AWS SDK
работает с соединениями потокобезопасно, поэтому совместим с
многопоточными серверами.

Проверим это на примере клиента к DynamoDB (NoSQL база данных от Amazon).

### Тестируем клиента к DynamoDB

В тесте мы получим список таблиц DynamoDB и
проверим какие соединения установятся с сервером AWS.

Выберем конкретный регион, например `us-west-2`, и определим конкретный
IP-адрес сервера:

```
$ dig dynamodb.us-west-2.amazonaws.com

; <<>> DiG 9.10.6 <<>> dynamodb.us-west-2.amazonaws.com
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 43723
;; flags: qr rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 4096
;; QUESTION SECTION:
;dynamodb.us-west-2.amazonaws.com. IN	A

;; ANSWER SECTION:
dynamodb.us-west-2.amazonaws.com. 1953 IN A	52.94.29.68

;; Query time: 2 msec
;; SERVER: 188.190.254.254#53(188.190.254.254)
;; WHEN: Sun Jan 02 18:13:00 EET 2022
;; MSG SIZE  rcvd: 77
```

Получаем IP-адрес `52.94.29.68`.

Список соединений поможет получить команда `netstat`:

```
$ netstat -an -ptcp | grep 52.94.29.68
```

Опция `-ptcp` означает отфильтровать только TCP-соединения (и
игнорировать UDP). Это специфика `netstat` в MacOS. В Linux опции
отличаются, поэтому `-ptcp` заменяется на `-t`.

Теперь сделаем запрос к DynamoDB. Для этого устанавливаем _gem_
aws-sdk-dynamodb и задаем _credentials_ к аккаунту AWS. Далее запускаем
_irb_ и настраиваем AWS SDK:

```ruby
require 'aws-sdk-dynamodb'

ENV['AWS_ACCESS_KEY_ID'] = '...'
ENV['AWS_SECRET_ACCESS_KEY'] = '...'
ENV['AWS_REGION'] = 'us-west-2'
```

## Тест #1. Делаем последовательные запросы

Проверим, создастся ли новое соединение если сделать повторный запрос.
Для этого в уже открытой и настроенной сессии _irb_ выполним код:

```ruby
client = Aws::DynamoDB::Client.new
client.list_tables
```

И тут же в соседней вкладке терминала выполняем следующую *shell*-команду:
```
$ netstat -an -ptcp | grep 52.94.29.68
tcp4       0      0  192.168.1.12.56015     52.94.29.68.443        ESTABLISHED
```

В результате видим, что установилось одно соединение с сервером AWS с
IP-адресом `52.94.29.68`. Локально используется случайный порт 56015,
которым соединения и различаются.

Возвращаемся ко вкладке с _irb_ и повторяем запрос к DynamoDB. Нужно
сделать это быстро - интервал между запросами не должен превышать 5
секунд (поведение AWS SDK по-умолчанию):

```ruby
client.list_tables
```

Проверим соединения:

```
$ netstat -an -ptcp | grep 52.94.29.68
tcp4       0      0  192.168.1.12.56015     52.94.29.68.443        ESTABLISHED
```

Видим в результате соединение с тем же самым локальным портом. Вывод -
повторный запрос к AWS переиспользует уже открытое соединение.


### Тест #2. Делаем запросы с задержкой


Выполним те же действия, но подождем перед вторым запросом -
секунд 10, например:

```ruby
client = Aws::DynamoDB::Client.new
client.list_tables
```

Установилось соединение:

```
$ netstat -an -ptcp | grep 52.94.29.68
tcp4       0      0  192.168.1.12.56214     52.94.29.68.443        ESTABLISHED
```

Ждем 10 секунд и повторяем запрос:

```ruby
client.list_tables
```

В результате создано два соединения:

```
$ netstat -an -ptcp | grep 52.94.29.68
tcp4       0      0  192.168.1.12.56268     52.94.29.68.443        ESTABLISHED
tcp4       0      0  192.168.1.12.56214     52.94.29.68.443        TIME_WAIT
```

Соединения различаются локальными портами - 56268 и 56214. Соединение с
портом 56214 - это то, что создалось при первом запросе. И оно в
состоянии **TIME_WAIT**. Это промежуточное состояние соединения при
закрытии. В нашем случае соединение было закрыто на стороне клиента.

Вывод - повторный запрос после некоторого ожидания создает новое
соединение.


### Тест #3. Создаем несколько клиентов

Давайте проверим, как ведет себя AWS SDK когда созданы два клиента.
Приведет ли это к открытию новых соединений или AWS SDK умеет экономить
и переиспользовать соединения открытые другим клиентом?

Создадим первый клиент и сделаем запрос:

```ruby
client = Aws::DynamoDB::Client.new(http_idle_timeout: 60)
client.list_tables
```

В результате открывается соединение

```
$ netstat -an -ptcp | grep 52.94.29.68
tcp4       0      0  192.168.1.12.56424     52.94.29.68.443        ESTABLISHED
```

Создаем новый клиент и делаем еще один запрос (надо успеть это сделать
за 60 секунд):

```ruby
client = Aws::DynamoDB::Client.new(http_idle_timeout: 60)
client.list_tables
```

В результате открыто единственное соединение:

```
$ netstat -an -ptcp | grep 52.94.29.68
tcp4       0      0  192.168.1.12.56424     52.94.29.68.443        ESTABLISHED
```

Мы видим, что используется тот же локальный порт 56424. Это
значит, что второй клиент использовал соединение открытое первым
клиентом при первом запросе.

Вывод - клиенты используют соединения сообща и создание нового клиента
не приводит к созданию новых соединений.


### Seahorse

Давайте посмотрим как это реализовано в AWS SDK.

Работа с HTTP вынесена в библиотеку seahorse в _gem_'е aws-sdk-core.
По-умолчанию для отправки запроса используется класс
`Seahorse::Client::NetHttp::Handler` ([source][1]).

Обратим внимание на метод `session`, который возвращает HTTP-клиента.
(`Net::HTTP` из стандартной библиотеки Ruby):

```ruby
def session(config, req, &block)
  pool_for(config).session_for(req.endpoint) do |http|
    # ...
    yield(http)
  end
end
```

`config` - это настройки заданные при инстанцировании клиента (или
дефолтные значения ([документация][2])).

AWS SDK создает _pool_ HTTP-клиентов для каждой конфигурации настроек. В
таком _pool_'е для каждого сервиса AWS поддерживается список
HTTP-клиентов (под-*pool*). Так как у каждого сервиса отдельный поддомен -
сервисы различают по хосту из URL (`req.endpoint`).

_Pool_ соединений реализован в классе `Seahorse::Client::NetHttp::ConnectionPool`
([source][3]). _Pool_'ы соединений - это "статическое поле" (_instance
variable_) объекта `ConnectionPool` и представляет собой `Hash`:

```ruby
class ConnectionPool
  # ...
  @pools_mutex = Mutex.new
  @pools = {}
  # ...
end
```

Для потокобезопасности работа с _pool_'ом оборачивается в мьютекс (`@pools_mutex`).
Таким образом, в многопоточном коде клиент работает корректно.

Например, в методе `self.for` возвращается конкретный _pool_ для указанных
настроек (`options`):

```ruby
class << self
  def for options = {}
    options = pool_options(options)
    @pools_mutex.synchronize do
      @pools[options] ||= new(options)
    end
  end
end
```

Рассмотрим, как организован _pool_ соединений. Соединения хранятся в
`Hash`, где ключи - это URL, а значение - массивы HTTP-клиентов. Работа
с `@pool` аналогично обернута в мьютекс (`@pool_mutex`):

```ruby
def initialize(options = {})
  # ...
  @pool_mutex = Mutex.new
  @pool = {}
end
```

Как упоминалось выше, метод `session_for` принимает аргументом URL
(`endpoint`) и возвращает HTTP-клиента из _pool_'а. Если упростить,
то метод работает следующим образом ([source][4]):

```ruby
def session_for(endpoint, &block)
  # attempt to recycle an already open session
  @pool_mutex.synchronize do
    if @pool.key?(endpoint)
      session = @pool[endpoint].shift
    end
  end

  session ||= start_session(endpoint)

  yield(session)

  # No error raised? Good, check the session into the pool.
  @pool_mutex.synchronize do
    @pool[endpoint] = [] unless @pool.key?(endpoint)
    @pool[endpoint] << session
  end

  nil
end
```

Если в _pool_ (`@pool`) уже добавлено соединение для сервиса
(сервис определяется `endpoint`-ом), то используем его (`session`) и
удаляем из _pool_'а методом `Array#shift`. Иначе
создаем новый HTTP-клиент вызывая хелпер-метод `start_session`. Далее
передаем клиента в блок, в котором отправят HTTP-запрос в AWS и
обработают ответ. Далее возвращаем клиента опять в _pool_. Обратите
внимание, что работа с `@pool` закрыта мьютексом `@pool_mutex`.

### Как настроить pool соединений

В тесте ранее упоминалась опция `http_idle_timeout`. В принципе, это
единственная доступная настройка _pool_'а.

Из [документации][2]:

> The number of seconds a connection is allowed to sit idle before it is
> considered stale. Stale connections are closed and removed from the
> pool before making a request.

Опция `http_idle_timeout` влияет на два момента. Во-первых, неиспользуемый HTTP-клиент
после этого таймаута удаляется из _pool_'а. Правда, не сразу, а перед
очередным запросом. В начале метода `session_for`
_pool_ очищается от протухших HTTP-клиентов вызовом хелпер-метода
`_clean` ([source][5]):


```ruby
# Removes stale sessions from the pool.  This method *must* be called
# @note **Must** be called behind a `@pool_mutex` synchronize block.
def _clean
  now = Aws::Util.monotonic_milliseconds
  @pool.each_pair do |endpoint,sessions|
    sessions.delete_if do |session|
      if session.last_used.nil? or now - session.last_used > http_idle_timeout * 1000
        session.finish
        true
      end
    end
  end
end
```

Во-вторых, `http_idle_timeout` используется при инстанцировании и
настройке нового HTTP-клиента и влияет на свойство `keep_alive_timeout`
([source][6]):

```ruby
http.keep_alive_timeout = http_idle_timeout if http.respond_to?(:keep_alive_timeout=)
```

Согласно [документации][7] `Net::HTTP#keep_alive_timeout` это:

> Seconds to reuse the connection of the previous request. If the idle
> time is less than this Keep-Alive Timeout, Net::HTTP reuses the TCP/IP
> socket used by the previous communication. The default value is 2
> seconds.

То есть, HTTP-клиент создаст новое соединение если между
запросами прошло больше чем `keep_alive_timeout` секунд. Это дублирует уже
описанный выше механизм устаревания HTTP-клиентов в _pool_'е. Ну да
ладно.

Замечу, что это не влияет никоим образом на заголовки HTTP-запроса
`Keep-Alive` и `Connection` (как можно было бы ожидать) - т.е. это
клиентская настройка ([документация][8]) и ничего не подсказывает
серверу.


### PS

После этого маленького исследования я могу быть спокоен за
производительность и безопасность AWS-клиентов в веб-приложении.
Создать клиента на лету и использовать в разных потоках совершенно
безопасно. И не нужны дополнительные усилия вроде мьютексов и
_pool_'а клиентов.


[1]: https://github.com/aws/aws-sdk-ruby/blob/version-3/gems/aws-sdk-core/lib/seahorse/client/net_http/handler.rb
[2]: https://docs.aws.amazon.com/sdk-for-ruby/v3/api/Aws/DynamoDB/Client.html#initialize-instance_method
[3]: https://github.com/aws/aws-sdk-ruby/blob/version-3/gems/aws-sdk-core/lib/seahorse/client/net_http/connection_pool.rb
[4]: https://github.com/aws/aws-sdk-ruby/blob/version-3/gems/aws-sdk-core/lib/seahorse/client/net_http/connection_pool.rb#L81-L116
[5]: https://github.com/aws/aws-sdk-ruby/blob/version-3/gems/aws-sdk-core/lib/seahorse/client/net_http/connection_pool.rb#L311-L323
[6]: https://github.com/aws/aws-sdk-ruby/blob/version-3/gems/aws-sdk-core/lib/seahorse/client/net_http/connection_pool.rb#L289
[7]: https://ruby-doc.org/stdlib-3.1.0/libdoc/net/http/rdoc/Net/HTTP.html#keep_alive_timeout-attribute-method
[8]: https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Keep-Alive

[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
