namespace :after_party do
  desc 'Deployment task: update_user_full_names'
  task update_user_full_names: :environment do
    puts "Running deploy task 'update_user_full_names'"

    ActiveRecord::Base.connection.update("update users set full_name = 'John Doe'")

    # Update task as completed.  If you remove the line below, the task will
    # run with every deploy (or every time you call after_party:run).
    AfterParty::TaskRecord
      .create version: AfterParty::TaskRecorder.new(__FILE__).timestamp
  end
end
