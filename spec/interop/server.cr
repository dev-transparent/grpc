# gRPC interop test server implementing grpc.testing.TestService as described
# in https://github.com/grpc/grpc/blob/master/doc/interop-test-descriptions.md
#
#   crystal run spec/interop/server.cr -- --port=10000
require "option_parser"
require "./service"

port = 10000
host = "127.0.0.1"
use_tls = false
certs = File.join(__DIR__, "certs")
cert = File.join(certs, "server1.pem")
key = File.join(certs, "server1.key")
OptionParser.parse do |parser|
  parser.on("--port=PORT", "Port to listen on") { |value| port = value.to_i }
  parser.on("--host=HOST", "Host to bind") { |value| host = value }
  parser.on("--use_tls=BOOL", "Serve over TLS (with the gRPC test certificates by default)") { |value| use_tls = value == "true" }
  parser.on("--tls_cert=PATH", "Server certificate chain") { |value| cert = value }
  parser.on("--tls_key=PATH", "Server private key") { |value| key = value }
  parser.on("--threads=N", "Worker threads (requires -Dpreview_mt -Dexecution_context)") do |value|
    {% if flag?(:execution_context) %}
      Fiber::ExecutionContext.default.resize(value.to_i)
    {% else %}
      abort "--threads requires building with -Dpreview_mt -Dexecution_context"
    {% end %}
  end
end

server = GRPC::Server.new
server.handle(Interop::TestServiceImpl.new)
address = if use_tls
            context = OpenSSL::SSL::Context::Server.new
            context.certificate_chain = cert
            context.private_key = key
            server.bind_tls(host, port, context)
          else
            server.bind_tcp(host, port)
          end
STDOUT.puts "Interop server listening on #{address}"
STDOUT.flush
server.listen
