main_thread = Thread.current

Thread.new do
  loop do
    sleep 0.1
    main_thread.raise 'Timout error'
  end
end

(1..1000).each do |i|
  User.where(id: 1).limit(i).to_a
rescue ActiveRecord::StatementInvalid => e
  puts e
  break
rescue
  next
end
