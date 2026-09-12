@read_io, @write_io = IO.pipe

# write into pipe some data
def run_specs
  packet = '*' * 1000
  @write_io.write("#{packet.bytesize}\n#{packet}")
end

# create a child process
pid = fork { run_specs }

# wait for it terminating
Process.waitpid(pid)

# read result
packet_size = Integer(@read_io.gets)
packet = @read_io.read(packet_size)

puts "packet size: #{packet.size}"
