require 'fileutils'

file = File.open('development.log', 'a')
file.puts('First line')

FileUtils.mkdir('archive')
FileUtils.mv(file.path, 'archive/development.log.1')
file.puts('Second line')

file.reopen(file.path, 'a')
file.puts('Third line')

file.close
