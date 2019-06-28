require 'socket'

fileno = Integer(ENV['SOCKET_ID'])
server = TCPServer.for_fd(fileno)

loop do
  client = server.accept
  client.puts "Hello from server child #{$$}!"
  client.close
end
