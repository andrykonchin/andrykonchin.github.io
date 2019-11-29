require_relative 'puma_shell'

tcp_mode

bind 'tcp://127.0.0.1:9292'

threads 2, 10

app do |env, socket|
  PumaShell.run(env, socket)
end
