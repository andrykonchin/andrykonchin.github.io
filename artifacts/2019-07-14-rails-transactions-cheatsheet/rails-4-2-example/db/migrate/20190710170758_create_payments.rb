class CreatePayments < ActiveRecord::Migration
  def change
    create_table :payments do |t|
      t.references :account
      t.decimal    :amount
    end
  end
end
