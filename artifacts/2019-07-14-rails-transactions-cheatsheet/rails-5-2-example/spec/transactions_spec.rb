require 'rails_helper'

# https://api.rubyonrails.org/classes/ActiveRecord/Transactions/ClassMethods.html
# https://api.rubyonrails.org/classes/ActiveRecord/Rollback.html
# https://makandracards.com/makandra/42885-nested-activerecord-transaction-pitfalls
# https://github.com/rails/rails/blob/v4.2.11.1/activerecord/lib/active_record/connection_adapters/abstract/database_statements.rb

RSpec.describe 'transactions' do

#   (0.1ms)  BEGIN
#  SQL (4.1ms)  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "KFC"]]
#   (0.3ms)  COMMIT

  it 'explicit transaction' do
    ActiveRecord::Base.transaction do
      Account.create(name: 'KFC')
    end
  end

#   (0.1ms)  BEGIN
#  SQL (0.4ms)  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "KFC"]]
#   (0.1ms)  ROLLBACK

  it 'explicit transaction with rollback' do
    ActiveRecord::Base.transaction do
      Account.create(name: 'KFC')
      raise
    end
  end

#   (0.1ms)  BEGIN
#  SQL (1.9ms)  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "KFC"]]
#   (1.0ms)  COMMIT

  it 'nested explicit transaction but joined to parent' do
    ActiveRecord::Base.transaction do
      ActiveRecord::Base.transaction do
        Account.create(name: 'KFC')
      end
    end
  end

#   (0.1ms)  BEGIN
#  SQL (1.1ms)  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "KFC"]]
#   (0.7ms)  SAVEPOINT active_record_1
#  SQL (0.3ms)  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "McDonald's"]]
#   (0.1ms)  RELEASE SAVEPOINT active_record_1
#   (0.4ms)  COMMIT

  it 'real nested explicit transaction' do
    ActiveRecord::Base.transaction do
      Account.create(name: 'KFC')

      ActiveRecord::Base.transaction(requires_new: true) do
        Account.create(name: "McDonald's")
      end
    end
  end

#   (0.1ms)  BEGIN
#  SQL (0.8ms)  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "KFC"]]
#   (0.1ms)  SAVEPOINT active_record_1
#  SQL (0.2ms)  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "McDonald's"]]
#   (0.9ms)  ROLLBACK TO SAVEPOINT active_record_1
#   (0.3ms)  ROLLBACK

  it 'real nested explicit transaction with rollback' do
    ActiveRecord::Base.transaction do
      Account.create(name: 'KFC')

      ActiveRecord::Base.transaction(requires_new: true) do
        Account.create(name: "McDonald's")
        raise
      end
    end
  end

#   (0.2ms)  BEGIN
#  SQL (1.2ms)  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "KFC"]]
#   (0.2ms)  SAVEPOINT active_record_1
#  SQL (0.2ms)  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "McDonald's"]]
#   (0.2ms)  ROLLBACK TO SAVEPOINT active_record_1
#   (0.4ms)  COMMIT

  it 'real nested explicit transaction with partial rollback' do
    ActiveRecord::Base.transaction do
      Account.create(name: 'KFC')

      begin
        ActiveRecord::Base.transaction(requires_new: true) do
          Account.create(name: "McDonald's")
          raise
        end
      rescue
      end
    end
  end

#   (0.1ms)  BEGIN
#  SQL (0.6ms)  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "KFC"]]
#   (0.3ms)  COMMIT

  it 'implicit transaction' do
    Account.create(name: 'KFC')
  end

#   (0.2ms)  BEGIN
#  SQL (0.6ms)  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "KFC"]]
#  SQL (22.1ms)  INSERT INTO "payments" ("amount", "account_id") VALUES ($1, $2) RETURNING "id"  [["amount", "10.0"], ["account_id", 1]]
#  SQL (0.2ms)  INSERT INTO "payments" ("amount", "account_id") VALUES ($1, $2) RETURNING "id"  [["amount", "13.0"], ["account_id", 1]]
#   (8.6ms)  COMMIT

  it 'missing implicit transaction' do
    Account.create(name: 'KFC', payments: [Payment.new(amount: 10), Payment.new(amount: 13)])
  end

#  (0.1ms)  BEGIN
#   (0.1ms)  SAVEPOINT active_record_1
#  SQL (0.4ms)  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "KFC"]]
#   (0.1ms)  RELEASE SAVEPOINT active_record_1
#   (0.1ms)  SAVEPOINT active_record_1
#  SQL (0.1ms)  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "McDonald's"]]
#   (0.1ms)  RELEASE SAVEPOINT active_record_1
#   (27.6ms)  COMMIT

  it 'nested implicit transaction' do
    ActiveRecord::Base.transaction(joinable: false) do
      Account.create(name: 'KFC')
      Account.create(name: "McDonald's")
    end
  end

#   (0.1ms)  BEGIN
#   (0.1ms)  SAVEPOINT active_record_1
#  Account Load (0.6ms)  SELECT  "accounts".* FROM "accounts" WHERE "accounts"."name" = $1 LIMIT $2  [["name", "KFC"], ["LIMIT", 1]]
#   (0.2ms)  RELEASE SAVEPOINT active_record_1
#   (0.2ms)  COMMIT

  it 'deeply nested transactions' do
    ActiveRecord::Base.transaction(joinable: false) do
      ActiveRecord::Base.transaction do
        Account.find_by(name: 'KFC')
      end
    end
  end

#   (0.1ms)  BEGIN
#   (0.1ms)  SAVEPOINT active_record_1
#  Account Load (0.4ms)  SELECT  "accounts".* FROM "accounts" WHERE "accounts"."name" = $1 LIMIT $2  [["name", "KFC"], ["LIMIT", 1]]
#   (0.1ms)  RELEASE SAVEPOINT active_record_1
#   (0.1ms)  COMMIT

  it 'even more deeply nested transactions' do
    ActiveRecord::Base.transaction(joinable: false) do
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.transaction do
          Account.find_by(name: 'KFC')
        end
      end
    end
  end

#   (0.1ms)  BEGIN
#  SQL (0.3ms)  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "KFC"]]
#  SQL (0.1ms)  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "McDonald's"]]
#   (0.3ms)  COMMIT

  it 'nested explicit transaction and rollback' do
    ActiveRecord::Base.transaction do
      Account.create(name: 'KFC')

      ActiveRecord::Base.transaction do
        Account.create(name: "McDonald's")

        raise ActiveRecord::Rollback
      end
    end
  end

#   (0.2ms)  BEGIN
#  SQL (1.3ms)  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "KFC"]]
#   (0.2ms)  SAVEPOINT active_record_1
#  SQL (0.4ms)  INSERT INTO "accounts" ("name") VALUES ($1) RETURNING "id"  [["name", "McDonald's"]]
#   (0.5ms)  ROLLBACK TO SAVEPOINT active_record_1
#   (0.8ms)  COMMIT

  it 'real nested explicit transaction and rollback' do
    ActiveRecord::Base.transaction do
      Account.create(name: 'KFC')

      ActiveRecord::Base.transaction(requires_new: true) do
        Account.create(name: "McDonald's")

        raise ActiveRecord::Rollback
      end
    end
  end
end
