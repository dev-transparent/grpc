# Generates the Greeter service from its .proto file at compile time, without
# protoc or a code generation step:
#
#   crystal run examples/import_proto/main.cr
require "../../src/grpc"

GRPC.import_proto "../helloworld/proto/helloworld.proto"

class Greeter < Helloworld::Greeter::Service
  def say_hello(request, context)
    Helloworld::HelloReply.new(message: "Hello #{request.name}")
  end

  def say_hello_stream(requests, responses, context)
    requests.each { |request| responses << Helloworld::HelloReply.new(message: "Hello #{request.name}") }
  end
end

server = GRPC::Server.new
server.handle(Greeter.new)
address = server.bind("127.0.0.1:0").as(Socket::IPAddress)
server.start

client = Helloworld::Greeter::Client.new("127.0.0.1:#{address.port}")
puts client.say_hello(Helloworld::HelloRequest.new(name: "import_proto")).message
client.close
server.close
