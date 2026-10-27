require "./grpc_helper"

# A minimal gRPC-Web client over HTTP/2 used to test the server side.
private module WebClient
  record Response, status : Int32, headers : HTTP::Headers, messages : Array(Bytes), trailers : Hash(String, String)

  def self.call(address : String, path : String, messages : Array(Protobuf::Message), text : Bool = false,
                headers : HTTP::Headers = HTTP::Headers.new) : Response
    host, port = address.split(':')
    client = HTTP2::Client.new(host, port.to_i)
    begin
      body = IO::Memory.new
      messages.each { |message| body.write(GRPC::Framing.encode(message.to_protobuf)) }
      payload = text ? Base64.strict_encode(body.to_slice).to_slice : body.to_slice
      headers["content-type"] ||= text ? "application/grpc-web-text" : "application/grpc-web+proto"
      headers["x-grpc-web"] = "1"
      response = client.post(path, headers, payload)
      raw = response.body.getb_to_end
      raw = decode_text(raw) if text
      parse(response.status, response.headers, raw)
    ensure
      client.close
    end
  end

  # Decodes concatenated, independently padded base64 segments.
  def self.decode_text(raw : Bytes) : Bytes
    io = IO::Memory.new
    String.new(raw).each_char.each_slice(4) { |quantum| io.write(Base64.decode(quantum.join)) }
    io.to_slice
  end

  def self.parse(status : Int32, headers : HTTP::Headers, raw : Bytes) : Response
    messages = [] of Bytes
    trailers = {} of String => String
    # Trailers-only responses carry the status and trailers in the headers.
    if raw.empty?
      headers.each { |name, values| trailers[name.downcase] = values.first unless name.downcase.in?("content-type", "grpc-accept-encoding") }
    end
    io = IO::Memory.new(raw)
    while io.pos < io.size
      flag = io.read_byte.not_nil!
      length = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
      data = Bytes.new(length)
      io.read_fully(data)
      if flag & 0x80 != 0
        String.new(data).split("\r\n", remove_empty: true).each do |line|
          name, _, value = line.partition(": ")
          trailers[name] = value
        end
      else
        messages << data
      end
    end
    Response.new(status, headers, messages, trailers)
  end
end

describe "gRPC-Web" do
  it "serves unary calls with trailers in the body" do
    GRPCSpec.with_server do |h|
      response = WebClient.call(h.address, "/grpc_spec.TestService/Unary", [GrpcSpec::EchoRequest.new(message: "web")])
      response.status.should eq(200)
      response.headers["content-type"].should eq("application/grpc-web+proto")
      response.messages.size.should eq(1)
      GrpcSpec::EchoResponse.from_protobuf(response.messages[0]).message.should eq("web")
      response.trailers["grpc-status"].should eq("0")
    end
  end

  it "serves server streaming calls" do
    GRPCSpec.with_server do |h|
      response = WebClient.call(h.address, "/grpc_spec.TestService/ServerStream", [GrpcSpec::EchoRequest.new(message: "s", count: 3)])
      response.messages.map { |m| GrpcSpec::EchoResponse.from_protobuf(m).index }.should eq([0, 1, 2])
      response.trailers["grpc-status"].should eq("0")
    end
  end

  it "supports the base64 text encoding" do
    GRPCSpec.with_server do |h|
      response = WebClient.call(h.address, "/grpc_spec.TestService/ServerStream",
        [GrpcSpec::EchoRequest.new(message: "t", count: 2, payload: Bytes.new(1000) { |i| i.to_u8! })], text: true)
      response.headers["content-type"].should eq("application/grpc-web-text+proto")
      response.messages.size.should eq(2)
      GrpcSpec::EchoResponse.from_protobuf(response.messages[0]).message.should eq("t")
      response.trailers["grpc-status"].should eq("0")
    end
  end

  it "reports errors and trailing metadata" do
    GRPCSpec.with_server do |h|
      request = GrpcSpec::EchoRequest.new(status_code: GRPC::StatusCode::NotFound.value, status_message: "gone ☺",
        trailers: {"x-trailer" => "t"})
      response = WebClient.call(h.address, "/grpc_spec.TestService/Unary", [request])
      response.trailers["grpc-status"].should eq("5")
      GRPC::Status.decode_message(response.trailers["grpc-message"]).should eq("gone ☺")
      response.trailers["x-trailer"].should eq("t")
    end
  end

  it "answers unknown methods with UNIMPLEMENTED" do
    GRPCSpec.with_server do |h|
      response = WebClient.call(h.address, "/grpc_spec.TestService/Nope", [GrpcSpec::Empty.new])
      response.trailers["grpc-status"].should eq(GRPC::StatusCode::Unimplemented.value.to_s)
    end
  end

  it "can be disabled" do
    GRPCSpec.with_server(server: GRPC::Server.new(web: false)) do |h|
      WebClient.call(h.address, "/grpc_spec.TestService/Unary", [GrpcSpec::EchoRequest.new]).status.should eq(415)
    end
  end

  describe "CORS" do
    it "answers preflight requests for allowed origins" do
      GRPCSpec.with_server(server: GRPC::Server.new(cors: GRPC::CORS.new(["https://app.example"]))) do |h|
        host, port = h.address.split(':')
        client = HTTP2::Client.new(host, port.to_i)
        begin
          headers = HTTP::Headers{"origin" => "https://app.example", "access-control-request-method" => "POST",
                                  "access-control-request-headers" => "content-type,x-grpc-web,x-custom"}
          response = client.request("OPTIONS", "/grpc_spec.TestService/Unary", headers)
          response.status.should eq(204)
          response.headers["access-control-allow-origin"].should eq("https://app.example")
          response.headers["access-control-allow-methods"].should contain("POST")
          response.headers["access-control-allow-headers"].should eq("content-type,x-grpc-web,x-custom")

          other = client.request("OPTIONS", "/grpc_spec.TestService/Unary",
            HTTP::Headers{"origin" => "https://evil.example", "access-control-request-method" => "POST"})
          other.status.should eq(405)
        ensure
          client.close
        end
      end
    end

    it "exposes gRPC headers on responses" do
      GRPCSpec.with_server(server: GRPC::Server.new(cors: GRPC::CORS.allow_all(extra_exposed_headers: ["x-trailer"]))) do |h|
        response = WebClient.call(h.address, "/grpc_spec.TestService/Unary", [GrpcSpec::EchoRequest.new(message: "c")],
          headers: HTTP::Headers{"origin" => "https://any.example"})
        response.headers["access-control-allow-origin"].should eq("*")
        response.headers["access-control-expose-headers"].should contain("grpc-status")
        response.headers["access-control-expose-headers"].should contain("x-trailer")
      end
    end
  end

  it "rejects standard gRPC over transports without trailers" do
    transport = FakeTransport.new
    server = GRPC::Server.new
    server.serve(transport, "POST", "/grpc_spec.TestService/Unary", [{"content-type", "application/grpc"}], nil)
    transport.headers.not_nil!.find { |(name, _)| name == ":status" }.should eq({":status", "505"})
  end
end

# A transport without trailer support (like HTTP/1.1).
private class FakeTransport < GRPC::ServerTransport
  getter headers : Array({String, String})? = nil

  def request_body : IO
    IO::Memory.new
  end

  def send_headers(fields : Array({String, String}), end_stream : Bool = false) : Nil
    @headers = fields
  end

  def send_data(data : Bytes, end_stream : Bool = false) : Nil
  end

  def send_trailers(fields : Array({String, String})) : Nil
    raise "unsupported"
  end

  def supports_trailers? : Bool
    false
  end

  def abort : Nil
  end

  def stop_receiving : Nil
  end

  def closed? : Bool
    false
  end

  def on_abort(&block : -> Nil) : Nil
  end

  def peer : String?
    nil
  end
end

describe "gRPC-Web over HTTP/1.1" do
  it "serves unary and streaming calls with the stdlib HTTP/1.1 client" do
    GRPCSpec.with_server do |h|
      host, port = h.address.split(':')
      client = HTTP::Client.new(host, port.to_i)
      begin
        [false, true].each do |text|
          body = GRPC::Framing.encode(GrpcSpec::EchoRequest.new(message: "h1", count: 3).to_protobuf)
          body = Base64.strict_encode(body).to_slice if text
          headers = HTTP::Headers{"content-type" => text ? "application/grpc-web-text" : "application/grpc-web+proto", "x-grpc-web" => "1"}
          response = client.post("/grpc_spec.TestService/ServerStream", headers, body: String.new(body))
          response.status_code.should eq(200)
          raw = response.body.to_slice
          raw = WebClient.decode_text(raw) if text
          parsed = WebClient.parse(response.status_code, response.headers, raw)
          parsed.messages.map { |m| GrpcSpec::EchoResponse.from_protobuf(m).index }.should eq([0, 1, 2])
          parsed.trailers["grpc-status"].should eq("0")
        end

        # Errors in trailers-only responses, on the same keep-alive connection.
        body = GRPC::Framing.encode(GrpcSpec::EchoRequest.new(status_code: 7, status_message: "no").to_protobuf)
        response = client.post("/grpc_spec.TestService/Unary", HTTP::Headers{"content-type" => "application/grpc-web"}, body: String.new(body))
        response.headers["grpc-status"].should eq("7")
      ensure
        client.close
      end
    end
  end

  it "rejects standard gRPC over HTTP/1.1" do
    GRPCSpec.with_server do |h|
      host, port = h.address.split(':')
      response = HTTP::Client.new(host, port.to_i).post("/grpc_spec.TestService/Unary",
        HTTP::Headers{"content-type" => "application/grpc"}, body: "")
      response.status_code.should eq(505)
    end
  end

  it "answers CORS preflights over HTTP/1.1" do
    GRPCSpec.with_server(server: GRPC::Server.new(cors: GRPC::CORS.allow_all)) do |h|
      host, port = h.address.split(':')
      response = HTTP::Client.new(host, port.to_i).options("/grpc_spec.TestService/Unary",
        HTTP::Headers{"origin" => "https://x.example", "access-control-request-method" => "POST"})
      response.status_code.should eq(204)
      response.headers["access-control-allow-origin"].should eq("*")
    end
  end

  it "interoperates with the sonora Python gRPC-Web client" do
    python = ENV["PYTHON"]? || "/tmp/grpc-venv-dir/venv/bin/python"
    unless File.exists?(python) && Process.run(python, ["-c", "import sonora.client"]).success?
      pending!("sonora not available")
    end
    GRPCSpec.with_server do |h|
      script = <<-PY
        import sys, sonora.client
        sys.path.insert(0, sys.argv[2])
        from google.protobuf import descriptor_pb2, descriptor_pool, message_factory
        fds = descriptor_pb2.FileDescriptorSet()
        fds.ParseFromString(open(sys.argv[3], "rb").read())
        pool = descriptor_pool.DescriptorPool()
        for f in fds.file: pool.Add(f)
        Req = message_factory.GetMessageClass(pool.FindMessageTypeByName("grpc_spec.EchoRequest"))
        Res = message_factory.GetMessageClass(pool.FindMessageTypeByName("grpc_spec.EchoResponse"))
        with sonora.client.insecure_web_channel("http://" + sys.argv[1]) as channel:
            unary = channel.unary_unary("/grpc_spec.TestService/Unary", request_serializer=Req.SerializeToString, response_deserializer=Res.FromString)
            print("unary", unary(Req(message="sonora")).message)
            stream = channel.unary_stream("/grpc_spec.TestService/ServerStream", request_serializer=Req.SerializeToString, response_deserializer=Res.FromString)
            print("stream", [r.index for r in stream(Req(count=3))])
            try:
                unary(Req(status_code=5, status_message="missing"))
            except Exception as e:
                print("error", e.code(), e.details())
        PY
      descriptors = File.tempname("grpc_spec", ".pb")
      Process.run("protoc", ["--include_imports", "-o", descriptors, "-Ispec/grpc/proto", "test_service.proto"]).success?.should be_true
      output = IO::Memory.new
      status = Process.run(python, ["-c", script, h.address, ".", descriptors], output: output, error: output)
      File.delete?(descriptors)
      output.to_s.should contain("unary sonora")
      output.to_s.should contain("stream [0, 1, 2]")
      output.to_s.should contain("NOT_FOUND")
      status.success?.should be_true
    end
  end
end
