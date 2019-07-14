class CreatePayments < ActiveRecord::Migration[5.2]
  def change
    create_table :payments do |t|
      t.references :account
      t.decimal    :amount
    end
  end
end
