application = -> (env) {
  [200, {"Content-Type" => "text/plain"}, ["Hello from Rack"]]
}

run application
