require 'rails_helper'
require 'migration_data/testing'
require_migration 'migrate_user_full_names'
#require './db/migrate/20220212205020_migrate_user_full_names'

RSpec.describe MigrateUserFullNames do
  describe '#data' do
    it 'updates full_name attribute' do
      user = User.create!(full_name: 'Robin Hood')

      described_class.new.data

      expect(user.reload.full_name).to eq('John Doe')
    end
  end
end
