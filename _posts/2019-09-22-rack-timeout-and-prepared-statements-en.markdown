---
layout:     post
title:      "How to shoot in your foot with prepared statements"
date:       2019-09-28 18:19
categories: Rails
---

I've faced recently an interesting new problem so I had to fill one more gap in my understanding how Rails work. This time it was about mechanism of using prepared SQL statements. Ofcouse I new that Rails does use this staff, but I have never investigated this topic. And only now I decided to look at it more closely.

We started receiving unusuall `ActiveRecord::StatementInvalid` exceptions on production:

```
PG::DuplicatePstatement: ERROR:  prepared statement "a4205" already exists
: SELECT  "parties".* FROM "parties" WHERE ...
```

Exceptions were occuring in completely different components of the
web-application and was grouped into sequences. Exceptions in every sequence have the same _bad_ identifier in a message (`a4205` in our example) that changes in the next  exceptions sequence.

Googling the symptoms revealed that the most probable cause of the exceptions is a [rack-timeout](https://github.com/sharpstone/rack-timeout) gem. Indeed we use it in the project and it explains randomness of moment and place of raising exceptions well.


### A bit of theory

Here we are talking about so called _prepared statements_ - ability to
execute SQL queries in a database faster due to caching of a query execution
plan. Every prepared statement is assigned a string indentifier (`a4205` in our example) and accepts arguments.

It works in the following steps. The first one - preparation. A SQL query is _prepared_, that's parsed, analyzed and an execution plan is created. A command `PREPARE` is used:

```sql
PREPARE usrrptplan (int, date) AS
    SELECT * FROM users u, logs l WHERE u.usrid=$1 AND u.usrid=l.usrid
    AND l.date = $2;
```

Then the prepared statement will be executed (with arguments):

```sql
EXECUTE foo(2, '2019-09-23');
```
(here and bellow we use PostrgeSQL in examples)

Prapared SQL query will be executed faster than not prepared due to database skips work needed to prepare an execution plan of the SQL query. It may result in visible speedup for complex SQL queries or if you need to execute multiple times the same SQL query but with different parameters (e.g. a banch of _INSERT_ queries).

In PostgreSQL a prepared statement is visibility is scoped by a current client session with a database. So their identifiers aren't visible for other clients and are stored until the current connection is closed.


### How it works in Rails

Rails supports prepared statements since Rails 3.1. By default this
mechanizm is turned on and Rails is preparing almost all AQL queries (with seldom exceptions).

Prepared statements consumes resources of a database - at least memory. So to prevent excessive memory consumption a number of prepared statement per a connection to a database is limited and default limit is 1000 prepared queries. If the limit is reached but there is a new SQL query to execute then one of the existing prepared statements is removed from a database (with command `DEALLOCATE`).

To configure this limit in a Rails application an adapter option `statement_limit` should be used. To disable prepared statements at all should be used adapter option `prepared_statements: false`:

```yaml
production:
  adapter: postgresql
  statement_limit: 200
```
or

```yaml
production:
  adapter: postgresql
  prepared_statements: false
```

An identifier for a new prepared statement is generating by Rails and
added to a _statement pool_ that stores key-value pairs (SQL query
string, identifier). The identifier string looks like `"a#{@counter + 1}"`
([source](https://github.com/rails/rails/blob/4-2-stable/activerecord/lib/active_record/connection_adapters/postgresql_adapter.rb#L172)), e.g. `a1`, `a2` etc.

When Rails is asked to execute a SQL query it checks the statement pool. If it contains the SQL query then Rails just uses related identified to execute a prepared statement with actual arguments.

Let's look at the following example:

```ruby
Account.find(3)
```

It derives the followinf SQL query:

```sql
SELECT  "accounts".* FROM "accounts" WHERE "accounts"."id" = $1 LIMIT $2  [["id", 3], ["LIMIT", 1]]
```

So we see that Rails generates the most generic SQL query and extract everything that can be changed (`id` и `LIMIT`) to parameters.

After executing this SQL query in a PostgreSQL system table for prepared statements a new record is added:

```sql
SELECT * FROM pg_prepared_statements
-- => "a1", "SELECT  \"accounts\".* FROM \"accounts\" WHERE \"accounts\".\"id\" = $1 LIMIT $2", "2019-09-24 18:06:04.887512+00", "{bigint,bigint}", false
```

In the `pg_prepared_statements` table PostgreSQL stores identifier
(`a1`), SQL query string, creation time (`2019-09-24 18:06:04.887512+00`)
and parameter types (`{bigint,bigint}`)
([documentation](https://www.postgresql.org/docs/11/view-pg-prepared-statements.html)).


### Limitations in Rails

Rails uses prepared statement only for *SELECT*-queries and tries to use
them in the most efficient way - avoiding garbadge one-time queries.

For instance, a query without parameters (all the parameters are inlined in the query string) will not be prepared:

```ruby
Account.where(id: [1, 2])
# SELECT "accounts".* FROM "accounts" WHERE "accounts"."deleted_at" IS NULL AND "accounts"."id" IN (1, 2)

ActiveRecord::Base.connection.execute('select * from pg_prepared_statements').count
# 0
```

Similarty, dynamically constructed query (so some parts of SQL are specifyed explicitly) will not be prepared as well:

```ruby
Account.where("id = 1")
# SELECT  "accounts".* FROM "accounts" WHERE (id = 1) LIMIT $1  [["LIMIT", 11]]

ActiveRecord::Base.connection.execute('select * from pg_prepared_statements').count
# 0
```

These limitations were introduced in Rails 5.0 (see a [commit](https://github.com/rails/rails/commit/cbcdecd2c55fca9613722779231de2d8dd67ad02))


### So what is wrong with Rack::Timeout?

The exception message 'prepared statement `a4205` already exists' tells us that Rails tried to create a new prepared statement, 4205th, but this identifier is already in use. It's already registered and PostgreSQL knows about it, but Rails still beleive it isn't registered yet. And all the further attempts to create a new prepared statements in this particular database connection fails with the same exception.

Such a situation is only possible if execution of a SQL query was interapted **after creation** of a prepared statement but **before adding** an identifier to the statement pool by Rails. This is exactly what the `Rack::Timeout` can lead to. It's a Rack-middleware, that terminates processing of a long HTTP-request if it exceeds some timeout. It uses merciless method `Thread#raise`
([source](https://github.com/sharpstone/rack-timeout/blob/v0.5.1/lib/rack/timeout/core.rb#L119)).

Let's look at the method that creates a prepared statement in Rails (v4.2):

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

The statement pool (`@statements`) contains key-value pairs [SQL-query
stirng, identifier]. A method call `@statements.next_key` produces a new identifier based on an internal counter. A method call `@connection.prepare` creates a prepared statement in PostgreSQL, and `@statements[sql_key] = nextkey` adds the new key-value pair to the statement pool and increments the internal counter by 1.

If terminate this method executed between expressions `@connection.prepare nextkey,
sql` and `@statements[sql_key] = nextkey`, we will get divergence
between PostgreSQL and Rails states.


### Hm, but how likely it that?

Let's reproduce this situation manually.

The code snipped below executes multiple SQL-queries and creates a new prepared statement every time. In another thread it raises an exception to terminate an SQL query execution in the main thread (`main_thread.raise 'Timout error'`). So sooner or later the main thread will be interapted right in the interesting moment - after preparing a query but before adding identifier to the statement pool.

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

An SQL-query is created with the expression `User.where(id: 1).limit(i)`. To have a unique SQL query string every time we change `limit` value. Its value is inlined and not passed as a query parameter. That's why every query will differ from all the others and Rails we create a prepepared statement every time:

```sql
SELECT  "accounts".* FROM "accounts" WHERE "accounts"."id" = $1 LIMIT 1  [["id", 1]]
```

Its how Rails 4.2 behaves and it may be changed slitely in the next versions - Rails more and more uses passing parameters instead of inlining values into a query string.

This code easily reproduces the `ActiveRecord::StatementInvalid` exception:

```
$ rails runner ./timeout.rb

PG::DuplicatePstatement: ERROR:  prepared statement "a359" already exists
: SELECT  "users".* FROM "users" WHERE "users"."deleted_at" IS NULL AND "users"."id" = $1  ORDER BY created_at DESC LIMIT 362
```

So in this case 359th query was interapted by the exception.


It reproduces the issue with Rails 4.2, but in Rails 5.2 to have SQL
queries unique we need a bit different way - the method `#limit` gets passing a limit value as a query parameter instead of inlining it (I suppose it works this way in 5.x, not only in 5.2).
So in Rails 5.2 a query string doesn't change and only one prepapred
statement is created:

```sql
SELECT  "accounts".* FROM "accounts" WHERE "accounts"."id" = $1 LIMIT $2  [["id", 1], ["LIMIT", 2]]
```

For Rails 5.2 the following expression:
```ruby
User.where(id: 1).limit(i).to_a
```

should be replaced with:

```ruby
User.where(id: [1] * i).to_a
```

This way all the SQL queries will be unique and depend on the `[1] * i` array
length - each array element value is passed as a separate query
parameter:

```sql
SELECT "accounts".* FROM "accounts" WHERE "accounts"."id" IN ($1, $2, $3, $4, $5)
```

As we can see such a divergance is pretty probably and easily can occur in some not optimised code that executes a lot of SQL queries.


### PS

The `Rack::Timout` middleware and the method from the Ruby standard library `Timeout::timeout` as well - are very dangerous tools and should be used carefully with fully understanding of consequences.
We were using `Timeout::timeout` to terminate timeouted Sidekiq (background workers manager) and Sneakers (RabbitMQ workers manager) job and finally we got id of it in both cases.

It's important to understand that dispite prepared statements may improve performance they may have negative effect as well. They could lead to increasing memory consumption by a database
([issue](https://github.com/rails/rails/issues/14645),
[issue](https://stackoverflow.com/questions/22657459/memory-leaks-on-postgresql-server-after-upgrade-to-rails-4)
and [issue](https://gitlab.com/gitlab-org/gitlab-foss/issues/20723)).
So disabling completely or decreasing the limit (`statement_limit`) sometimes might be useful.


### Links

* [https://www.postgresql.org/docs/11/sql-prepare.html](https://www.postgresql.org/docs/11/sql-prepare.html)
* [Execution Plan Basics](https://www.red-gate.com/simple-talk/sql/performance/execution-plan-basics/)
* [Show some love for prepared statements in Rails 3.1](http://patshaughnessy.net/2011/10/22/show-some-love-for-prepared-statements-in-rails-3-1)
* [Timeout: Ruby's Most Dangerous API](https://www.mikeperham.com/2015/05/08/timeout-rubys-most-dangerous-api/)

[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
