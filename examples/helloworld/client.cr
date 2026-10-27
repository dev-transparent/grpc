# crystal run examples/helloworld/client.cr -- World
require "../../src/grpc"
require "./generated/helloworld_grpc.pb"

client = Helloworld::Greeter::Client.new("127.0.0.1:50051", default_timeout: 5.seconds)

reply = client.say_hello(Helloworld::HelloRequest.new(name: ARGV[0]? || "World"))
puts reply.message

begin
  client.say_hello(Helloworld::HelloRequest.new(name: ""))
rescue e : GRPC::Error
  puts "Error: #{e.code} #{e.status.message}"
end

call = client.say_hello_stream
spawn do
  %w(Ada Grace Barbara).each { |name| call.send(Helloworld::HelloRequest.new(name: name)) }
  call.close_send
end
call.each { |reply| puts reply.message }

client.close
