require "./support"

# Concurrency stress specs. With `-Dpreview_mt -Dexecution_context` the
# server and the clients run in separate `Fiber::ExecutionContext::Parallel`
# contexts, so connections, streams and handlers really run in parallel;
# without it they exercise the same code with cooperative concurrency.

{% if flag?(:execution_context) %}
  private def spawn_in(context, name : String, &block : ->) : Nil
    context.as(Fiber::ExecutionContext).spawn(name: name, &block)
  end

  private def new_context(name : String)
    Fiber::ExecutionContext::Parallel.new(name, 4)
  end
{% else %}
  private def spawn_in(context, name : String, &block : ->) : Nil
    spawn(name: name, &block)
  end

  private def new_context(name : String)
    nil
  end
{% end %}

private SERVER_CONTEXT = new_context("spec-server")
private CLIENT_CONTEXT = new_context("spec-clients")

# Echoes the request body (streamed) with the path as a trailer.
private def echo_server
  HTTP2::Server.new do |ctx|
    IO.copy(ctx.request.body, ctx.response)
    ctx.response.trailers["x-path"] = ctx.request.path
  end
end

private def start(server : HTTP2::Server, tls : OpenSSL::SSL::Context::Server? = nil) : {Socket::IPAddress, Channel(Nil)}
  address = tls ? server.bind_tls("127.0.0.1", 0, tls) : server.bind_tcp("127.0.0.1", 0)
  done = Channel(Nil).new(1)
  spawn_in(SERVER_CONTEXT, "spec-listen") do
    server.listen
  ensure
    done.send(nil)
  end
  {address, done}
end

# Runs *workers* fibers in the client context, each performing *requests*
# echo requests on one of *clients*. Returns the errors.
private def hammer(clients : Array(HTTP2::Client), workers : Int32, requests : Int32) : Array(Exception)
  results = Channel(Exception?).new(workers * requests)
  workers.times do |w|
    spawn_in(CLIENT_CONTEXT, "spec-worker") do
      client = clients[w % clients.size]
      random = Random.new(w)
      requests.times do |i|
        path = "/#{w}/#{i}"
        body = HTTP2Spec.random_bytes(random.rand(1..40_000), random)
        response = client.post(path, body: body)
        echoed = response.body.gets_to_end.to_slice
        if echoed != body
          results.send(Exception.new("Body mismatch for #{path}"))
        elsif response.trailers.try(&.["x-path"]?) != path
          results.send(Exception.new("Trailer mismatch for #{path}"))
        else
          results.send(nil)
        end
      rescue e
        results.send(e)
      end
    end
  end
  Array.new(workers * requests) { HTTP2Spec.receive(results, 60.seconds, "request result") }.compact
end

describe "HTTP2 under parallel load" do
  it "serves many concurrent streams on shared and separate connections" do
    HTTP2Spec.bounded(120.seconds) do
      server = echo_server
      address, done = start(server)
      clients = Array.new(4) { HTTP2::Client.new("127.0.0.1", address.port) }
      errors = hammer(clients, 32, 20)
      errors.map(&.message).should be_empty
      clients.each &.close
      server.close(2.seconds)
      HTTP2Spec.receive(done)
    end
  end

  it "serves concurrent streams over TLS" do
    pending!("openssl CLI not available") unless HTTP2Spec::TLSFixture.paths
    HTTP2Spec.bounded(120.seconds) do
      server = echo_server
      address, done = start(server, HTTP2Spec::TLSFixture.server_context)
      clients = Array.new(3) { HTTP2::Client.new("127.0.0.1", address.port, HTTP2Spec::TLSFixture.client_context) }
      errors = hammer(clients, 16, 10)
      errors.map(&.message).should be_empty
      clients.each &.close
      server.close(2.seconds)
      HTTP2Spec.receive(done)
    end
  end

  it "survives connections being drained, reset and cancelled under load" do
    HTTP2Spec.bounded(120.seconds) do
      opts = HTTP2::ConnectionOptions.new(max_connection_age: 100.milliseconds, max_connection_age_grace: 10.seconds)
      server = HTTP2::Server.new(HTTP2::Server.default_settings, options: opts) do |ctx|
        IO.copy(ctx.request.body, ctx.response)
      end
      address, done = start(server)
      client = HTTP2::Client.new("127.0.0.1", address.port)
      results = Channel(Exception?).new(400)
      16.times do |w|
        spawn_in(CLIENT_CONTEXT, "spec-canceller") do
          25.times do |i|
            stream = client.open_stream("POST", "/")
            stream.send_data(Bytes.new(1000))
            if (w + i) % 3 == 0
              stream.reset(HTTP2::ErrorCode::CANCEL)
            else
              stream.close_send
              HTTP2::Client::Response.new(stream).body.gets_to_end.bytesize == 1000 || raise "short body"
            end
            results.send(nil)
          rescue e : HTTP2::RefusedStreamError
            # Refused streams are retry safe.
            results.send(nil)
          rescue e
            results.send(e)
          end
        end
      end
      errors = Array.new(400) { HTTP2Spec.receive(results, 60.seconds) }.compact
      errors.map(&.message).should be_empty
      client.close
      server.close(2.seconds)
      HTTP2Spec.receive(done)
    end
  end
end
