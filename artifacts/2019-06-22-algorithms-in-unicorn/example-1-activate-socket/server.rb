require 'socket'

server = TCPServer.new 2000

fork do
  ENV['SOCKET_ID'] = server.fileno.to_s
  exec 'ruby server_child.rb', server.fileno => server
end

loop do
  client = server.accept
  client.puts "Hello from server #{$$}!"
  client.close
end
