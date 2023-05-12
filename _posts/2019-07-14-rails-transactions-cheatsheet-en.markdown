---
layout:     post
title:      "Rails database transactions cheat sheet"
date:       2019-07-14 19:53
categories: Ruby
extra_head: |
  <style>
    pre code { white-space: pre; }
  </style>
---


Recently I was investigating a bug related to code in one of the `after_commit` _callback_ in a ActiveRecord model in the current project. And suddenly I've realised that have only vague knowledge and understanding of implicit database transactions. The `after_commit` callback is called at transaction completing and it's importand to understand when and how it happens. Espessially I was interested in _nested_ implicit transactions. So this sheat sheet is a result of my diving into this topic. Here you will find multiple examples of SQL queries (specific to PostreSQL). It's one of the things I am missing in guides and numerous blog posts.


### Implict transactions

As it's well known ActiveRecord implicitly wraps all the modifying operations that trigger callbacks (`create`/`save`/`update`/`destroy`, `touch`, `toggle`) into transaction.

Let's imagine that we run the following command:

```ruby
Account.create(name: 'KFC')
```

Resulting SQL query (that you can see in the console or a log file) will look like this:

```sql
BEGIN
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "KFC"]]
COMMIT
```

The transaction begins with command `BEGIN` and completes with command `COMMIT`. To cancel all the data changes of the transaction a command `ROLLBACK` is used ([PostgreSQL documentation](https://www.postgresql.org/docs/11/tutorial-transactions.html)).

If the whole graph of models is saving (main model and all the associated ones), all these queries are also wrapped into one outer transaction.

Let's imagine we create an account model and two associated payments
models:

```ruby
Account.create(
  name: 'KFC',
  payments: [Payment.new(amount: 10), Payment.new(amount: 13)]
)
```

Resulting SQL query will look like this:

```sql
BEGIN
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "KFC"]]
  INSERT INTO "payments" ("amount", "account_id") VALUES ($1, $2) RETURNING "id"  [["amount", "10.0"], ["account_id", 1]]
  INSERT INTO "payments" ("amount", "account_id") VALUES ($1, $2) RETURNING "id"  [["amount", "13.0"], ["account_id", 1]]
COMMIT
```

So this transaction is implicit as far as we don't explicitly enables
it.

### Explicit transactions

To create an explicit transaction a method `ActiveRecord::Base.transaction` should be used, a class method `transaction` that's avaialable in every ActiveRecord model class, or `transaction` instance method. All the SQL queries in transactions are wrapped into standard `BEGIN`/`COMMIT` block.

```ruby
ActiveRecord::Base.transaction do
  Account.create(name: 'KFC')
end
```

```sql
BEGIN
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "KFC"]]
COMMIT
```

Although `Account.create` call should create its own implicit transaction, inside explicitly started transaction an implicit nested transaction is "absorbed". So by default creation of a nested implicit transaction is skipped.

Similarly an explicit call of `transaction` method inside another explicit transaction doesn't create a new nested transaction.

```ruby
ActiveRecord::Base.transaction do
  ActiveRecord::Base.transaction do
    Account.create(name: 'KFC')
  end
end
```

```sql
BEGIN
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "KFC"]]
COMMIT
```

### Nested transactions

Real nested transactions are supported (according to Rails [documentation](https://api.rubyonrails.org/classes/ActiveRecord/Transactions/ClassMethods.html#module-ActiveRecord::Transactions::ClassMethods-label-Nested+transactions)) only by Microsoft SQL Server, and all the other supported in Rails RDMS imitate them wit_save points_ ([PostgreSQL documentation](https://www.postgresql.org/docs/11/sql-savepoint.html)). As follows from teh name it's just point to restore, tha allow rollback changes to some saved _save point_. Like in video games it's possible to restore the same save point multiple times in arbitrary point in a transaction.

There are the following commands are available (please take into account
that it's PostgreSQL-specific examples):
* `SAVEPOINT` - to create a _save point_
* `ROLLBACK TO SAVEPOINT` - to restore state at the _save point_ creation
* `RELEASE SAVEPOINT` - to remove a _save point_

It's allowd to use _save points_ only inside a transaction(`BEGIN`/`COMMIT` block). Obviously it isn't full-fledged transactions, as far as amoung all the ACID properties they provide only _atomicity_ ("A"). Isolation ("I") isn't provided because if there several _save pints_ created then changes after one of them will be visible to all the subsequent _save points_. Dirability ("D") also isn't guarantied - "closing" of a "transaction" with `RELEASE SAVEPOINT` doesn't cause persisting changes on the storage device.

According to the documentation _save point_ is automatically removed if a new one is created with the same name. In PostgreSQL the previous _save point_ isn't removed and will be available again after the new one is removed.

By default ActiveRecord doesn't create nested transaction (transaction in terms of Rails, not database). To enforce its creation an option `requires_new: true` should be used.

```ruby
ActiveRecord::Base.transaction do
  Account.create(name: 'KFC')

  ActiveRecord::Base.transaction(requires_new: true) do
    Account.create(name: "McDonald's")
  end
end
```

```sql
BEGIN
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "KFC"]]

  SAVEPOINT active_record_1
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "McDonald's"]]
  RELEASE SAVEPOINT active_record_1
COMMIT
```

As you can see the second _INSERT_ query is wrapped into `SAVEPOINT`/`RELEASE SAVEPOINT`. This way a nested transaction is emulated.

There is one more useful option - `joinable: false`. It means that any nested transaction will not be absorbed by the one created with `joinable: false`.

```ruby
ActiveRecord::Base.transaction(joinable: false) do
  Account.create(name: 'KFC')
  Account.create(name: "McDonald's")
end
```

```sql
BEGIN
  SAVEPOINT active_record_1
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "KFC"]]
  RELEASE SAVEPOINT active_record_1

  SAVEPOINT active_record_1
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "McDonald's"]]
  RELEASE SAVEPOINT active_record_1
COMMIT
```

It works this way also for a nested call of `transaction` method - it also causes wrapping of SQL queries into `SAVEPOINT`/`RELEASE SAVEPOINT`.

```ruby
ActiveRecord::Base.transaction(joinable: false) do
  ActiveRecord::Base.transaction do
    Account.find_by(name: 'KFC')
  end
end
```

```sql
BEGIN
  SAVEPOINT active_record_1
  SELECT  "accounts".* FROM "accounts" WHERE "accounts"."name" = $1 LIMIT $2  [["name", "KFC"], ["LIMIT", 1]]
  RELEASE SAVEPOINT active_record_1
COMMIT
```

If there several levels of transactions nesting then only the top level nested transactions aren't absorbed. All the transaction on the lower leves are still absorbed.

```ruby
ActiveRecord::Base.transaction(joinable: false) do
  ActiveRecord::Base.transaction do
    ActiveRecord::Base.transaction do
      Account.find_by(name: 'KFC')
    end
  end
end
```

```sql
BEGIN
  SAVEPOINT active_record_1
  SELECT  "accounts".* FROM "accounts" WHERE "accounts"."name" = $1 LIMIT $2  [["name", "KFC"], ["LIMIT", 1]]
  RELEASE SAVEPOINT active_record_1
COMMIT
```


### Transactions rolling back

Transaction is rolled back automatically when an exception is raised.

```ruby
ActiveRecord::Base.transaction do
  Account.create(name: 'KFC')
  raise
end
```

```sql
BEGIN
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "KFC"]]
ROLLBACK
```

If exception is raised inside a nested transaction then both outer and nested ones are rolled back.

```ruby
ActiveRecord::Base.transaction do
  Account.create(name: 'KFC')

  ActiveRecord::Base.transaction(requires_new: true) do
    Account.create(name: "McDonald's")
    raise
  end
end
```

```sql
BEGIN
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "KFC"]]

  SAVEPOINT active_record_1
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "McDonald's"]]
  ROLLBACK TO SAVEPOINT active_record_1
ROLLBACK
```

There is a special exception `ActiveRecord::Rollback`, that is handled in special way. Usual exception will cause a transaction rolling back and will be re-raised again. `ActiveRecord::Rollback` causes only a transaction rolling back and doesn't cause re-raising. This way it's possible to roll back one nested transaction but dont't affect the outer one.

```ruby
ActiveRecord::Base.transaction do
  Account.create(name: 'KFC')

  ActiveRecord::Base.transaction(requires_new: true) do
    Account.create(name: "McDonald's")
    raise ActiveRecord::Rollback
  end
end
```

```sql
BEGIN
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "KFC"]]

  SAVEPOINT active_record_1
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "McDonald's"]]
  ROLLBACK TO SAVEPOINT active_record_1
COMMIT
```

There is a tiny nuance. We have seen that if a nested transaction is run without `requires_new: true` option, then it's absorbed and joined to an outer transaction, so in fact there is no any nested transaction. Consequantly it isn't possible to rollback or commit it. But the `ActiveRecord::Rollback` exception with be rescued nevetheless on the level of this absorbed ephimeral not existing nested transaction, and this way changes will not be rolled back.

```ruby
ActiveRecord::Base.transaction do
  Account.create(name: 'KFC')

  ActiveRecord::Base.transaction do
    Account.create(name: "McDonald's")
    raise ActiveRecord::Rollback
  end
end
```

```sql
BEGIN
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "KFC"]]
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "McDonald's"]]
COMMIT
```

### PS

All the examples above were checked with both Rails 4.2 and the current Rails 5.2, so we can cosider it as a stable behaviour.

There was not concidered pessimistic locking that is toughly coupled to transactions ([PostgreSQL documentation](https://www.postgresql.org/docs/current/sql-select.html#SQL-FOR-UPDATE-SHARE)). As a quick note - it's implemeted in Rails with the following methods:
* `ActiveRecord::Base#lock!`,
* `ActiveRecord::Base#with_lock`
* and `ActiveRecord::QueryMethods#lock`

It's described in details in the Rails documentation here - [ActiveRecord::Locking::Pessimistic](https://api.rubyonrails.org/classes/ActiveRecord/Locking/Pessimistic.html).

### Links

* [Active Record Transactions (API Reference)](https://api.rubyonrails.org/classes/ActiveRecord/Transactions/ClassMethods.html)
* [ActiveRecord::Rollback (API Reference)](https://makandracards.com/makandra/42885-nested-activerecord-transaction-pitfalls)
* [ActiveRecord::ConnectionAdapters::DatabaseStatements.transaction (source code)](https://github.com/rails/rails/blob/v4.2.11.1/activerecord/lib/active_record/connection_adapters/abstract/database_statements.rb#L128-L217)
* [Nested ActiveRecord transaction pitfalls](https://makandracards.com/makandra/42885-nested-activerecord-transaction-pitfalls)

[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
