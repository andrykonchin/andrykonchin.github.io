RSpec.configure do |config|
  config.before :each do
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.clean
  end
end

