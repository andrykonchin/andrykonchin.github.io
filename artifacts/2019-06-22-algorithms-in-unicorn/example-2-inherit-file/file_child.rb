raise if ENV['FILE_FD'].nil?

fileno = Integer(ENV['FILE_FD'])
file = File.for_fd(fileno)

file.puts "Hello from file_child.rb"
file.close

puts "Bye from file_child.rb"
