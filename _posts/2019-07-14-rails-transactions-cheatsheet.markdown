---
layout:     post
title:      "Шпаргалка по транзакциям в Rails"
date:       2019-07-14 19:53
categories: Ruby
extra_head: |
  <style>
    pre code { white-space: pre; }
  </style>
---


Недавно разбираясь с багой в коде `after_commit` _callback_'а в текущем проекте я внезапно осознал, что смутно представляю когда и как ActiveRecord создает неявные транзакции. `after_commit` вызывается при завершении транзакции и важно понимать где и когда это происходит. Особенно меня интересовали _вложенные_ неявные транзакции. Изучив тему, пришла мысль систематизировать и оформить все в виде такой себе шпаргалки по работе с транзакциями в Rails. Для наглядности везде приводятся генерируемые SQL-запросы на примере PostgreSQL, так как обычно это опускают и в статьях и документации по Rails.

### Неявные транзакции

Как всем хорошо известно ActiveRecord неявно оборачивает все операции на которые можно навесить _callback_'и (`create`/`save`/`update`/`destroy`, `touch`, `toggle`) в транзакции.

```ruby
Account.create(name: 'KFC')
```

```sql
BEGIN
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "KFC"]]
COMMIT
```

Транзакция начинается командой `BEGIN` и завершается командой `COMMIT`. Для отката всех изменений транзакции используется команда `ROLLBACK` ([PostgreSQL documentation](https://www.postgresql.org/docs/11/tutorial-transactions.html)).

Если сохраняется целое дерево объектов (основная модель и ассоциированные с ней объекты), то эти операции также оборачиваются в одну общую транзакцию.

```ruby
Account.create(
  name: 'KFC',
  payments: [Payment.new(amount: 10), Payment.new(amount: 13)]
)
```

```sql
BEGIN
  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "KFC"]]
  INSERT INTO "payments" ("amount", "account_id") VALUES ($1, $2) RETURNING "id"  [["amount", "10.0"], ["account_id", 1]]
  INSERT INTO "payments" ("amount", "account_id") VALUES ($1, $2) RETURNING "id"  [["amount", "13.0"], ["account_id", 1]]
COMMIT
```

### Явные транзакции

Чтобы создать транзакцию явно, нужно использовать метод `ActiveRecord::Base.transaction`, вызывать метод `transaction` на любом классе модели или на самом экземпляре. Все операции в транзакции оборачиваются в стандартный блок `BEGIN`/`COMMIT`.

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

Хотя вызов `Account.create` должен создавать свою транзакцию, внутри явно открытой транзакции неявная вложенная транзакция "поглощается". Т.е. по умолчанию вложенная транзакция не создается.

Аналогично вызов `transaction` внутри другой явной транзакции не приводит к созданию вложенной.

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

### Вложенные транзакции

Настоящие вложенные транзакции поддерживаются (согласно документации Rails) только в MS SQL, и в остальных поддерживаемых Rails РСУБД они имитируются _save point_'ами ([PostgreSQL documentation](https://www.postgresql.org/docs/11/sql-savepoint.html)). Как следует из названия это просто точки восстановления, которые дают возможность откатить сделанные изменения до сохраненного ранее _save point_'а. Как в компьютерных играх к сохраненному состоянию можно возвращаться множество раз из произвольного места в транзакции.

Доступные следующий операции:
* `SAVEPOINT` - создать _save point_
* `ROLLBACK TO SAVEPOINT` - востановить состояние на момент создания _save point_'а
* `RELEASE SAVEPOINT` - удалить _save point_

Использовать _save point_'ы можно только внутри транзакции (блока `BEGIN`/`COMMIT`). Очевидно, что это не полноценные транзакции, так как из свойств ACID этот механизм предоставляет только _atomicity_ ("A"). Изоляция ("I") не обеспечивается, так как если созданы несколько _save point_'ов последовательно, то изменения в одной из них будут видны в остальных, в отличии от настоящих транзакций. Долговечность ("D") тоже не гарантируется - завершение вложенной "транзакции" (`RELEASE SAVEPOINT`) не означает сброс данных на диск, в отличии от завершения настоящей транзакции (командой `COMMIT`).

Согласно документации _save point_ должен автоматически удаляться если создается новый _save point_ с таким же именем. В PostgreSQL предыдущий _save point_ не удаляется и будет доступен снова после того как новый _save point_ будет удален.

По умолчанию ActiveRecord не создает вложенную транзакцию (транзакцию в терминах Rails, не базы данных). Чтобы ее все таки создать, нужно использовать опцию `requires_new: true`.

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

Как видно, второй `INSERT`-запрос обернут в `SAVEPOINT`/`RELEASE SAVEPOINT`. Так имитируется вложенная транзакция.

Есть еще одна полезная опция `joinable: false`. Она означает, что любая вложенная транзакция не будет "поглощаться" внешней (если ту создать с `joinable: false`) .

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

То же самое можно наблюдать для вложенного вызова `transaction` - он тоже теперь оборачивается в `SAVEPOINT`/`RELEASE SAVEPOINT`.

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

Если есть несколько уровней вложенных транзакций, то не "поглощаются" только вложенные транзакции верхнего уровня. Остальные вложенные транзакции будут "поглощены".

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


### Откат транзакций

Откат транзакции происходит автоматически, если был брошен _exception_.

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

Если exception брошен из вложенной транзакции, очевидно, откатывается как вложенная так и внешняя транзакция.

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

Есть специальный _exception_ `ActiveRecord::Rollback`, который обрабатывается в транзакции особым образом. Обычный _exception_ приведет к откату транзакции и будет брошен повторно. `ActiveRecord::Rollback` приводит к откату транзакцию но повторно он не бросается. Так, например, можно откатить вложенную транзакцию но не прерывать внешнюю.

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

Здесь есть одна тонкость в реализации этого механизма ActiveRecord. Как мы видели, если вложенная транзакция была объявлена без `requires_new: true`, то она присоединяется к внешней транзакции, и фактически никакой вложенной транзакции нет. Соответственно, ее нельзя ни откатить ни закомитить. Но `ActiveRecord::Rollback` _exception_ все равно будет перехватываться на уровне этой "присоединенной" несуществующей вложенной транзакции и, таким образом, никакого отката изменений не будет.

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

### Заключение

Приведенные примеры проверялось как на Rails 4.2 так и на текущей версии Rails 5.2, поэтому можно рассчитывать на стабильность этого поведения.

Здесь не был рассмотрен вопрос пессимистичных блокировок, которые тесно связаны с транзакциями ([PostgreSQL documentation](https://www.postgresql.org/docs/current/sql-select.html#SQL-FOR-UPDATE-SHARE)). В Rails это реализуется с помощью методов:
* `ActiveRecord::Base#lock!`,
* `ActiveRecord::Base#with_lock`
* и `ActiveRecord::QueryMethods#lock`

Детальнее это описано здесь - [ActiveRecord::Locking::Pessimistic](https://api.rubyonrails.org/classes/ActiveRecord/Locking/Pessimistic.html).

### Ссылки

* [Active Record Transactions (API Reference)](https://api.rubyonrails.org/classes/ActiveRecord/Transactions/ClassMethods.html)
* [ActiveRecord::Rollback (API Reference)](https://makandracards.com/makandra/42885-nested-activerecord-transaction-pitfalls)
* [ActiveRecord::ConnectionAdapters::DatabaseStatements.transaction (source code)](https://github.com/rails/rails/blob/v4.2.11.1/activerecord/lib/active_record/connection_adapters/abstract/database_statements.rb#L128-L217)
* [Nested ActiveRecord transaction pitfalls](https://makandracards.com/makandra/42885-nested-activerecord-transaction-pitfalls)

[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
