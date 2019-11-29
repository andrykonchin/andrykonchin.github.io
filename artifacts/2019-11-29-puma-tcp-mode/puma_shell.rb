require 'open3'

class PumaShell
  def self.run(env, socket)
    socket.puts "You are welcome to Puma Shell"

    loop do
      socket.write "> "
      shell_command = socket.gets.chomp

      if shell_command.empty?
        next
      end

      if ['exit', 'quit'].include? shell_command
        break
      end

      # use trick with adding ';' to force Ruby to use shell instead of passing command to the OS directly
      # it's important in error handling
      Open3.popen2e(shell_command + ';') do |stdin, stdout_and_stderr, wait_thr|
        output = stdout_and_stderr.read.chomp

        if !output.empty?
          socket.puts output
        end
      end
    end

    socket.puts "Bye!"
  end
end
