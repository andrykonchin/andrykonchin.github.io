require 'rack'
require 'unicorn'

raw = File.read('config.ru')
app = -> {
  eval("Rack::Builder.new {(\n#{raw}\n)}.to_app")
}

options = {
  listeners: ['127.0.0.1:8080']
}

Unicorn::HttpServer.new(app, options).start.join
