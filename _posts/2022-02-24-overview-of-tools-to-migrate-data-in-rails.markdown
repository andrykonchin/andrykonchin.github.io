---
layout: post
title:  Как мигрировать данные в Rails-приложении
date:   2022-02-24 18:00
categories: Ruby Rails
---


Rails-миграции подходят для маленьких и коротких миграций. В идеале без _downtime_. Это разумный выбор для нового проекта. База данных относительно маленькая, пользователей мало. _Downtime_ - не проблема. Бага - тоже не страшно.

Но с ростом проекта меняются и требования. Становится критичным качество, поэтому миграции данных надо тестировать. База разрастается, поэтому миграции данных идут дольше. Теперь данные не мигрирует при деплое. _Downtime_ уже не вариант, разве что когда у пользователей ночь. И со временем проекты уходят от миграций Rails. Стандартный выбор - Rake-задачи.

Плюсы подхода с Rake-задачами:
* легко написать _unit_-тесты
* запускать вручную и больше одного раза
* а затем удалить после релиза

Единственный минус - Rake-задачи надо запускаются вручную и на каждом окружении (_production_, _staging_). Появляется человеческий фактор, а значит риск ошибиться. Тратятся время и нервы инженеров.

Но Rake-задачи не единственный выход. Появилась куча _gem_'ов, которые берутся решать проблемы как миграций Rails, так и подхода с Rake-задачами. Рассмотрим их внимательнее.

**DISCLAIMER:** Я не пользовался этими _gem_'ами в _production_'е.



### Содержание
{:.no_toc}

* A markdown unordered list which will be replaced with the ToC, excluding the "Contents header" from above
{:toc}



### data-migrate

<https://github.com/ilyakatz/data-migrate>

_data-migrate_ решает только одну проблему - переносит миграции данных в отдельную директорию.

Ключевые моменты:
* миграции данных - в отдельной директории _db/data_
* список запущенных миграций хранится в таблице базы данных _data_migrations_, аналогичной стандартной в Rails таблице _schema_migrations_
* в комплекте идут 22 Rake-задачи, аналогичные стандартным:
  * для запуска и отката конкретной миграции,
  * получить статус миграций
  * создать или применить файл _db/data_schema.rb_ со списком миграций итд
* можно накатить отдельно миграции данных - командой `rake data:migrate`
* можно накатать сразу и миграции данных и схемы в правильном порядке (отсортированные по _timestamp_'у) командой `rake db:migrate:with_data`
* 1к звезд на GitHub, 7M скачиваний на RubyGems

После добавления _gem_'а в проект при первом запуске миграций данных _data-migrate_ автоматически создаст таблицу _data_migrations_ и файл _db/data_schema.rb_.

Если создать пустой Rails-проект, добавить _data-migrate_ и запустить `bin/rails db:migrate` и затем `bin/rails data:migrate`, то база будет выглядеть так (на примере SQLite):

```
sqlite> .fullschema
CREATE TABLE IF NOT EXISTS "schema_migrations" ("version" varchar NOT NULL PRIMARY KEY);
CREATE TABLE IF NOT EXISTS "ar_internal_metadata" ("key" varchar NOT NULL PRIMARY KEY, "value" varchar, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
CREATE TABLE IF NOT EXISTS "data_migrations" ("version" varchar NOT NULL PRIMARY KEY);
```

Создадим таблицу для экспериментов:

```ruby
class CreateUsers < ActiveRecord::Migration[7.0]
  def change
    create_table :users do |t|
      t.string :full_name

      t.timestamps
    end
  end
end
```

И затем первую миграцию данных. Сгенерируем файл командой:

```
$ bin/rails g data_migration AnonymizeUserFullName
```

Отметим, что созданная миграция данных ничем не отличается от миграции Rails:

```ruby
# frozen_string_literal: true

class AnonymizeUserFullName < ActiveRecord::Migration[7.0]
  def up
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
```

Добавим SQL-запрос для модификации колонки таблицы:

```ruby
def up
  execute <<~SQL
    update users set full_name = 'John Doe'
  SQL
end
```

Запустим миграцию данных:

```
$ bin/rails data:migrate
== 20220204001632 AnonymizeUserFullName: migrating ============================
-- execute("update users set full_name = 'John Doe'\n")
   -> 0.0055s
== 20220204001632 AnonymizeUserFullName: migrated (0.0056s) ===================
```

Запущенная миграция сразу отражается в файле _db/data_schema.rb_

```ruby
DataMigrate::Data.define(version: 20220204001632)
```

Итоговая структура файлов в директории _db_:

```
▾ db/
  ▾ data/
      20220204001632_anonymize_user_full_name.rb
  ▾ migrate/
      20220204001454_create_users.rb
    data_schema.rb
    schema.rb
```

Проверим, как поддерживается порядок запуска миграций схемы и данных. Добавим новую миграцию схемы, которая создает таблицу _projects_. Затем пересоздадим базу данных и накатим все миграции с нуля командой `rake db:migrate:with_data`

```
$ bin/rails db:migrate:with_data
== Schema =====================================================================
== 20220204001454 CreateUsers: migrating ======================================
-- create_table(:users)
   -> 0.0016s
== 20220204001454 CreateUsers: migrated (0.0017s) =============================

== Data =======================================================================
== 20220204001632 AnonymizeUserFullName: migrating ============================
-- execute("update users set full_name = 'John Doe'\n")
   -> 0.0158s
== 20220204001632 AnonymizeUserFullName: migrated (0.0159s) ===================

== Schema =====================================================================
== 20220204002538 CreateProjects: migrating ===================================
-- create_table(:projects)
   -> 0.0017s
== 20220204002538 CreateProjects: migrated (0.0018s) ==========================
```

Как видим, миграции запустились в правильном порядке - сначала создается таблица _users_, затем миграция данных, а затем создается таблица _projects_. Все упорядочены по времени создания.

Проверим статус миграций:

```
$ bundle exec rake db:migrate:status:with_data

database:

 Status    Type    Migration ID   Migration Name
------------------------------------------------------------
   up     schema  20220204001454  Create users
   up      data   20220204001632  Anonymize user full name
   up     schema  20220204002538  Create projects
```

Все миграции (и схемы и данных) отмечены в одном списке как примененные.



### after_party

<https://github.com/theSteveMitchell/after_party>

_after_party_ решает главную проблему подхода с Rake-задачами - ручной запуск новых Rake-задач с миграциями данных при деплое.

Ключевые моменты:
* миграции - это Rake-задачи
* миграции - в отдельной директории _lib/tasks/deployment/_
* запущенные миграции трекаются в отдельной таблице _task_records_ в базе данных, аналогичной стандартной в Rails таблице _schema_migrations_
* при деплое выполняют команду `rake after_party:run`, которая запускает все еще не примененные в этом окружении Rake-задачи с миграциями данных
* миграцию данных запускают после Rails миграций схемы.
* ~100 звезд на GitHub, 1M скачиваний на RubyGems

При добавлении _gem_' надо настроить - сгенерировать конфигурационный файл и миграцию с созданием таблицы _task_records_:

```
$ rails generate after_party:install
      create  config/initializers/after_party.rb
      create  db/migrate/20220212173610_create_task_records.rb
```

Новый конфигурационный файл:

```ruby
# config/initializers/after_party.rb

AfterParty.setup do |config|
  # ==> ORM configuration
  # Load and configure the ORM. Supports :active_record (default) and
  # :mongoid (bson_ext recommended) by default. Other ORMs may be
  # available as additional gems.
  require 'after_party/active_record.rb'
end
```

Миграция с созданием таблицы _task_records_:

```ruby
# db/migrate/20220212173610_create_task_records.rb

class CreateTaskRecords < ActiveRecord::Migration[7.0]
  def change
    create_table :task_records, :id => false do |t|
      t.string :version, :null => false
    end
  end
end
```

Структура аналогична таблице _schema_migrations_ - сохраняется только версия (_timestamp_) запущенных миграций.

Запустим Rails миграции, чтобы создать таблицу:

```
$ bin/rails db:migrate
== 20220212173610 CreateTaskRecords: migrating ================================
-- create_table(:task_records, {:id=>false})
   -> 0.0011s
== 20220212173610 CreateTaskRecords: migrated (0.0011s) =======================
```

Создадим миграцию данных (и предварительно создадим еще таблицу _users_ как в прошлом примере):

```
$ bin/rails generate after_party:task update_user_full_names
      create  lib/tasks/deployment/20220212174826_update_user_full_names.rake
```

Сгенерировалась новая Rake-задача:

```ruby
namespace :after_party do
  desc 'Deployment task: update_user_full_names'
  task update_user_full_names: :environment do
    puts "Running deploy task 'update_user_full_names'"

    # Put your task implementation HERE.

    # Update task as completed.  If you remove the line below, the task will
    # run with every deploy (or every time you call after_party:run).
    AfterParty::TaskRecord
      .create version: AfterParty::TaskRecorder.new(__FILE__).timestamp
  end
end
```

Повторим наш пример с миграцией таблицы _users_ - меняем значение колонки _full_name_:

```ruby
ActiveRecord::Base.connection.update("update users set full_name = 'John Doe'")
```

Запускаем миграцию данных:

```
$ bundle exec rake after_party:run
Running deploy task 'update_user_full_names'
```

Это зафиксировалось в статусе миграций:

```
bundle exec rake after_party:status
Status   Task ID         Task Name
--------------------------------------------------
  up     20220212174826  Update user full names
```

Повторный запуск миграций игнорирует уже запущенную миграцию:

```
$ bundle exec rake after_party:run
no pending tasks to run
```

_after_party_ решает некоторые проблемы миграций Rails:
* миграции данных находятся в отдельной директории (_lib/tasks/deployment_)
* миграцию можно легко протестировать - раз это стандартная Rake-задача
* миграцию можно запустить руками повторно
* длинную миграцию можно запустить асинхронно при деплое с помощью команды `nohup <command> &`

Я бы отметил одну очевидную проблему с таким подходом. В общем случае не выйдет мигрировать старую или отставшую базу данных, например бэкап. Нельзя запустить миграции схемы и миграции данных за нескольких релизов в том же порядке, в каком они прошли на _production_'е, так как мы можем запустить их только отдельно. Сначала все миграции схема, а затем все миграции данных. Нам же надо, чтобы сначала запустились миграции одного релиза, потом следующего и так до самого конца.

Рассмотрим вариант с переносом столбца из одной таблицы в другую. В релизе 1 в миграции схемы мы создали новый столбец в таблице и в миграции данных скопировали значение из другой таблицы. В релизе 2 мы удаляем старый столбец. А теперь представим, что у нас есть дамп базы созданный до релиза 1 и нам надо обновить его до текущего состояния. Мы запускаем миграции Rails, которые создают новый столбец и затем удаляют старый. Затем мы запускаем миграции данных и наша миграция копирования столбца падает, так как старый столбец уже удален.



### migration_data

<https://github.com/ka8725/migration_data>

Довольно скромный _gem_ _migration_data_ создавался, чтобы решить все проблемы миграций Rails ([статья автора][1]). Но в итоге только упрощает тестирование. Вернее только подключение файла миграции в тесте.

Ключевые моменты:
* дополняет механизм миграций Rails и добавляет несколько методов к стандартным `up`, `down` и `change`:
    * `data`
    * `rollback`
    * `data_before`, `data_after`
    * `rollback_before`, `rollback_after`
* появляется тестовый _helper_ `require_migration`
* ~300 звезд на GitHub, 1M скачиваний на RubyGems

Создадим миграцию для таблицы _users_:

```ruby
class MigrateUserFullNames < ActiveRecord::Migration[7.0]
  def change
  end

  def data
    execute <<~SQL
      update users set full_name = 'John Doe'
    SQL
  end
end
```

В ней появляется метод _data_, в который и помещается код миграции данных. Метод `change` остается пустым.

Запустим миграцию:

```
$ bin/rails db:migrate
== 20220212205020 MigrateUserFullNames: migrating =============================
-- execute("update users set full_name = 'John Doe'\n")
   -> 0.0012s
== 20220212205020 MigrateUserFullNames: migrated (0.0012s) ====================
```

Метод `change` можно опустить и оставить только миграцию данных

```ruby
class MigrateUserFullNames < ActiveRecord::Migration[7.0]
  def data
    execute <<~SQL
      update users set full_name = 'John Doe'
    SQL
  end
end
```

Теперь давайте посмотрим как это тестировать. Инстанцируем класс миграции (без параметров) и вызываем метод `data`:

```ruby
require 'rails_helper'
require 'migration_data/testing'
require_migration 'migrate_user_full_names'

RSpec.describe MigrateUserFullNames do
  describe '#data' do
    it 'updates full_name attribute' do
      user = User.create!(full_name: 'Robin Hood')

      described_class.new.data

      expect(user.reload.full_name).to eq('John Doe')
    end
  end
end
```

Метод `require_migration` подключает нашу миграцию по имени, без версии и пути:

```ruby
require_migration 'migrate_user_full_names'
```

Тест успешно запускается и проходит.

```
$ bundle exec rspec spec/db/migrations/migrate_user_full_names_spec.rb
-- execute("update users set full_name = 'John Doe'\n")
   -> 0.0001s
.


Finished in 0.01534 seconds (files took 2 seconds to load)
1 example, 0 failures
```

Это равносильно прямолинейному `require`:

```ruby
require './db/migrate/20220212205020_migrate_user_full_names'
```

Такой тест использует текущую схему базы данных, и не выполняет откат до версии, на которой должна запускаться миграция данных. Если схема таблиц, вовлеченных в миграцию, изменилась (например, удалили или переименовали столбец), тест начнет падать.

На мой взгляд этот _gem_ не решает ни одну из проблем миграций Rails.



### rails-data-migrations

<https://github.com/OffgridElectric/rails-data-migrations>

_rails-data-migrations_ похож на _data-migrate_ и решает ту же самую проблему - переносит миграции данных в отдельную директорию.

Ключевые моменты:
* миграции - в отдельной директории _db/data_migrations_
* список запущенных миграций хранится в таблице базы данных _data_migrations_, аналогичной стандартной в Rails таблице _schema_migrations_
* есть несколько незадокументированных Rake-задач с говорящими названиями:
    * `data:reset`
    * `data:migrate:up`
    * `data:migrate:down`
    * `data:migrate:skip`
    * `data:migrate:pending`
* можно накатить только миграции данных - `rake data:migrate`
* ~100 звезд на GitHub, 200k скачиваний на RubyGems

После добавления _gem_'а в проект при первом запуске миграций данных _rails-data-migrations_ автоматически создаст таблицу _data_migrations_.

Структура таблиц в базе:

```
sqlite> .fullschema
CREATE TABLE IF NOT EXISTS "schema_migrations" ("version" varchar NOT NULL PRIMARY KEY);
CREATE TABLE IF NOT EXISTS "ar_internal_metadata" ("key" varchar NOT NULL PRIMARY KEY, "value" varchar, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
CREATE TABLE IF NOT EXISTS "data_migrations" ("version" varchar NOT NULL PRIMARY KEY);
```

Сгенерируем первую миграцию данных:

```
$ rails generate data_migration MigrateUserFullNames
      create  db/data_migrations/20220213001232_migrate_user_full_names.rb
```

Новая миграция выглядит следующим образом:

```ruby
class MigrateUserFullNames < ActiveRecord::DataMigration
  def up
    # put your code here
  end
end
```

Добавим нашу миграцию таблицы _users_:

```ruby
class MigrateUserFullNames < ActiveRecord::DataMigration
  def up
    execute <<~SQL
      update users set full_name = 'John Doe'
    SQL
  end
end
```

И запустим командой `rake data:migrate`:

```
$ bundle exec rake data:migrate
== 20220213001232 MigrateUserFullNames: migrating =============================
-- execute("update users set full_name = 'John Doe'\n")
   -> 0.0012s
== 20220213001232 MigrateUserFullNames: migrated (0.0013s) ====================
```

Вроде бы все правильно отработало.

Я позапускал доступные Rake-задачи и заметил, что `rake data:migrate:down` работает неправильно. Эта команда должна откатить конкретную миграцию, но в таблице _data_migrations_ версия миграции не удаляется. И последующая накатка миграции командой `rake data:migrate:up` завершается ошибкой:

```
$ bundle exec rake data:migrate:down VERSION=20220213001232

$ bundle exec rake data:migrate:up VERSION=20220213001232
== 20220213001232 MigrateUserFullNames: migrating =============================
-- execute("update users set full_name = 'John Doe'\n")
   -> 0.0012s
== 20220213001232 MigrateUserFullNames: migrated (0.0012s) ====================

rake aborted!
StandardError: An error has occurred, this and all later migrations canceled:

SQLite3::ConstraintException: UNIQUE constraint failed: data_migrations.version
/Users/andrykonchin/.rbenv/versions/3.0.0/bin/bundle:23:in `load'
/Users/andrykonchin/.rbenv/versions/3.0.0/bin/bundle:23:in `<main>'

Caused by:
ActiveRecord::RecordNotUnique: SQLite3::ConstraintException: UNIQUE constraint failed: data_migrations.version
/Users/andrykonchin/.rbenv/versions/3.0.0/bin/bundle:23:in `load'
/Users/andrykonchin/.rbenv/versions/3.0.0/bin/bundle:23:in `<main>'

Caused by:
SQLite3::ConstraintException: UNIQUE constraint failed: data_migrations.version
/Users/andrykonchin/.rbenv/versions/3.0.0/bin/bundle:23:in `load'
/Users/andrykonchin/.rbenv/versions/3.0.0/bin/bundle:23:in `<main>'
Tasks: TOP => data:migrate:up
(See full trace by running task with --trace)
```

Очевидно, что при накатывании миграции ее версия сохраняется в таблице _data_migrations_. Но там уже есть эта версия добавленная в  предыдущий раз. Зарепортил багу автору на GitHub ([issue][2])



### nonschema_migrations

<https://github.com/jasonfb/nonschema_migrations>

_nonschema_migrations_ - использует подход _data-migrate_. Главная цель - вынести миграции данных в отдельную директорию.

Ключевые моменты:
* миграции данных находятся в отдельной директории _db/data_migrate_
* список запущенных миграций хранится в таблице базы данных _data_migrations_, аналогичной стандартной в Rails таблице _schema_migrations_
* в комплекте идет набор Rake-задач:
    * `rake data:migrate`
    * `rake data:rollback`
    * `rake data:migrate:down`
    * `rake data:migrate:up`
* можно накатить только миграции данных отдельно командой `rake data:migrate`
* ~60 звезд на GitHub, ~20k скачиваний на RubyGems

Для работы _gem_'а надо сгенерировать миграцию с созданием таблицы _data_migrations_:

```
$ rails generate data_migrations:install
      create  db/migrate/20220213202651_create_data_migrations.rb
```

Новая миграция:

```ruby
class CreateDataMigrations < ActiveRecord::Migration[7.0]
  def self.up
    create_table :data_migrations, id: false do |t|
      t.string :version
    end
  end

  def self.down
    drop_table :data_migrations
  end
end
```

Далее сгенерируем миграцию данных для таблицы _users_:

```
$ rails generate data_migration MigrateUserFullNames
      create  db/data_migrate/20220213202952_migrate_user_full_names.rb
```

Получился вот такой файл:

```ruby
class MigrateUserFullNames < ActiveRecord::Migration[7.0]
  def change
  end
end
```

Добавим SQL-запрос:

```ruby
class MigrateUserFullNames < ActiveRecord::Migration[7.0]
  def change
    execute <<~SQL
      update users set full_name = 'John Doe'
    SQL
  end
end
```

И запустим миграцию:

```
$ bundle exec rake data:migrate
== 20220213202952 MigrateUserFullNames: migrating =============================
-- execute("update users set full_name = 'John Doe'\n")
   -> 0.0017s
== 20220213202952 MigrateUserFullNames: migrated (0.0018s) ====================
```

Как видим, все работает. Правильно и просто. Пользоваться можно.



### Выводы


Как видим, нам предлагают всего два подхода - копия механизма миграций
Rails и его вариация с Rake-задачами. Не густо, скажу я вам. Выделяются
два _gem_'а - _data-migrate_, так как к нему прилагается неприлично
большой набор Rake-задач и на GitHub стоит много звезд, и _after_party_ -
оригинальностью подхода с Rake-задачами. Остальные _gem_'ы отстают по
набору Rake-задач, поддержке и популярности.

Мне нравятся оба варианта, правда подход _after_party_ немного больше.

Но есть проблемы или недоработки в обоих реализациях. Как минимум нужна
возможность в _unit_-тесте откатить схему таблиц назад до актуальной для
миграции версии. Также в _after_party_ нельзя запустить сразу и
миграции схемы и миграции данных вперемешку, но упорядоченно по времени
создания.



[1]: https://railsguides.net/change-data-in-migrations-like-a-boss/
[2]: https://github.com/OffgridElectric/rails-data-migrations/issues/14

[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com

