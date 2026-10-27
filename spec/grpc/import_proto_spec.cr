require "./grpc_helper"

GRPC.import_proto "../../examples/helloworld/proto/helloworld.proto"

private class MacroGreeter < Helloworld::Greeter::Service
  def say_hello(request, context)
    Helloworld::HelloReply.new(message: "Hello #{request.name}")
  end

  def say_hello_stream(requests, responses, context)
    requests.each { |request| responses << Helloworld::HelloReply.new(message: request.name.upcase) }
  end
end

describe "GRPC.import_proto" do
  it "generates working service base classes and client stubs" do
    server = GRPC::Server.new
    server.handle(MacroGreeter.new)
    port = server.bind("127.0.0.1:0").as(Socket::IPAddress).port
    server.start
    client = Helloworld::Greeter::Client.new("127.0.0.1:#{port}", default_timeout: 5.seconds)
    begin
      client.say_hello(Helloworld::HelloRequest.new(name: "macro")).message.should eq("Hello macro")
      call = client.say_hello_stream
      call.send(Helloworld::HelloRequest.new(name: "a"))
      call.send(Helloworld::HelloRequest.new(name: "b"))
      call.close_send
      call.map(&.message).to_a.should eq(["A", "B"])
    ensure
      client.close
      server.close
    end
  end
end
