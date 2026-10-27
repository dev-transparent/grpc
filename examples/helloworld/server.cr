# crystal run examples/helloworld/server.cr
require "../../src/grpc"
require "../../src/grpc/health"
require "./generated/helloworld_grpc.pb"

class Greeter < Helloworld::Greeter::Service
  def say_hello(request, context)
    raise GRPC::Error.new(:invalid_argument, "name must not be empty") if request.name.empty?
    Helloworld::HelloReply.new(message: "Hello #{request.name}")
  end

  def say_hello_stream(requests, responses, context)
    requests.each do |request|
      responses << Helloworld::HelloReply.new(message: "Hello #{request.name}")
    end
  end
end

server = GRPC::Server.new
server.handle(Greeter.new)
server.handle(GRPC::HealthService.new)
server.intercept do |context, continuation|
  started = Time.instant
  begin
    continuation.call
  ensure
    puts "#{context.method_path} took #{started.elapsed.total_milliseconds.round(2)}ms"
  end
end

address = server.bind("127.0.0.1:50051")
puts "Listening on #{address}"
Signal::INT.trap { server.close; exit }
server.listen
