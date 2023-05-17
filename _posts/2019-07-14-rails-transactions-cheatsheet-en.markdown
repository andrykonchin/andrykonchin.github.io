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


While working on my latest Rails project, I encountered a bug that was related to code in an `after_commit` callback. This made me realize that I didn't fully understand implicit database transactions. The `after_commit` callback is called after a transaction completes, so it's important to understand when and how transactions occur. I was particularly interested in _nested implicit_ transactions, so I created this cheat sheet to help me learn more about this topic. This cheat sheet includes multiple examples of SQL queries (specific to PostgreSQL), which is something that I was missing from other guides and blog posts.


### Implict transactions

When you perform a modifying operation in ActiveRecord, such as `create`, `save`, `update`, `destroy`, `touch`, or `toggle`, ActiveRecord automatically starts a transaction. This transaction is committed when the operation completes successfully, or rolled back if the operation raises an exception. This behavior ensures that any changes made to the database as a result of the operation are always atomic, meaning that either all of the changes are made, or none of them are. This is a useful feature for ensuring data integrity.

Let's imagine that we execute the following Ruby code:

```ruby
Account.create(name: 'KFC')
```

The resulting SQL query for the code above would be:

```sql
BEGIN
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id" -- [["name", "KFC"]]
COMMIT
```

The transaction initiates with the `BEGIN` command and concludes with the `COMMIT` command. To undo all the data modifications made during the transaction, the `ROLLBACK` command is employed (as stated in the ([PostgreSQL documentation](https://www.postgresql.org/docs/11/tutorial-transactions.html))).

In the scenario where the entire model graph needs to be saved, encompassing the root model and its associations, all the corresponding SQL  queries are grouped together within a single transaction.

Consider an example where we create an account model accompanied by two associated payments:

```ruby
Account.create(
  name: 'KFC',
  payments: [Payment.new(amount: 10), Payment.new(amount: 13)]
)
```

The SQL query result will be as follows:

```sql
BEGIN
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id" --  [["name", "KFC"]]
  INSERT INTO "payments" ("amount", "account_id") VALUES ($1, $2) RETURNING "id" -- [["amount", "10.0"], ["account_id", 1]]
  INSERT INTO "payments" ("amount", "account_id") VALUES ($1, $2) RETURNING "id" -- [["amount", "13.0"], ["account_id", 1]]
COMMIT
```

So this transaction is implicit as far as we don't explicitly enable it.


### Explicit transactions

If you want to establish a transaction explicitly, you have multiple options at your disposal. One approach is to utilize the `ActiveRecord::Base.transactio`n method, which is a class method available in all ActiveRecord model classes. Alternatively, you can employ the `transaction` instance method. Regardless of the method chosen, all SQL queries executed within transactions are automatically enclosed within a `BEGIN`/`COMMIT` block.

```ruby
ActiveRecord::Base.transaction do
  Account.create(name: 'KFC')
end
```

```sql
BEGIN
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id" -- [["name", "KFC"]]
COMMIT
```

While the `create` method call usually triggers an implicit transaction of its own, it behaves differently when executed within an explicitly initiated transaction. In such cases, any implicit nested transaction is assimilated and effectively skipped by default.

Similarly, when the transaction method is explicitly used within another explicitly initiated transaction, it does not initiate a new nested transaction.

```ruby
ActiveRecord::Base.transaction do
  ActiveRecord::Base.transaction do
    Account.create(name: 'KFC')
  end
end
```

```sql
BEGIN
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id" -- [["name", "KFC"]]
COMMIT
```


### Nested transactions

According to the Rails [documentation](https://api.rubyonrails.org/classes/ActiveRecord/Transactions/ClassMethods.html#module-ActiveRecord::Transactions::ClassMethods-label-Nested+transactions), true nested transactions are exclusively supported by Microsoft SQL Server. Other supported RDBMS in Rails emulate nested transactions using _savepoints_, as outlined in the [PostgreSQL documentation](https://www.postgresql.org/docs/11/sql-savepoint.html). Savepoints act as checkpoints within a transaction, allowing for the rollback of changes made up to a specific savepoint. Similar to the concept of saving progress in video games, it is possible to restore the same savepoint multiple times at any arbitrary point within a transaction.

Within PostgreSQL, you can utilize the following commands for savepoints:

* `SAVEPOINT`: this command is employed to create a savepoint, enabling you to designate a specific checkpoint within a transaction.
* `ROLLBACK TO SAVEPOINT`: with this command, you can restore the transaction to the state it was in when the savepoint was created.
* `RELEASE SAVEPOINT`: use this command to remove a savepoint, effectively discarding any modifications made after the savepoint was established.

In PostgreSQL, savepoints can only be used within a transaction defined by the `BEGIN`/`COMMIT` block. However, it's important to understand that savepoints do not provide the complete set of features associated with transactions, including all the ACID properties. While they do ensure atomicity (the "A" in ACID) by treating changes as a single unit, they do not guarantee isolation (the "I" in ACID) - there is no way to associate SQL query with some savepoint. Additionally, durability (the "D" in ACID) is not guaranteed because a safepoint couldn't be commited on its own before the outer real transaction is commited.

According to the documentation, when a new savepoint is created with the same name, the previous savepoint is automatically replaced. Nevertheless, in PostgreSQL, the previous savepoint is not removed and remains accessible once the new savepoint is removed.

In ActiveRecord nested transactions are not automatically created by default. To explicitly enforce the creation of a nested transaction, you can utilize the `requires_new: true` option.

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
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id" -- [["name", "KFC"]]

  SAVEPOINT active_record_1
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id" -- [["name", "McDonald's"]]
  RELEASE SAVEPOINT active_record_1
COMMIT
```

As you can observe, the second _INSERT_ query is encapsulated within `SAVEPOINT`/`RELEASE SAVEPOINT` statements.

Additionally, there is the `joinable: false` option, which prevents any nested transaction from being assimilated into the transaction created with this option.

```ruby
ActiveRecord::Base.transaction(joinable: false) do
  Account.create(name: 'KFC')
  Account.create(name: "McDonald's")
end
```

```sql
BEGIN
  SAVEPOINT active_record_1
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id" -- [["name", "KFC"]]
  RELEASE SAVEPOINT active_record_1

  SAVEPOINT active_record_1
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id" -- [["name", "McDonald's"]]
  RELEASE SAVEPOINT active_record_1
COMMIT
```

This behavior also applies to nested calls of the `transaction` method, as it also triggers the wrapping of SQL queries into `SAVEPOINT`/`RELEASE SAVEPOINT` statements.

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
  SELECT  "accounts".* FROM "accounts" WHERE "accounts"."name" = $1 LIMIT $2 -- [["name", "KFC"], ["LIMIT", 1]]
  RELEASE SAVEPOINT active_record_1
COMMIT
```

If there are multiple levels of transaction nesting, it is important to note that only the transactions at the highest level remain. Transactions at lower levels, however, are still absorbed by the enclosing transaction.

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
  SELECT  "accounts".* FROM "accounts" WHERE "accounts"."name" = $1 LIMIT $2 -- [["name", "KFC"], ["LIMIT", 1]]
  RELEASE SAVEPOINT active_record_1
COMMIT
```


### Transactions rolling back

If an exception is raised during the execution, the transaction is rolled back automatically.

```ruby
ActiveRecord::Base.transaction do
  Account.create(name: 'KFC')
  raise
end
```

```sql
BEGIN
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id" -- [["name", "KFC"]]
ROLLBACK
```

When an exception occurs within a nested transaction, both the outer transaction and the nested transaction are rolled back.

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
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id" -- [["name", "KFC"]]

  SAVEPOINT active_record_1
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id" -- [["name", "McDonald's"]]
  ROLLBACK TO SAVEPOINT active_record_1
ROLLBACK
```

It's worth noting the special handling of the `ActiveRecord::Rollback` exception. While a standard exception results in a transaction rollback and subsequent re-raising, the `ActiveRecord::Rollback` exception solely triggers a transaction rollback without re-raising. This unique behavior allows for selectively rolling back a specific nested transaction without influencing the outer transaction.

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
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id" -- [["name", "KFC"]]

  SAVEPOINT active_record_1
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id" -- [["name", "McDonald's"]]
  ROLLBACK TO SAVEPOINT active_record_1
COMMIT
```

It is worth noting a subtle nuance. If a nested transaction is executed without the `requires_new: true` option, it becomes absorbed and integrated into the outer transaction. As a result, it's impossible to explicitly rollback or commit this absorbed transaction. An `ActiveRecord::Rollback` exception raised within a nested transaction will still be rescued within this absorbed, ephemeral, non-existent nested transaction, allowing changes to persist instead of being rolled back.

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
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id" -- [["name", "KFC"]]
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id" -- [["name", "McDonald's"]]
COMMIT
```

### PS

The behavior described in the examples has been validated using both Rails 4.2 and the current Rails 5.2. Hence, we can conclude that this behavior is stable and remains consistent across these versions.

There was not concidered pessimistic locking in the post that is toughly coupled to transactions ([PostgreSQL documentation](https://www.postgresql.org/docs/current/sql-select.html#SQL-FOR-UPDATE-SHARE)). As a quick note - it's implemeted in Rails with the following methods:
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
