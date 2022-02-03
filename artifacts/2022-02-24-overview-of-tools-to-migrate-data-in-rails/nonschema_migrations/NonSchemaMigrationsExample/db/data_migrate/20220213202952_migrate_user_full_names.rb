class MigrateUserFullNames < ActiveRecord::Migration[7.0]
  def up
    execute <<~SQL
      update users set full_name = 'John Doe'
    SQL
  end

  def down

  end
end
