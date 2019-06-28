require 'socket'

loop do
  s = TCPSocket.new 'localhost', 2000
  line = s.gets
  puts line
  s.close

  sleep 1
end
