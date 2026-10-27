require "../grpc_helper"
require "file_utils"

{% if flag?(:execution_context) && flag?(:preview_mt) %}
  # Run the client specs on several threads (GRPC_SPEC_THREADS, default 4).
  Fiber::ExecutionContext.default.resize((ENV["GRPC_SPEC_THREADS"]? || "4").to_i)
{% end %}

module ClientSpec
  alias EchoRequest = GrpcSpec::EchoRequest
  alias EchoResponse = GrpcSpec::EchoResponse
  alias Client = GrpcSpec::TestService::Client

  UNARY         = "/grpc_spec.TestService/Unary"
  SERVER_STREAM = "/grpc_spec.TestService/ServerStream"
  CLIENT_STREAM = "/grpc_spec.TestService/ClientStream"
  BIDI          = "/grpc_spec.TestService/Bidi"

  # Fast backoff for specs.
  FAST_BACKOFF = GRPC::ConnectionBackoff.new(initial: 50.milliseconds, max: 200.milliseconds,
    min_connect_timeout: 2.seconds)

  # A test service that answers unary calls with its name.
  class NamedService < GRPCSpec::TestServiceImpl
    getter name : String
    getter calls = Atomic(Int32).new(0)

    def initialize(@name : String)
      super()
    end

    def unary(request, context)
      @calls.add(1)
      if request.message == "name"
        EchoResponse.new(message: @name)
      else
        super
      end
    end
  end

  # A gRPC server on 127.0.0.1 serving *impl*.
  class TestServer
    getter server : GRPC::Server
    getter port : Int32
    getter impl : GRPCSpec::TestServiceImpl

    def initialize(@impl : GRPCSpec::TestServiceImpl = GRPCSpec::TestServiceImpl.new, port : Int32 = 0,
                   tls : OpenSSL::SSL::Context::Server? = nil)
      @server = GRPC::Server.new
      @server.handle(@impl)
      address = tls ? @server.bind_tls("127.0.0.1", port, tls) : @server.bind_tcp("127.0.0.1", port)
      @port = address.port
      @server.start
    end

    def address : String
      "127.0.0.1:#{@port}"
    end

    def close : Nil
      @server.close(1.second) rescue nil
    end
  end

  # Runs servers for the duration of the block.
  def self.with_servers(count : Int32, &block : Array(TestServer) ->) : Nil
    servers = Array.new(count) { |i| TestServer.new(NamedService.new("s#{i}")) }
    begin
      GRPCSpec.within(20.seconds) { block.call(servers) }
    ensure
      servers.each &.close
    end
  end

  # A port with nothing listening on it (yet).
  def self.free_port : Int32
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    server.close
    port
  end

  # Polls until the block returns true.
  def self.wait_until(timeout : Time::Span = 5.seconds, message = "condition", &block : -> Bool) : Nil
    deadline = Time.instant + timeout
    until block.call
      if Time.instant > deadline
        raise Spec::AssertionFailed.new("Timed out waiting for #{message}", __FILE__, __LINE__)
      end
      sleep 5.milliseconds
    end
  end

  # A plain HTTP/2 server impersonating a gRPC server whose responses are
  # scripted per request (attempt). Records the request headers.
  class ScriptedServer
    alias Handler = Proc(Int32, HTTP2::Server::Context, Nil)

    getter requests = [] of Array({String, String})
    getter port : Int32
    @mutex = Mutex.new

    def initialize(&handler : Int32, HTTP2::Server::Context ->)
      @handler = handler
      @server = HTTP2::Server.new(->(context : HTTP2::Server::Context) { handle(context) })
      @port = @server.bind_tcp("127.0.0.1", 0).port
      spawn { @server.listen }
      Fiber.yield
    end

    def address : String
      "127.0.0.1:#{@port}"
    end

    def request_count : Int32
      @mutex.synchronize { @requests.size }
    end

    # The value of header *name* in each request.
    def header_values(name : String) : Array(String?)
      @mutex.synchronize { @requests.map { |fields| fields.find { |(key, _)| key == name }.try(&.[1]) } }
    end

    def close : Nil
      @server.close(1.second) rescue nil
    end

    private def handle(context : HTTP2::Server::Context) : Nil
      index = @mutex.synchronize do
        @requests << context.stream.headers
        @requests.size - 1
      end
      @handler.call(index, context)
    end

    # Responds with a single message and OK trailers.
    def self.ok(context : HTTP2::Server::Context, message : String = "ok") : Nil
      context.request.body.gets_to_end
      stream = context.stream
      stream.send_headers([{":status", "200"}, {"content-type", "application/grpc"}])
      stream.send_data(GRPC::Framing.encode(EchoResponse.new(message: message).to_protobuf))
      stream.send_trailers([{"grpc-status", "0"}])
    end

    # Responds with a trailers-only status (plus *extra* fields).
    def self.fail(context : HTTP2::Server::Context, code : GRPC::StatusCode,
                  extra : Array({String, String}) = [] of {String, String}, read_body : Bool = true) : Nil
      context.request.body.gets_to_end if read_body
      fields = [{":status", "200"}, {"content-type", "application/grpc"}, {"grpc-status", code.value.to_s},
                {"grpc-message", "scripted #{code}"}]
      context.stream.send_headers(fields + extra, end_stream: true)
    end
  end

  def self.with_scripted_server(&handler : Int32, HTTP2::Server::Context ->) : ScriptedServer
    ScriptedServer.new(&handler)
  end

  # Certificates generated with the openssl CLI: a CA, a server certificate
  # for localhost/127.0.0.1, a server certificate only valid for
  # "override.test" and a client certificate.
  module Certs
    @@generated = false
    @@dir : String? = nil

    def self.dir : String?
      return @@dir if @@generated
      @@generated = true
      return nil unless openssl = Process.find_executable("openssl")
      dir = File.tempname("grpc-client-certs")
      Dir.mkdir_p(dir)
      at_exit { FileUtils.rm_rf(dir) rescue nil }
      ok = run(openssl, dir, ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.pem",
                              "-days", "1", "-subj", "/CN=gRPC Spec CA"]) &&
           run(openssl, dir, ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "other-ca.key",
                              "-out", "other-ca.pem", "-days", "1", "-subj", "/CN=Other CA"]) &&
           issue(openssl, dir, "server", "/CN=localhost", "subjectAltName=DNS:localhost,IP:127.0.0.1") &&
           issue(openssl, dir, "override", "/CN=override.test", "subjectAltName=DNS:override.test") &&
           issue(openssl, dir, "client", "/CN=spec-client", "extendedKeyUsage=clientAuth")
      @@dir = dir if ok
      @@dir
    end

    def self.path(name : String) : String
      File.join(dir.not_nil!, name)
    end

    def self.server_context(name : String = "server", client_ca : Bool = false) : OpenSSL::SSL::Context::Server
      context = OpenSSL::SSL::Context::Server.new
      context.certificate_chain = path("#{name}.pem")
      context.private_key = path("#{name}.key")
      context.alpn_protocol = "h2"
      if client_ca
        context.ca_certificates = path("ca.pem")
        context.verify_mode = OpenSSL::SSL::VerifyMode::PEER | OpenSSL::SSL::VerifyMode::FAIL_IF_NO_PEER_CERT
      end
      context
    end

    private def self.issue(openssl : String, dir : String, name : String, subject : String, extension : String) : Bool
      File.write(File.join(dir, "#{name}.ext"), extension + "\n")
      run(openssl, dir, ["req", "-newkey", "rsa:2048", "-nodes", "-keyout", "#{name}.key", "-out", "#{name}.csr",
                         "-subj", subject]) &&
        run(openssl, dir, ["x509", "-req", "-in", "#{name}.csr", "-CA", "ca.pem", "-CAkey", "ca.key",
                           "-CAcreateserial", "-out", "#{name}.pem", "-days", "1", "-extfile", "#{name}.ext"])
    end

    private def self.run(openssl : String, dir : String, args : Array(String)) : Bool
      Process.run(openssl, args, chdir: dir, output: Process::Redirect::Close, error: Process::Redirect::Close).success?
    end
  end
end
