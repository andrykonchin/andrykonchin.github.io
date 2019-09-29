---
layout:     post
title:      "Как выстрелить себе в ногу с prepared statements"
date:       2019-09-28 18:19
categories: Rails
---

Недавно столкнулся с необычной проблемой и пришлось восполнить еще один
пробел знаний по Rails - на этот раз механизм *prepared statements* для
SQL-запросов. Не то, чтобы я не знал, что Rails так умеет, но эта фича
в свое время прошла как-то мимо меня. И только сейчас я занялся ею
вплотную.

У нас на *production*'е внезапно начали сыпаться необычные *exception*'ы
`ActiveRecord::StatementInvalid`:

```
PG::DuplicatePstatement: ERROR:  prepared statement "a4205" already exists
: SELECT  "parties".* FROM "parties" WHERE ...
```

Ошибки возникали в совершенно разных местах веб-приложения и шли
сериями. В каждой серии в тексте сообщения был один тот же идентификатор
("a4205"), который менялся от серии к серии.

Поиск в сети достаточно быстро привел к правдоподобному объяснению -
виновник *exception*'ов это *gem* [Rack::Timeout](https://github.com/sharpstone/rack-timeout).
Мы действительно использовали его в проекте и это хорошо объясняло
случайность времени и места возникновения *exception*'ов.

### Немного матчасти

Здесь речь идет о так называемых *prepared statements* - возможность
выполнять SQL-запросы в базе данных быстрее за счет кеширования плана
выполнения. Каждый *prepared statement* имеет строковый идентификатор
("a4205" в примере выше) и может принимать параметры.

Работает это следующим образом - при выполнении SQL-запроса он сначала
препарируется (парсится, анализируется и создается план выполнения
запроса):

```sql
PREPARE usrrptplan (int, date) AS
    SELECT * FROM users u, logs l WHERE u.usrid=$1 AND u.usrid=l.usrid
    AND l.date = $2;
```

Затем выполняется, собственно, сам запрос:

```sql
EXECUTE foo(2, '2019-09-23');
```
(здесь и далее для примеров используется Postgres)

Препарированный запрос будет выполняться быстрее обычного потому, что
пропускается этап подготовки плана выполнения запроса. Это может дать
ощутимое ускорение для сложных SQL-запросах или если очень много раз
выполнить простой запрос (с разными параметрами, например пачка
INSERT-ов).

В Postgres область видимости *prepared statements* ограничена текущей
сессией с базой данных. Они не видны другим клиентам и хранятся только
до завершения текущей сессии.


### Как это работает в Rails

Rails поддерживает *prepared statements* начиная с версии 3.1. По
умолчанию этот механизм включен и Rails препарирует практически все
SQL-запросы (за некоторым исключением).

*prepared statements* потребляют ресурсы базы данных - как минимум
оперативную память.  Поэтому, чтобы сильно не нагружать базу, количество
*prepared statements* на одно соединение ограничено и по умолчанию лимит
составляет 1000 запросов. Если надо добавить новый *prepared statement*,
а лимит уже достигнут, то один из созданных ранее *prepared statement*
удаляется из базы данных (оператором `DEALLOCATE`). Для адаптера
Postgres этот лимит можно выставить параметром `statement_limit`. Чтобы
отключить *prepared statements* глобально в приложении нужно выставить
параметр `prepared_statements: false`:

```yaml
production:
  adapter: postgresql
  statement_limit: 200
```
или
```yaml
production:
  adapter: postgresql
  prepared_statements: false
```

Идентификатор для нового *prepared statement* генерируется Rails'ми и
сохраняется в *statement pool* в виде *key-value* пары [текст
SQL-запроса, идентификатор]. Идентификатор имеет вид `"a#{@counter + 1}"`
([source](https://github.com/rails/rails/blob/4-2-stable/activerecord/lib/active_record/connection_adapters/postgresql_adapter.rb#L172)).

Когда в следующий раз надо будет выполнить точно такой же запрос, Rails
проверит, если ли он в *statement pool*. Далее используя найденный
идентификатор просто выполнит запрос c конкретными параметрами.

Для примера возьмем следующий запрос:

```ruby
Account.find(3)
```

В переводе на SQL это:

```sql
SELECT  "accounts".* FROM "accounts" WHERE "accounts"."id" = $1 LIMIT $2  [["id", 3], ["LIMIT", 1]]
```

Мы видим, что Rails сгенерировали максимально обобщенный SQL-запрос и
вынесли все что может измениться (`id` и `LIMIT`) в параметры. А в
служебной таблице для *prepared statements* появится новая запись:

```sql
SELECT * FROM pg_prepared_statements
-- => "a1", "SELECT  \"accounts\".* FROM \"accounts\" WHERE \"accounts\".\"id\" = $1 LIMIT $2", "2019-09-24 18:06:04.887512+00", "{bigint,bigint}", false
```

В таблице `pg_prepared_statements` Postgres сохранил идентификатор
("a1"), текст запроса, время создания ("2019-09-24 18:06:04.887512+00")
и типы параметров ("{bigint,bigint}")
([документация](https://www.postgresql.org/docs/11/view-pg-prepared-statements.html)).


### Ограничения в Rails

Rails использует *prepared statement* только для SELECT-запросов и
старается использовать их максимально эффективно - избегает
замусоривания одноразовыми запросами.

Так, например, запрос без параметров (где все значения заинлайнены прямо
в текст запроса) не будет препарироваться:

```ruby
Account.where(id: [1, 2])
# SELECT "accounts".* FROM "accounts" WHERE "accounts"."deleted_at" IS NULL AND "accounts"."id" IN (1, 2)

ActiveRecord::Base.connection.execute('select * from pg_prepared_statements').count
# 0
```

Аналогично, динамический запрос (часть которого формируется в коде) тоже
не будет препарироваться:

```ruby
Account.where("id = 1")
# SELECT  "accounts".* FROM "accounts" WHERE (id = 1) LIMIT $1  [["LIMIT", 11]]

ActiveRecord::Base.connection.execute('select * from pg_prepared_statements').count
# 0
```

Такие ограничения появились еще в Rails 5.0 (см [коммит](https://github.com/rails/rails/commit/cbcdecd2c55fca9613722779231de2d8dd67ad02))


### Так причем же здесь Rack::Timeout?

Ошибка 'prepared statement "a4205" already exists' говорит о том, что
Rails попыталась создать новый *prepared statement*, 4205-й по счету, но
идентификатор "a4205" уже занят. Он был зарегистрирован в Postgres но
Rails по прежнему считает его свободным. И все последующие попытки
создать *prepared statement* в этом конкретном соединении завершатся
точно такой же ошибкой.

Такая ситуация возможна только если выполнение SQL-запроса Rails'ами
было прервано **после создания** *prepared statement* в Postgres но **до
сохранения** идентификатора в *statement pool* в Rails'ах. Как раз к
этому и может привести работа `Rack::Timeout`. Это *Rack-middleware*,
который прерывает обработку HTTP-запроса если превышен заданных таймаут.
При этом используется беспощадный метод `Thread#raise`
([source](https://github.com/sharpstone/rack-timeout/blob/v0.5.1/lib/rack/timeout/core.rb#L119)).

Рассмотрим процедуру создания *prepared statement* в Rails (v4.2):
```ruby
# lib/active_record/connection_adapters/postgresql_adapter.rb
def prepare_statement(sql)
  sql_key = sql_key(sql)
  unless @statements.key? sql_key
    nextkey = @statements.next_key
    begin
      @connection.prepare nextkey, sql
    rescue => e
      raise translate_exception_class(e, sql)
    end
    # Clear the queue
    @connection.get_last_result
    @statements[sql_key] = nextkey
  end
  @statements[sql_key]
end
```
([source](https://github.com/rails/rails/blob/4-2-stable/activerecord/lib/active_record/connection_adapters/postgresql_adapter.rb#L630-L646))

В *statement pool*'е (`@statements`) хранятся пары [текст SQL-запроса,
идентификатор]. Вызов `@statements.next_key` генерирует новый
идентификатор на основе внутреннего счетчика. Вызов
`@connection.prepare` создает *prepared statement* в Postgres, а
`@statements[sql_key] = nextkey` добавляет в *statement pool* новый
*prepared statement* и увеличивает счетчик на единицу.

Если прервать выполнение между строчками `@connection.prepare nextkey,
sql` и `@statements[sql_key] = nextkey`, мы получим расхождение
между Postgres и Rails.


### Хм, а насколько это вообще вероятно?

Давайте воспроизведем эту ситуацию руками.

Приведенный ниже код выполняет множество SQL-запросов, для каждого из
которых создается новый *prepared statement*. В параллельном потоке
периодически вызываем `RuntimeError`, который прерывает выполнение
SQL-запросов в основном потоке (`main_thread.raise 'Timout error'`).
Рано или поздно основной поток прервется как раз в нужный момент - после
препарирования запроса но до сохранения его в *statement pool*.

```ruby
# timeout.rb

main_thread = Thread.current

Thread.new do
  loop do
    sleep 0.1
    main_thread.raise 'Timout error'
  end
end

(1..1000).each do |i|
  User.where(id: 1).limit(i).to_a
rescue ActiveRecord::StatementInvalid => e
  puts e
  break
rescue
  next
end
```

SQL-запрос генерируется так - `User.where(id: 1).limit(i)`. Чтобы
текст запросов отличался - изменяем `LIMIT`. Это значение инлайнится, а
не передается параметром. Поэтому каждый запрос будет отличаться от
остальных и будет препарироваться заново:

```sql
SELECT  "accounts".* FROM "accounts" WHERE "accounts"."id" = $1 LIMIT 1  [["id", 1]]
```

Это поведение Rails 4.2 и в других версиях оно может отличаться - все
больше и больше инлайнинг значений в текст запроса заменяется передачей
значений в виде параметров.

Этот код воспроизводит приведенную выше ошибку
`ActiveRecord::StatementInvalid`:

```
$ rails runner ./timeout.rb

PG::DuplicatePstatement: ERROR:  prepared statement "a359" already exists
: SELECT  "users".* FROM "users" WHERE "users"."deleted_at" IS NULL AND "users"."id" = $1  ORDER BY created_at DESC LIMIT 362
```

Ошибка воспроизводится на Rails 4.2, но уже в Rails 5.2 нужно
генерировать SQL-запрос иначе - значение для `LIMIT` стало передаваться
параметром (подозреваю что это касается всех версий 5.x, не только 5.2).
Поэтому текст запроса не изменяется и препарируется только один раз:

```sql
SELECT  "accounts".* FROM "accounts" WHERE "accounts"."id" = $1 LIMIT $2  [["id", 1], ["LIMIT", 2]]
```

Для Rails 5.2 нужно заменить
```ruby
User.where(id: 1).limit(i).to_a
```
на
```ruby
User.where(id: [1] * i).to_a
```

Таким образом будут генерироваться разные SQL-запросы в зависимости от
длины массива `[1] * i` - каждый элемент массива передается отдельным
параметром:

```sql
SELECT "accounts".* FROM "accounts" WHERE "accounts"."id" IN ($1, $2, $3, $4, $5)
```

Как мы видим, такая рассинхронизация вполне возможна и легко может
возникнуть в каком-то не оптимизированном коде, который делает много
SQL-запросов. Локально в среднем ошибка воспроизводится на первых 50-100
запросах.


### Выводы

`Rack::Timout` *middleware* как и аналогичный метод `Timeout::timeout`
из стандартной библиотеки Ruby - весьма опасные инструменты и должны
применяться аккуратно понимая какие могут быть последствия. Например,
`Timeout::timeout` использовался для прерывание *job*'ов в Sidekiq и
Sneakers, но в итоге его выпилили в обоих случаях.

Использование *prepared statement* может иметь и негативный эффект. Это
может привести к большому потреблению памяти сервера баз данных
([тыц](https://github.com/rails/rails/issues/14645),
[тыц](https://stackoverflow.com/questions/22657459/memory-leaks-on-postgresql-server-after-upgrade-to-rails-4)
и [тыц](https://gitlab.com/gitlab-org/gitlab-foss/issues/20723)).
Поэтому отключение *prepared statement* совсем или уменьшение лимита
`statement_limit` иногда может быть полезным.


### Ссылки

* [https://www.postgresql.org/docs/11/sql-prepare.html](https://www.postgresql.org/docs/11/sql-prepare.html)
* [Execution Plan Basics](https://www.red-gate.com/simple-talk/sql/performance/execution-plan-basics/)
* [Show some love for prepared statements in Rails 3.1](http://patshaughnessy.net/2011/10/22/show-some-love-for-prepared-statements-in-rails-3-1)
* [Timeout: Ruby's Most Dangerous API](https://www.mikeperham.com/2015/05/08/timeout-rubys-most-dangerous-api/)

[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
