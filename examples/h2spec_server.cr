# HTTP/2 server used to run the h2spec conformance suite:
#
#   crystal run examples/h2spec_server.cr -- 8080
#   h2spec -p 8080
require "../src/http2"

port = (ARGV[0]? || "8080").to_i
body = "Hello, World!\n" * 2048

server = HTTP2::Server.new do |context|
  # Consume the request body before responding, as a typical application
  # would, so request-side flow control and stream states are exercised.
  context.request.body.skip_to_end
  context.response.headers["content-type"] = "text/plain"
  context.response.print body unless context.request.method == "HEAD"
end

address = server.bind_tcp("127.0.0.1", port)
puts "Listening on http://#{address}"
server.listen
