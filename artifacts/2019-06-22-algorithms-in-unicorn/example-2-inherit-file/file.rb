file = File.open('file.txt', 'w')
new_fileno = file.fileno + 100

fork do
  ENV['FILE_FD'] = new_fileno.to_s
  exec 'ruby file_child.rb', new_fileno => file
end

file.puts "Hello from file.rb"

Process.wait

puts "Bye from file.rb"
