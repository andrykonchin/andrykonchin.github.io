class MigrateUserFullNames < ActiveRecord::DataMigration
  def up
    execute <<~SQL
      update users set full_name = 'John Doe'
    SQL
  end
end
