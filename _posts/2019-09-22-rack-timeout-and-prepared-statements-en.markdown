---
layout:     post
title:      "The art of shooting yourself in the foot with prepared statements"
date:       2019-09-28 18:19
categories: Rails
---

I recently encountered an intriguing issue that required me to gain a deeper understanding of how Rails works. The problem pertained to the use of prepared SQL statements, a concept I am familiar with but had never thoroughly explored how Rails uses them. However, I resolved to delve into the topic and explore it in greater detail.

Our production environment began experiencing atypical exceptions:

```
PG::DuplicatePstatement: ERROR:  prepared statement "a4205" already exists
: SELECT  "parties".* FROM "parties" WHERE ...
```

Exceptions were occuring in completely different components of the
web-application and was grouped into sequences. Exceptions in every sequence have the same _bad_ identifier in a message (`a4205` in our example) that changes in the next  exceptions sequence.

These exceptions were being generated in completely different places of the web application and were being grouped into sequences. Each sequence of exceptions contained a consistent _bad_ identifier in the message (`a4205` in the example above), with the identifier changing in the subsequent sequence of exceptions.

After researching the issue, I discovered that the most likely culprit behind these exceptions was the [rack-timeout](https://github.com/sharpstone/rack-timeout) gem. As it turned out, the gem was already being used within our project, and it would explain the randomness of the exception occurrences.


### A bit of theory

Here we are talking about so called _prepared statements_. Prepared statements are an optimization technique used to speed up the execution of SQL queries in a database. This is accomplished by caching the query execution plan, which is then assigned a unique string identifier (such as `a4205`). Prepared statements can accept arguments, making them suitable for a wide range of use cases. By reusing previously generated execution plans, the database can execute queries at a much faster rate, resulting in improved performance and reduced resource usage.

It works in the following steps. The first one - preparation. A SQL query is _prepared_, that's parsed, analyzed and an execution plan is created. A command `PREPARE` is used:

Prepared statements work by going through a series of steps. The first step is preparation, during which a SQL query is parsed, analyzed, and an execution plan is created. This is accomplished using the `PREPARE` command, which takes the SQL query, identifier and parameter types as its arguments:

```sql
PREPARE usrrptplan (int, date) AS
    SELECT * FROM users u, logs l WHERE u.usrid=$1 AND u.usrid=l.usrid
    AND l.date = $2;
```

Once a prepared statement has been created, it can be executed with arguments. The execution is done using the `EXECUTE` command, which takes the prepared statement identifier as well as the arguments to be passed to the query. The database retrieves the execution plan associated with the prepared statement and uses it to execute the query with the supplied arguments:

```sql
EXECUTE foo(2, '2019-09-23');
```

I'll be using PostgreSQL in my examples.

Preparing SQL queries can offer significant performance enhancements, especially for complex queries or scenarios where the same query must be executed multiple times with different parameters. By using a prepared query, the database avoids the effort of preparing the execution plan of the SQL query, which leads to faster execution times.


### How it works in Rails

Rails has supported prepared statements since version 3.1, and this feature is enabled by default. Nearly all SQL queries in Rails are automatically prepared, with only a few exceptions.

As prepared statements consume resources in the database (such as memory), there is a default limit of 1000 prepared statements per database connection to mitigate excessive memory consumption. When this limit is reached, and a new SQL query is executed, Rails removes one of the existing prepared statements from the database using the `DEALLOCATE` command.

In a Rails application, the prepared statement limit can be configured using the adapter option `statement_limit`. To disable prepared statements entirely, the adapter option `prepared_statements: false` can be used:

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

A new prepared statement is assigned a unique identifier by Rails and added to a _statement pool_ that contains key-value pairs consisting of the SQL query string and its identifier. The identifier is generated as a string using the format `a#{@counter + 1}`, such as `a1`, `a2`, and so on ([source](https://github.com/rails/rails/blob/4-2-stable/activerecord/lib/active_record/connection_adapters/postgresql_adapter.rb#L172)).

When Rails executes a SQL query it checks the statement pool first to see if it contains the query. If the query is found, Rails uses the associated identifier to execute the prepared statement with the supplied arguments.

Let's look at the typical expression:

```ruby
Account.find(3)
```

The following SQL query is derived from the preceding code snippet:

```sql
SELECT  "accounts".* FROM "accounts" WHERE "accounts"."id" = $1 LIMIT $2  [["id", 3], ["LIMIT", 1]]
```

In the preceding example, we can observe that Rails generates a generic SQL query and extracts all the variable components, such as `id` and `LIMIT`, as parameters.

Upon executing the SQL query mentioned previously, a new record is added to the PostgreSQL system table for prepared statements, as illustrated by the following code snippet:

```sql
SELECT * FROM pg_prepared_statements
-- => "a1", "SELECT  \"accounts\".* FROM \"accounts\" WHERE \"accounts\".\"id\" = $1 LIMIT $2", "2019-09-24 18:06:04.887512+00", "{bigint,bigint}", false
```

PostgreSQL maintains a `pg_prepared_statements` table that stores various details related to prepared statements, such as the unique identifier (`a1`), the SQL query string, the creation timestamp (`2019-09-24 18:06:04.887512+00`), and the expected data types for the query parameters (`{bigint,bigint}`). More information on this can be found in the PostgreSQL ([documentation](https://www.postgresql.org/docs/11/view-pg-prepared-statements.html)).


### Limitations in Rails

In Rails, prepared statements are exclusively used for *SELECT* queries, and usage is optimized to avoid preparing one-time queries.

For instance, a query without parameters (all the values are inlined) will not be prepared:

```ruby
Account.where(id: [1, 2])
# SELECT "accounts".* FROM "accounts" WHERE "accounts"."deleted_at" IS NULL AND "accounts"."id" IN (1, 2)

ActiveRecord::Base.connection.execute('select * from pg_prepared_statements').count
# 0
```

Similarly, queries that are constructed dynamically and contain hardcoded SQL segments will also not be prepared:

```ruby
Account.where("id = 1")
# SELECT  "accounts".* FROM "accounts" WHERE (id = 1) LIMIT $1  [["LIMIT", 11]]

ActiveRecord::Base.connection.execute('select * from pg_prepared_statements').count
# 0
```

These restrictions on prepared statements were added to Rails with the release of version 5.0. You can find more information about this in the related [commit](https://github.com/rails/rails/commit/cbcdecd2c55fca9613722779231de2d8dd67ad02).


### So what is wrong with Rack::Timeout?

The error message "prepared statement a4205 already exists" indicates that Rails attempted to create a new prepared statement with the identifier a4205, but it had already been created and registered in PostgreSQL. Although PostgreSQL knows about this prepared statement, Rails is unaware of its existence and attempts to create a new one with the same identifier, which leads to the error. Any further attempts to create a new prepared statement with the same identifier on this database connection will fail with the same error message.

The only way for such a situation to occur is if the execution of a SQL query is interrupted **after** the creation of the prepared statement but **before** the identifier is added to the Rails' statement pool. This is precisely what can happen when `rack-timeout` gem is used. It provides a `Rack::Timeout` Rack middleware that terminates processing of a long HTTP request if it exceeds a set timeout. This is done by calling the merciless `Thread#raise` method ([source](https://github.com/sharpstone/rack-timeout/blob/v0.5.1/lib/rack/timeout/core.rb#L119)).

We can examine the method in Rails (version 4.2) that generates prepared statements:

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

The statement pool (`@statements`) consists of key-value pairs in the form of SQL-query strings and their identifiers. A new identifier is generated based on an internal counter using `@statements.next_key`. The method `@connection.prepare` creates a prepared statement in PostgreSQL, and `@statements[sql_key] = nextkey` adds the new key-value pair to the statement pool and increments the internal counter by 1.

If a request is terminated between the `@connection.prepare nextkey, sql` and `@statements[sql_key] = nextkey` expressions, it can result in a discrepancy between the states of PostgreSQL and Rails.


### Hm, but how likely is that?

Let's replicate this scenario manually.

The following code snippet executes numerous SQL queries, creating a new prepared statement each time. In a separate thread, an exception is thrown to interrupt the execution of an SQL query in the main thread (`main_thread.raise 'Timeout error'`). Therefore, at some point, the main thread will be interrupted just after preparing a query, but before adding its identifier to the statement pool.

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

The expression `User.where(id: 1).limit(i)` is used to create an SQL query that will have a unique query string each time by changing the value of the limit parameter. Since this parameter is inlined and not passed as a query parameter, each query will be distinct and Rails will create a new prepared statement for each one:

```sql
SELECT  "accounts".* FROM "accounts" WHERE "accounts"."id" = $1 LIMIT 1  [["id", 1]]
```

This behavior is specific to Rails 4.2 and may be slightly different in later versions. As Rails evolves, it increasingly uses parameters passing instead of inlining values in query strings.

This code easily reproduces the `ActiveRecord::StatementInvalid` exception:

```
$ rails runner ./timeout.rb

PG::DuplicatePstatement: ERROR:  prepared statement "a359" already exists
: SELECT  "users".* FROM "users" WHERE "users"."deleted_at" IS NULL AND "users"."id" = $1  ORDER BY created_at DESC LIMIT 362
```

So in this case the 359th query was interapted by the exception.

Instead of inlining the limit value in the SQL query string, Rails 5.2 (and possibly other 5.x versions) passes it as a query parameter to make each query generic. For instance, using the method `#limit` the resulting SQL query string doesn't change and only one prepared statement is created. This is an improvement from Rails 4.2, where each query had a different SQL query string due to inlining the limit value, resulting in creating a new prepared statement every time:

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

By passing `[1] * i` as a parameter to the where method, each SQL query will be unique and dependent on the length of the array. Specifically, each element in the array will be passed as a separate query parameter.

```sql
SELECT "accounts".* FROM "accounts" WHERE "accounts"."id" IN ($1, $2, $3, $4, $5)
```

So it is highly likely that such a discrepancy can occur in an unoptimized code that executes numerous SQL queries.


### PS

The `Rack::Timeout` middleware and the `Timeout::timeout` method from the Ruby standard library are powerful but potentially dangerous tools, and their usage requires a thorough understanding of their consequences. In our case, we also employed the `Timeout::timeout` method to terminate timed-out jobs in both Sidekiq (a background workers manager) and Sneakers (a RabbitMQ workers manager). As a result of this investigation we completely removed `Timeout::timeout` in our project.

Certainly, prepared statements can improve performance, but they can also have negative effects, such as increasing memory consumption by a database. There have been reported issues ([issue](https://github.com/rails/rails/issues/14645),
[issue](https://stackoverflow.com/questions/22657459/memory-leaks-on-postgresql-server-after-upgrade-to-rails-4)
and [issue](https://gitlab.com/gitlab-org/gitlab-foss/issues/20723)) that are caused by excessive use of prepared statements. Therefore, disabling prepared statements completely or decreasing the limit might be useful in some cases.


### Links

* [https://www.postgresql.org/docs/11/sql-prepare.html](https://www.postgresql.org/docs/11/sql-prepare.html)
* [Execution Plan Basics](https://www.red-gate.com/simple-talk/sql/performance/execution-plan-basics/)
* [Show some love for prepared statements in Rails 3.1](http://patshaughnessy.net/2011/10/22/show-some-love-for-prepared-statements-in-rails-3-1)
* [Timeout: Ruby's Most Dangerous API](https://www.mikeperham.com/2015/05/08/timeout-rubys-most-dangerous-api/)

[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
