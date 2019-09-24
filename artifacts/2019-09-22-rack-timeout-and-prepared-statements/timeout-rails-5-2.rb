main_thread = Thread.current

Thread.new do
  loop do
    sleep 0.1
    main_thread.raise 'Timout error'
  end
end

(1..10000).each do |i|
  Account.where(id: [1]*i).to_a
rescue ActiveRecord::StatementInvalid => e
  puts e
  break
rescue
  puts $!
  next
end
