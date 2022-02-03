class MigrateUserFullNames < ActiveRecord::Migration[7.0]
  # def change
  # end

  def data
    execute <<~SQL
      update users set full_name = 'John Doe'
    SQL
  end
end
