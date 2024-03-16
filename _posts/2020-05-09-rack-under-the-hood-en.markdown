---
layout:     post
title:      Rack under the hood
date:       2020-05-09 00:01
categories: Ruby
---

Let's briefly discuss Rack. It's a crucial part of the Ruby web stack,
serving as the standard interface between web servers and web
applications. Ruby web servers like Puma, Unicorn, and Thin utilize the
Rack interface to send HTTP requests to web applications and receive
responses. Typically, web applications are not involved in this process.
Frameworks like Rails, Sinatra, or Grape take care of everything
smoothly.

If Rack is merely a specification, a contract between a web server and
an application, then why is the `rack` _gem_ necessary? What function
does it serve, and why is it listed as a dependency for web servers and
frameworks? Let's delve into this. But first, let's cover some basics.

### Content
{:.no_toc}

* A markdown unordered list which will be replaced with the ToC, excluding the "Contents header" from above
{:toc}


### Rack specification

The Rack interface is relatively straightforward. An application is
essentially an object with a `#call` method. It takes an HTTP request as
an argument and returns an HTTP response. The web server forwards
requests to an application in the form of a `Hash`, referred to as
`env`. The response comprises an `Array` with three components: the HTTP
status (e.g., 200 or 500), headers, and the response body. Headers
consist of key-value pairs, while the body comprises Strings, allowing
it to be streamed to a client incrementally.

The full specification can be found
[here](https://github.com/rack/rack/blob/2-2-stable/SPEC.rdoc).


#### Example of application

Let's create a simple Rack application.

We will create a `config.ru` file - it's a starting point for every Rack
application. The name can be chosen freely, but usually, the web server
expects to find this file by default. Let's define our application as a
_lambda_. It provides a `#call` method like any instance of `Proc`,
making it suitable for our requirements:


```ruby
app = lambda do |env|
  [200, { 'Content-Type' => 'text/plain' }, ['Hello']]
end

run app
```

This application on every request returns status 200, string 'Hello' and
header 'Content-Type'. Launching this application in the terminal is
straightforward; simply use the `rackup` command included with the
`rack` _gem_:

```
$ rackup --port 5000
```

When you make the following HTTP request in the terminal using the curl
command, the application unsurprisingly returns "Hello" in response:

```
$ curl http://0.0.0.0:5000/foo/bar\?q\=qwerty -d 'Hi'
Hello
```

Let's explore the HTTP request object that the web server hands over to
the web application:

```ruby
{
  "rack.version"=>[1, 3],
  "rack.errors"=>"#<Rack::Lint::ErrorWrapper:0x00007fc0e2166a98>",
  "rack.multithread"=>true,
  "rack.multiprocess"=>false,
  "rack.run_once"=>false,
  "SCRIPT_NAME"=>"",
  "QUERY_STRING"=>"q=qwerty",
  "SERVER_PROTOCOL"=>"HTTP/1.1",
  "SERVER_SOFTWARE"=>"puma 4.3.3 Mysterious Traveller",
  "GATEWAY_INTERFACE"=>"CGI/1.2",
  "REQUEST_METHOD"=>"POST",
  "REQUEST_PATH"=>"/foo/bar",
  "REQUEST_URI"=>"/foo/bar?q=qwerty",
  "HTTP_VERSION"=>"HTTP/1.1",
  "HTTP_HOST"=>"0.0.0.0:5000",
  "HTTP_USER_AGENT"=>"curl/7.54.0",
  "HTTP_ACCEPT"=>"*/*",
  "CONTENT_LENGTH"=>19,
  "CONTENT_TYPE"=>"application/x-www-form-urlencoded",
  "SERVER_NAME"=>"0.0.0.0",
  "SERVER_PORT"=>5000,
  "PATH_INFO"=>"/foo/bar",
  "REMOTE_ADDR"=>"127.0.0.1",
  "rack.hijack?"=>true,
  "rack.hijack"=>
   "#<Proc:0x00007fc0e2166c78 .../ruby/gems/2.7.0/gems/rack-2.2.2/lib/rack/lint.rb:567>",
  "rack.input"=>"#<Rack::Lint::InputWrapper:0x00007fc0e2166ae8>",
  "rack.url_scheme"=>"http",
  "rack.after_reply"=>[],
  "rack.tempfiles"=>[]
}
```

The HTTP-request object includes several parameter groups:
* meta-parameters
* headers
* auxiliary parameters

Meta-parameters comprise HTTP protocol version, method (POST, GET, etc),
path and query-parameters within the URL:

key                  | value
---------------------|--------------------------------------
`"HTTP_VERSION"`     | `"HTTP/1.1"`
`"SCRIPT_NAME"`      | `""`
`"QUERY_STRING"`     | `"q=qwerty"`
`"SERVER_PROTOCOL"`  | `"HTTP/1.1"`
`"SERVER_SOFTWARE"`  | `"puma 4.3.3 Mysterious Traveller"`
`"GATEWAY_INTERFACE"`| `"CGI/1.2"`
`"REQUEST_METHOD"`   | `"POST"`
`"REQUEST_PATH"`     | `"/foo/bar"`
`"REQUEST_URI"`      | `"/foo/bar?q=qwerty"`
`"SERVER_NAME"`      | `"0.0.0.0"`
`"SERVER_PORT"`      | `9292`
`"PATH_INFO"`        | `"/foo/bar"`
`"REMOTE_ADDR"`      | `"127.0.0.1"`
`"CONTENT_LENGTH"`   | `19`
`"CONTENT_TYPE"`     | `"application/x-www-form-urlencoded"`

The names of HTTP headers are prefixed with `HTTP_`. Although we didn't
explicitly specify these headers, curl has added them automatically:

key                  | value
---------------------|------------------
`"HTTP_HOST"`        | `"0.0.0.0:9292"`
`"HTTP_USER_AGENT"`  | `"curl/7.54.0"`
`"HTTP_ACCEPT"`      | `"*/*"`

You may have noted that `CONTENT_LENGTH` and `CONTENT_TYPE` headers are
handled as meta-parameters rather than HTTP headers (prefixed with
`HTTP_`). This may seem odd, but it's consistent with the CGI standard
detailed in [RFC 3875](https://tools.ietf.org/html/rfc3875#section-4.1).

The prefix `rack.` is added to auxiliary parameters:

key                  | value
---------------------|--------------------------------------------------
`"rack.version"`     | `[1, 3]`
`"rack.errors"`      | `"#<Rack::Lint::ErrorWrapper:0x00007fc0e2166a98>"`
`"rack.multithread"` | `true`
`"rack.multiprocess"`| `false`
`"rack.run_once"`    | `false`
`"rack.hijack?"`     | `true`
`"rack.hijack"`      | `"#<Proc:0x00007fc0e2166c78 .../ruby/gems/2.7.0/gems/rack-2.2.2/lib/rack/lint.rb:567>"`
`"rack.input"`       | `"#<Rack::Lint::InputWrapper:0x00007fc0e2166ae8>"`
`"rack.url_scheme"`  | `"http"`
`"rack.after_reply"` | `[]`

For instance `rack.input` is a request body. `rack.hijack?` and
`rack.hijack` parameters are associated with a unique feature known as
_socket hijacking_, wherein an application can interact with a socket
directly for read and write operations. This way applications may use
different communication protocols, e.g. websockets. Further elaboration
on this topic can be found
[here](https://github.com/rack/rack/blob/2-2-stable/SPEC.rdoc#label-Hijacking).


#### Interfaces in the specification

I bet you have noticed a subtle nuance. The request body is not simply a
`String` or an `Array`; rather, it is an instance of a peculiar class
`Rack::Lint::InputWrapper`. In fact, the Rack specification does not
mandate the use of any specific data structure such as an `Array` or
`Hash`. Instead, it outlines an interface that an object must adhere to
and specifies the methods it should support. For example, the request
body must behave like an `IO` object and must offer methods `#gets`,
`#each`, `#read` and `#rewind`. It could be, for instance, `StringIO` or
`File`. Or any arbitrary class that implements these methods.

The specification has the following requirements:
* response status should have a `#to_i` method that returns a numeric value,
such as 200 or 500
* response headers aren't obliged to be a `Hash`; the object must simply support the `#each` method to iterate through key-value pairs.
* the response body isn't obliged to be an `Array`; instead, this object should offer an
`#each` method to iterate through a collection of `String` body parts;
additionally, it may optionally provide `#to_path` and `#close` methods.


### rack gem

Turning our focus to the `rack` gem, Leah Neukirchen, one of its
authors, explains in her article [Introducing
Rack](http://leahneukirchen.org/blog/archive/2007/02/introducing-rack.html)
that Rack serves as both a specification and a solution for addressing
typical challenges in web applications by offering a means to integrate
them seamlessly.

Upon examining the gem's [source
code](https://github.com/rack/rack/tree/2-2-stable/lib/rack), we can
categorize the files into distinct groups, although this classification
does not align with the existing directory structure:

* middlewares
* web server and framework utilities
* tools for creating new middlewares


#### Middlewares

Rack's approach to solve common issues is to use already existing
components to handle requests. These components (filters or middlewares)
form a chain and process incoming requests one by one before passing it
to a web application. A middleware should implement a standardized
interface. It's also a way to reuse common logic in different
applications even using different frameworks and web servers.

Now, let's examine a straightforward middleware that undertakes no
action but simply invokes the subsequent middleware (`app`) in the
sequence:

```ruby
class SimpleMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    # analize request
    status, headers, body = @app.call(env)
    # analize response

    [status, headers, body]
  end
end
```

The `rack` gem provides a multitude of diverse middlewares. Here are a
few noteworthy examples:
* Rack::CommonLogger: logs all incoming requests in the Apache web
  server logs format.
* ConditionalGet: examines `If-None-Match` and `If-Modified-Since`
  headers, delivering a 304 status code without a body if it detects that
  the browser has already cached the current version of a document.
* ContentLength: sets the `Content-Length` response header if not done
  by the application.
* Directory: facilitates file browsing for a specific server directory,
  enabling users to browse directories and view file contents.
* ETag: computes the checksum of the response body using SHA256 and sets
  the `ETag` header.
* Lock: prevents parallel processing of concurrent requests, ensuring
  they are handled sequentially. This can be particularly beneficial when
  executing thread-unsafe applications on multi-threaded web servers like
  Puma.

Organizing components as a chain of middlewares is a prevalent and
widely adopted approach. For example, Rails features its own middleware
chain comprising [a range of
middlewares](https://github.com/rails/rails/tree/master/actionpack/lib/action_dispatch/middleware)
that adhere to the Rack specification. Additionally, Rails leverages
select middlewares from the `rack` gem:
* Rack::Sendfile
* Rack::Cache
* Rack::Lock
* Rack::Runtime
* Rack::MethodOverride
* Rack::Head
* Rack::ConditionalGet
* Rack::ETag
* Rack::TempfileReaper

Popular middlewares are offered as individual gems:
* `warden`
* `rack-timeout`
* `rack-attack`
* `rack-reverse-proxy`
* `rack-cors`


#### Integration with web servers and frameworks

Moving forward to the next category - utilities tailored for web servers and frameworks.

__Warning__: in Rack 3.0, all rackup-related functionality has been migrated to a separate gem named `rackup`.


##### Rack::Server
<https://github.com/rack/rack/blob/2-2-stable/lib/rack/server.rb>

Ever wondered about the mechanism behind the `rackup` command's
initiation of web applications? Its primary function is to launch a web
server. Although the long-standing WEBrick web server has been a default
Ruby gem, it lacks support for Rack.

For this specific function, the `rack` gem includes a handy class called
`Rack::Server`, which is utilized to launch web applications on servers
such as Webrick. Notably, the `rackup` command makes use of this class
under the hood
([source](https://github.com/rack/rack/blob/2-2-stable/bin/rackup)):

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require "rack"
Rack::Server.start
```

`Rack::Server` supports numerous command line options that were
specified for `rackup` command, e.g. `--daemonize` for running a web
server in the background. Users can also specify `--port` and `--host`
to launch a web server on a designated port and host. Furthermore, users
have the flexibility to specify the web server name to be used with the
`--server` option.

It is also possible to manually launch the web server. By default,
`Rack::Server` searches for a `config.ru` file to load an application
(with the path and filename specifiable using the `:config` parameter).
Alternatively, the application object can be directly specified using
the `:app` parameter, as demonstrated in the
[documentation](https://www.rubydoc.info/gems/rack/Rack/Server).

```ruby
Rack::Server.start(
  :app => lambda do |e|
    [200, {'Content-Type' => 'text/html'}, ['hello world']]
  end
)
```

Moreover, `Rack::Server` can serve as a tool for debugging specific
middlewares, such as `Rack::ShowExceptions`, using an application stub:

```ruby
require 'rack'

app = lambda do |e|
  [200, {'Content-Type' => 'text/html'}, ['hello world']]
end

Rack::Server.start(
  app: Rack::ShowExceptions.new(app), Port: 9292
)
```

It is noteworthy that the Rails command `rails server` employs
`Rack::Server` as well
([source](https://github.com/rails/rails/blob/6-0-stable/railties/lib/rails/commands/server/server_command.rb))


##### Rask::Handler
<https://github.com/rack/rack/blob/2-2-stable/lib/rack/handler.rb>

As previously mentioned, `Rack::Server` can launch various web servers.
To facilitate this, there exists an adapter (or handler) responsible for
supporting a particular web server. Adapters initialize and launch the
web server by configuring settings and specifying the application:

```ruby
Rack::Server.start(app: app, server: :puma)
```

Out of the box, users have access to a set of adapters:
* [CGI](https://github.com/rack/rack/blob/2-2-stable/lib/rack/handler/cgi.rb)
* [FastCGI](https://github.com/rack/rack/blob/2-2-stable/lib/rack/handler/fastcgi.rb)
* [SCGI](https://github.com/rack/rack/blob/2-2-stable/lib/rack/handler/scgi.rb)
* [Thin](https://github.com/rack/rack/blob/2-2-stable/lib/rack/handler/thin.rb)
* [Webrick](https://github.com/rack/rack/blob/2-2-stable/lib/rack/handler/webrick.rb)
* [LiteSpeed Web Server](https://github.com/rack/rack/blob/2-2-stable/lib/rack/handler/lsws.rb)

While there are additional adapters for different web servers available in separate gems:
* [Puma](https://github.com/puma/puma/blob/master/lib/rack/handler/puma.rb)
* [Phusion Passenger](https://github.com/phusion/passenger/blob/stable-6.0/src/ruby_supportlib/phusion_passenger/rack_handler.rb)
* [Falcon](https://github.com/socketry/falcon/blob/master/lib/rack/handler/falcon.rb)
* [iodine](https://github.com/boazsegev/iodine/blob/master/lib/rack/handler/iodine.rb)
* [Unicorn](https://github.com/samuelkadolph/unicorn-rails/blob/master/lib/unicorn_rails.rb)
* and other [Unicorn-like web servers](https://github.com/godfat/rack-handlers/tree/master/lib/rack/handler).

Users have the option to directly launch a web server using an adapter
without the need for `Rack::Server`:

```ruby
require 'rack'

app = lambda do |e|
  [200, {'Content-Type' => 'text/html'}, ['hello world']]
end

Rack::Handler::Thin.run app
```


##### Rack::Builder
<https://github.com/rack/rack/blob/2-2-stable/lib/rack/builder.rb>

Certainly, looking at the examples of `config.ru` file you were wondering
that it is a method `run app`:

```ruby
app = lambda do |env|
  [200, { 'Content-Type' => 'text/plain' }, ['Hello']]
end

run app
```

Clearly, `#run` does not belong to the standard methods of the `Object`
class, given its role in launching a web application. In actuality, the
`#run` method comes from the `Rack::Builder` class, and the `config.ru`
file is executed within the context of an instance of the
`Rack::Builder` class.

`Rack::Builder` facilitates construction of a Rack application by
integrating its components - namely, the web application and
middlewares. The following methods are available:

__#use__

Adds one more middleware into a chain. This new middleware will handle
each HTTP request before being passed on to the main application for
further processing.

```ruby
use Rack::ShowExceptions
run lambda { |env| [200, { "Content-Type" => "text/plain" }, ["OK"]] }
```

__#run__

One of the key methods that allows you to set the web application:

```ruby
run lambda { |env| [200, { "Content-Type" => "text/plain" }, ["OK"]] }
```

__#map__


This functionality can be considered as a custom router. By defining a
path along with a Rack application, all HTTP requests associated with
that specific path will be directed and handled by the specified
application.

```ruby
Rack::Builder.app do
  map '/heartbeat' do
    run Heartbeat
  end
  run App
end
```

The nested application can establish its own middleware chain, which is
configured using the `#use` method.

__#warmup__

This setup allows the application to undergo a warm-up phase before it
begins processing incoming requests.

```ruby
warmup do |app|
  client = Rack::MockRequest.new(app)
  client.get('/')
end
```

__#freeze_app__

Freezes (calls the `#freeze` method) an application and all the
middlewares in a chain, preventing any further modifications.

```ruby
freeze_app
```

You can utilize `Rack::Builder` directly in a `config.ru` file, for
example, in the following manner:

```ruby
app = Rack::Builder.app do
  use Rack::CommonLogger
  run lambda { |env| [200, {'Content-Type' => 'text/plain'}, ['OK']] }
end

run app
```

However, it seems that `Rack::Builder` is primarily beneficial for
smaller Rack applications that do not rely on a framework. In contrast,
Rails requires more robust functionality and employs its own builder,
`ActionDispatch::MiddlewareStack`
([source](https://github.com/rails/rails/blob/master/actionpack/lib/action_dispatch/middleware/stack.rb)).

Next, let's examine how a `config.ru` file is loaded. Prior to Rack
v2.2, the following approach was used
([source](https://github.com/rack/rack/blob/2-1-stable/lib/rack/builder.rb#L64-L67)):

```ruby
def self.new_from_string(builder_script, file = "(rackup)")
  eval "Rack::Builder.new {\n" + builder_script + "\n}.to_app",
    TOPLEVEL_BINDING, file, 0
end
```

Now, the process operates this way
([source](https://github.com/rack/rack/blob/2-2-stable/lib/rack/builder.rb#L110-L118)):

```ruby
# Evaluate the given +builder_script+ string in the context of
# a Rack::Builder block, returning a Rack application.
def self.new_from_string(builder_script, file = "(rackup)")
  # We want to build a variant of TOPLEVEL_BINDING with self as
  # a Rack::Builder instance.
  # We cannot use instance_eval(String) as that would resolve constants
  # differently.

  binding, builder = TOPLEVEL_BINDING.eval(
    'Rack::Builder.new.instance_eval { [binding, self] }'
  )
  eval builder_script, binding, file
  builder.to_app
end
```

`Rack::Builder` is meant to be used by web servers, primarily for
loading a `config.ru` file.

As an example, Unicorn takes care of loading the `config.ru` file
independently and executes `Rack::Builder.new` to establish the
application.
([source](https://github.com/defunkt/unicorn/blob/5.4-stable/lib/unicorn.rb#L56)):

```ruby
eval("Rack::Builder.new {(\n#{raw}\n)}.to_app", TOPLEVEL_BINDING, ru)
```

Puma makes use of the helper method `Rack::Builder.parse_file`, which
was added to the `rack` library many years ago
([source](https://github.com/puma/puma/blob/4.3.3/lib/puma/configuration.rb#L321)):

```ruby
rack_app, rack_options = rack_builder.parse_file(rackup)
```

It remains uncertain why this is the case, but Puma has its own
simplified version of `Rack::Builder`
([source](https://github.com/puma/puma/blob/4.3.3/lib/puma/rack/builder.rb#L129-L300)).
that comes into play if it encounters an issue while trying to require
the original source file containing the `Rack::Builder` implementation
([source](https://github.com/puma/puma/blob/4.3.3/lib/puma/configuration.rb#L295-L316)).


#### Developing a middleware

Additionally, the `rack` gem comes with various helper classes that
facilitate the development and testing of new middlewares. Let's take a
brief look at them.


##### Rack::Request
<https://github.com/rack/rack/blob/2-2-stable/lib/rack/request.rb>

This is the well-known Rails _request_ object. `Rack::Request` provides
a thin layer over the incoming `env` hash, enabling data access through
various getter methods. It also offers some useful predicate methods.

For example, the following HTTP request:

```
curl http://0.0.0.0:5000/foo/bar\?q\=qwerty -d 'Hi'
```

is represented as:

```ruby
request = Rack::Request.new(env)

request.body            # => #<Rack::Lint::InputWrapper:0x00007ffa193313d0>
request.body.read       # => Hi
request.path            # => /foo/bar
request.request_method  # => POST
request.query_string    # => q=qwerty
request.content_length  # => 2
request.user_agent      # => curl/7.54.0
request.scheme          # => http
request.host            # => 0.0.0.0
request.post?           # => true
request.get?            # => false
request.GET             # => {"q"=>"qwerty"}
request.POST            # => {"Hi"=>nil}
request.params          # => {"q"=>"qwerty", "Hi"=>nil}
```

Additionally, it parses the following:
* _Query_ string,
* POST-parameters
* _Multipart_ request body
* _Cookies_
* `Accept-Encoding` and `Accept-Language` headers.

`Rack::Request` also processes `X_FORWARDED_*` headers while employing
sophisticated logic to deduce the client's IP address.


##### Rack::Response
<https://github.com/rack/rack/blob/2-2-stable/lib/rack/response.rb>


`Rack::Response` assists in constructing an HTTP response, allowing you
to set headers and the body in a user-friendly manner. There are also
setter methods available for modifying specific headers

Let's consider this example:

```ruby
response = Rack::Response.new(['Hello'], 200, {})
response.content_type = 'text/plain'
response.etag = 'v58.1.0'
response.set_header('Expires', 'Wed, 21 Oct 2015 07:28:00 GMT')
response.set_header('Age', '24')
response.set_cookie('id', '56817838490203423')
response.finish # => [status, headers, body]
```

where we build the following HTTP response:

```
HTTP/1.1 200 OK
Content-Type: text/plain
ETag: v58.1.0
Expires: Wed, 21 Oct 2015 07:28:00 GMT
Age: 24
Set-Cookie: id=56817838490203423
Content-Length: 5

Hello
```

Additionally, it's possible to create a "redirect":

```ruby
response = Rack::Response.new
response.redirect('https://wikipedia.org/wiki/CGI')
response.finish # => [status, headers, body]
```

which automatically sets the response status to 302 and includes a
`Location` header:

```
HTTP/1.1 302 Found
Location: https://wikipedia.org/wiki/CGI
Content-Length: 0
```

Out of the box, Rack provides support for streaming, enabling the
generation of response body fragments on the fly when the final length
of the body cannot be determined beforehand. The `Rack::Response` class
provides a `#finish` method that takes an optional block argument. You
can use the `#write` method to send extra response body fragments to the
client.

In the example below, the application returns a response with the
`Transfer-Encoding: chunked` header. This header is set automatically if
the response body isn't specified when the `#finish` method is invoked.
Web servers must also support streaming and refrain from buffering
response body fragments; Puma is one such web server.

In this example, we send multiple strings in a special _chunked_ format,
with a pause of 1 second between each fragment:

```ruby
response = Rack::Response.new

response.finish do |r|
  (1..10).each do |i|
    message = "line ##{i}"
    size = message.size.to_s(16)

    r.write("#{size}\r\n")
    r.write("#{message}\r\n")

    sleep 1
  end

  r.write("0\r\n")
  r.write("\r\n")
end
```

To run Puma, use the following command (as streaming didn't work for me
using rackup for some reason):

```
$ puma --port 5000 config.ru
```

By default, _curl_ buffers response fragments and displays them all at
once after the entire response has been received. To avoid this and
ensure that each fragment is printed immediately, you need to use the
`--no-buffer` option:

```
$ curl --no-buffer http://0.0.0.0:5000
7
line #1
7
line #2
7
line #3
7
line #4
7
line #5
7
line #6
7
line #7
7
line #8
7
line #9
8
line #10
0
```

Each string is printed with a 1-second delay.


##### Rack::BodyProxy
<https://github.com/rack/rack/blob/2-2-stable/lib/rack/body_proxy.rb>


It's a simple decorator for the response body, allowing you to set a callback to be executed after the response body is sent. This can be useful, for example, to release a `Rack::Lock` lock
([source](https://github.com/rack/rack/blob/v2.2.2/lib/rack/lock.rb#L19)):

```ruby
returned = response << BodyProxy.new(response.pop) { unlock }
```

or to log request in `Rack::CommonLogger`
([source](https://github.com/rack/rack/blob/v2.2.2/lib/rack/common_logger.rb#L40)):

```ruby
body = BodyProxy.new(body) { log(env, status, headers, began_at) }
```

Typically, this feature is used to close the original response body when
it has been replaced by another object, which is a requirement of the
specification.

```ruby
body = Rack::BodyProxy.new(new_body) do
  original_body.close if original_body.respond_to?(:close)
end
```


##### Rack::Utils::HeaderHash
<https://github.com/rack/rack/blob/v2.2.2/lib/rack/utils.rb#L413-L497>

`Rack::Utils::HeaderHash` is a case-insensitive `Hash`. While it is
designated as a private API, it can still prove useful when developing
middlewares.

According to HTTP standards, header names are case insensitive. Thus, it
is entirely valid for an application to return something like
`content-type` or `CONTENT-TYPE` in a response instead of the canonical
`Content-Type`. It's easy to overlook this detail and expect header
names to be in camel case format. `Rack::Utils::HeaderHash` effectively
addresses this issue, allowing you to disregard case sensitivity when
storing response headers.

```ruby
headers = Rack::Utils::HeaderHash.new(
  "content-type" => "application.json", "Etag" => "v1"
)
headers # => {"content-type"=>"application.json", "Etag"=>"v1"}

headers["content-type"] # => "application.json"
headers["CONTENT-TYPE"] # => "application.json"

headers["content-TYPE"] = "application/xml"
headers["content-type"] # => "application/xml"
```

Additionally, the Rack specification requires that headers implement an
`#each` method, so you cannot assume that headers will behave like a
standard Hash. `Rack::Utils::HeaderHash` offers several methods akin to
those of a Hash, including `#[]`, `#[]=`, `#key?`, `#has_key?`,
`#include?`, and others.

Another feature of `Rack::Utils::HeaderHash` is its ability to handle
multiple values for the same header (for example, `Set-Cookie`).
Multiple values can be represented as a single string with each value
separated by a newline character, and web servers will parse it
accordingly to form a proper response.

Lastly, it allows for setting multiple header values by accepting an
array of values:

```ruby
h = Rack::Utils::HeaderHash[{}]
h['Set-Cookes'] = ['a', 'b']

h.to_hash # => {"Set-Cookes"=>"a\nb"}
```


##### Rack::Lint
<https://github.com/rack/rack/blob/2-2-stable/lib/rack/lint.rb>


It's a middleware that validates the correctness of either an
application or another middleware, ensuring compliance with the Rack
specification. This functionality is particularly useful in unit tests
for middlewares.

`Rack::Lint` performs the following checks for a request (`env` object):
* It must be an instance of `Hash`
* It should not be _frozen_
* It must contain all the meta-parameters with valid values
* The `rack.input` (request body) should:
    * Implement all required methods (`#gets`, `#each`, `#read`, `#rewind`)
    * Return Strings when calling `#gets` or `#read`
    * Iterate through Strings when `#each` is called
* The `rack.error` should include the methods `#puts`, `#write`, and `#flush`

For responses, `Rack::Lint` performs the following checks:
* The response must be an Array consisting of three elements
* The status must be convertible to a numeric value using the `#to_i` method and should have a valid value (> 100)
* For headers:
    * The headers object must provide an `#each` method
    * All keys should be Strings
    * Header names must not contain the `rack.` prefix
    * Header names should comply with [RFC7230](https://tools.ietf.org/html/rfc7230), containing only printable characters and no forbidden characters ((),/:;<=>?@[]{})
    * The values should also be Strings
    * There should be no `Content-Type` and `Content-Length` headers in the response if the status is 1xx, 204, or 304
* For the response body:
    * It must provide an `#each` method
    * It should be a collection of Strings
    * The total length in bytes must equal the value of the `Content-Length` header
    * If it implements a `#to_path` method, then a file with that path must exist.


##### Rack::MockRequest
<https://github.com/rack/rack/blob/2-2-stable/lib/rack/mock.rb#L22>

Used in middlewares unit tests.

When it comes to testing middlewares, there are two primary approaches.
The first method involves employing the `#env_for` helper to create a
request (the env object) that includes all the essential parameters and
headers. You would then invoke the `#call` method of the middleware
under test and verify both the response and any modifications made to
the env object:

```ruby
env = Rack::MockRequest.env_for("/?_method=delete", method: "GET")
status, headers, body = app.call env

env["REQUEST_METHOD"].must_equal "GET"
```

The second method uses `Rack::MockRequest` to wrap the middleware
(`app`) being tested, simulating an HTTP request in the process. This
results in an instance of `Rack::MockResponse`, which holds the response
from the middleware and offers useful getters for inspecting the content
of the response:

```ruby
res = Rack::MockRequest.new(app).get("/foo")

res.must_be :ok?
res["X-ScriptName"].must_equal "/foo"
res["X-PathInfo"].must_equal ""
res.body.must_equal ""
```


#### Utilities


The gem includes the following helper classes:
* `Rack::Mime` - This class detects the MIME type (e.g., "image/png")
  based on the file extension.
* `Rack::MediaType` - It parses the `Content-Type` header, returning
  both the MIME type and any associated parameters. For example, for the
  `Content-Type` header `text/plain;charset=utf-8`, it would return the
  MIME type `text/plain` and parameters `{'charset' => 'utf-8'}`.
* `Rack::Multipart` - This class is responsible for parsing multipart
  requests.
* `Rack::QueryParser` - It parses query parameters contained in a URL
  and supports nested parameters, such as `foo[]=1&foo[]=2`.
* `Rack::RewindableInput` - This class acts as a wrapper for the
  `rack.input` object. The `rack.input` must implement a `#rewind` method
  to reset the position in the request body to its beginning.
  `Rack::RewindableInput` implements this rewind functionality by
  buffering, allowing any non-rewindable object to be transformed into a
  rewindable one.
* `Rack::Utils` - A collection of various helper methods.


#### Demo

Lastly, the gem includes a small demo application called
`Rack::Lobster`, which prints an ASCII-art representation of a lobster
([source](https://github.com/rack/rack/blob/v2.2.2/lib/rack/lobster.rb)).

To run the demo, you need to clone the gem's Git repository and execute the following command:

```shell
$ rackup example/lobster.ru
```

The result will be as follows:

<img src="/assets/images/2020-05-09-rack-under-the-hood/lobster.png" style="width: 80%; margin-left: auto; margin-right: auto;" />


### Summary


To summarize, the `rack` gem is essential for several reasons: it
contains an extensive collection of Rack middlewares, it is used to load
a `config.ru` file—the entry point of a Rack application - and it
provides tools for creating and testing new middlewares.


### Links


- <https://github.com/rack/rack/blob/2-2-stable/SPEC.rdoc>
- <https://tools.ietf.org/html/rfc3875>
- <http://leahneukirchen.org/blog/archive/2007/02/introducing-rack.html>
- <https://guides.rubyonrails.org/rails_on_rack.html>
- <https://blog.sqreen.com/fixing-a-critical-issue-a-journey-into-ruby-web-server-startup-sequences-part-two/>


[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
