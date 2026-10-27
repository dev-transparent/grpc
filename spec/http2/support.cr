require "../spec_helper"
require "socket"
require "file_utils"

{% if flag?(:execution_context) %}
  # Run the specs with true parallelism: the default execution context
  # starts with a single thread.
  Fiber::ExecutionContext.default.resize((ENV["HTTP2_SPEC_WORKERS"]? || "4").to_i)
{% end %}

# Helpers shared by the HTTP/2 specs.
module HTTP2Spec
  DEFAULT_TIMEOUT = 5.seconds

  class TimeoutError < Exception
  end

  # Runs *block* in a separate fiber and returns its result, raising
  # `TimeoutError` if it does not complete within *timeout*. Exceptions
  # (including spec assertion failures) are re-raised in the caller.
  def self.within(timeout : Time::Span = DEFAULT_TIMEOUT, what : String = "operation", &block : -> T) : T forall T
    channel = Channel(T | Exception).new(1)
    spawn(name: "spec-within") do
      channel.send(block.call)
    rescue ex
      channel.send(ex)
    end
    select
    when result = channel.receive
      case result
      when Exception then raise result
      else                result
      end
    when timeout(timeout)
      raise TimeoutError.new("Timed out after #{timeout} waiting for #{what}")
    end
  end

  # Runs a whole spec body with an upper time bound.
  def self.bounded(timeout : Time::Span = 20.seconds, &block : ->) : Nil
    within(timeout, "spec body") do
      block.call
      nil
    end
  end

  # Polls *block* until it returns a truthy value or *timeout* elapses.
  def self.eventually(timeout : Time::Span = DEFAULT_TIMEOUT, what : String = "condition", &) : Nil
    deadline = Time.instant + timeout
    until yield
      raise TimeoutError.new("Timed out after #{timeout} waiting for #{what}") if Time.instant > deadline
      sleep 5.milliseconds
    end
  end

  # Receives from *channel* with a timeout.
  def self.receive(channel : Channel(T), timeout : Time::Span = DEFAULT_TIMEOUT, what : String = "channel value") : T forall T
    select
    when value = channel.receive
      value
    when timeout(timeout)
      raise TimeoutError.new("Timed out after #{timeout} waiting for #{what}")
    end
  end

  def self.hex(string : String) : Bytes
    string.gsub(/\s+/, "").hexbytes
  end

  def self.random_bytes(size : Int, random = Random.new(42)) : Bytes
    bytes = Bytes.new(size)
    random.random_bytes(bytes)
    bytes
  end

  # Builds a raw frame from its components (used to craft malformed frames).
  def self.raw_frame(type : UInt8 | HTTP2::FrameType, flags : UInt8, stream_id : UInt32, payload : Bytes) : Bytes
    type = type.value if type.is_a?(HTTP2::FrameType)
    io = IO::Memory.new
    size = payload.size
    io.write_byte((size >> 16).to_u8!)
    io.write_byte((size >> 8).to_u8!)
    io.write_byte(size.to_u8!)
    io.write_byte(type)
    io.write_byte(flags)
    io.write_bytes(stream_id, IO::ByteFormat::BigEndian)
    io.write(payload)
    io.to_slice
  end

  # Decodes a single frame from raw bytes.
  def self.decode_frame(bytes : Bytes, max_frame_size : Int32 = HTTP2::DEFAULT_MAX_FRAME_SIZE) : HTTP2::Frame?
    HTTP2::Frame.read(IO::Memory.new(bytes), max_frame_size)
  end

  # Serializes and parses *frame* again.
  def self.round_trip(frame : T) : T forall T
    decode_frame(frame.to_slice, HTTP2::MAX_ALLOWED_FRAME_SIZE).as(T)
  end

  # A frame level HTTP/2 endpoint driven by hand from specs. Frames received
  # from the other side are read by a background fiber and queued so that
  # specs can wait for them with a timeout.
  class RawPeer
    alias Item = HTTP2::Frame | Exception | Nil

    getter io : IO
    getter encoder = HTTP2::HPACK::Encoder.new(huffman: false)
    getter decoder = HTTP2::HPACK::Decoder.new
    getter remote_settings : HTTP2::SettingsFrame? = nil
    getter? closed = false

    @frames = Channel(Item).new(65_536)
    # Frames read ahead (e.g. during the handshake) but not yet consumed.
    @pending = Deque(Item).new
    @write_mutex = Mutex.new

    # When *expect_preface* is set the peer acts as a server and first reads
    # the client connection preface.
    def initialize(@io : IO, expect_preface : Bool = false)
      spawn(name: "raw-peer-reader") { read_loop(expect_preface) }
    end

    private def read_loop(expect_preface : Bool) : Nil
      if expect_preface
        preface = Bytes.new(HTTP2::Connection::CLIENT_PREFACE.size)
        @io.read_fully(preface)
        raise "Invalid client preface #{preface.inspect}" unless preface == HTTP2::Connection::CLIENT_PREFACE
      end
      loop do
        frame = HTTP2::Frame.read(@io, HTTP2::MAX_ALLOWED_FRAME_SIZE)
        @frames.send(frame)
        break unless frame
      end
    rescue IO::Error
      @frames.send(nil)
    rescue ex
      @frames.send(ex)
    ensure
      # The reader closes the socket: closing it from another thread while
      # this fiber waits on it trips a race in Crystal 1.19's event loop
      # under execution contexts.
      @io.close rescue nil
    end

    # Shuts the connection down; the reader fiber then closes the socket.
    def close : Nil
      @closed = true
      HTTP2Spec.shutdown(@io)
    end

    # --- Writing ---

    def send_raw(bytes : Bytes) : Nil
      @write_mutex.synchronize do
        @io.write(bytes)
        @io.flush
      end
    end

    def send(frame : HTTP2::Frame) : Nil
      send_raw(frame.to_slice)
    end

    # Sends *frame*, ignoring errors caused by the other side having closed
    # the connection already.
    def try_send(frame : HTTP2::Frame) : Nil
      send(frame)
    rescue IO::Error
    end

    def send_preface : Nil
      send_raw(HTTP2::Connection::CLIENT_PREFACE)
    end

    def send_settings(params : Array({UInt16, UInt32}) = [] of {UInt16, UInt32}) : Nil
      send(HTTP2::SettingsFrame.new(params))
    end

    def send_settings(**params) : Nil
      list = [] of {UInt16, UInt32}
      params.each do |key, value|
        id = HTTP2::SettingIdentifier.parse(key.to_s)
        list << {id.value, value.to_u32}
      end
      send_settings(list)
    end

    def encode(fields : Array({String, String})) : Bytes
      @encoder.encode(fields)
    end

    def send_headers(stream_id : Int, fields : Array({String, String}), end_stream : Bool = false,
                     priority : HTTP2::Priority? = nil, padding : Int32 = 0) : Nil
      send(HTTP2::HeadersFrame.new(stream_id.to_u32, encode(fields), end_stream: end_stream, priority: priority, padding: padding))
    end

    def send_data(stream_id : Int, data : Bytes | String, end_stream : Bool = false, padding : Int32 = 0) : Nil
      send(HTTP2::DataFrame.new(stream_id.to_u32, data.to_slice, end_stream: end_stream, padding: padding))
    end

    def send_window_update(stream_id : Int, increment : Int) : Nil
      send(HTTP2::WindowUpdateFrame.new(stream_id.to_u32, increment.to_u32))
    end

    def send_rst(stream_id : Int, code : HTTP2::ErrorCode) : Nil
      send(HTTP2::RstStreamFrame.new(stream_id.to_u32, code))
    end

    def request_fields(method = "GET", path = "/", extra = [] of {String, String}) : Array({String, String})
      fields = [{":method", method}, {":scheme", "http"}, {":authority", "example.com"}, {":path", path}]
      fields.concat(extra)
      fields
    end

    # --- Reading ---

    # Returns the next frame (nil once the connection is closed).
    def next_frame(timeout : Time::Span = DEFAULT_TIMEOUT) : HTTP2::Frame?
      item = @pending.empty? ? HTTP2Spec.receive(@frames, timeout, "frame from peer") : @pending.shift
      case item
      when Exception then raise item
      when nil
        # Keep reporting EOF on subsequent reads.
        @frames.send(nil) rescue nil
        nil
      else
        item
      end
    end

    # Frames that carry no information relevant to most specs.
    def noise?(frame : HTTP2::Frame) : Bool
      case frame
      when HTTP2::WindowUpdateFrame then true
      when HTTP2::SettingsFrame     then frame.ack?
      when HTTP2::PingFrame         then frame.ack?
      else                               false
      end
    end

    # Reads frames until one of type *klass* arrives, skipping noise frames.
    # Fails on any other frame or EOF.
    def expect(klass : T.class, timeout : Time::Span = DEFAULT_TIMEOUT, skip_noise : Bool = true) : T forall T
      loop do
        frame = next_frame(timeout)
        raise "Expected #{klass} but the connection was closed" unless frame
        return frame if frame.is_a?(T)
        next if skip_noise && noise?(frame)
        raise "Expected #{klass} but received #{describe(frame)}"
      end
    end

    # Asserts no (non-noise) frame arrives within *duration*.
    def expect_silence(duration : Time::Span = 200.milliseconds) : Nil
      until @pending.empty?
        frame = next_frame
        raise "Expected silence but received #{frame ? describe(frame) : "EOF"}" unless frame && noise?(frame)
      end
      deadline = Time.instant + duration
      loop do
        remaining = deadline - Time.instant
        break if remaining <= Time::Span.zero
        select
        when item = @frames.receive
          case item
          when Exception then raise item
          when nil       then raise "Expected silence but the connection was closed"
          else
            raise "Expected silence but received #{describe(item)}" unless noise?(item)
          end
        when timeout(remaining)
          break
        end
      end
    end

    # Returns all frames received within *duration* (stopping at EOF).
    def collect(duration : Time::Span = 200.milliseconds) : Array(HTTP2::Frame)
      frames = [] of HTTP2::Frame
      while item = @pending.shift?
        raise item if item.is_a?(Exception)
        frames << item
      end
      deadline = Time.instant + duration
      loop do
        remaining = deadline - Time.instant
        break if remaining <= Time::Span.zero
        select
        when item = @frames.receive
          case item
          when Exception then raise item
          when nil
            @frames.send(nil) rescue nil
            break
          else
            frames << item
          end
        when timeout(remaining)
          break
        end
      end
      frames
    end

    # Expects a GOAWAY with *code* followed by the connection closing.
    # Frames of streams (responses to requests that were sent before the
    # offending frame, which handlers running in parallel may produce first)
    # are skipped.
    def expect_goaway(code : HTTP2::ErrorCode, timeout : Time::Span = DEFAULT_TIMEOUT) : HTTP2::GoawayFrame
      goaway = loop do
        frame = next_frame(timeout)
        raise "Expected GOAWAY but the connection was closed" unless frame
        break frame if frame.is_a?(HTTP2::GoawayFrame)
        next if noise?(frame) || frame.stream_id != 0
        raise "Expected GOAWAY but received #{describe(frame)}"
      end
      frame = goaway
      expect_closed(timeout)
      frame
    end

    # Expects the connection to be closed, ignoring frames sent before.
    def expect_closed(timeout : Time::Span = DEFAULT_TIMEOUT) : Nil
      loop do
        frame = next_frame(timeout)
        break unless frame
      end
    end

    def expect_rst(stream_id : Int, code : HTTP2::ErrorCode, timeout : Time::Span = DEFAULT_TIMEOUT) : HTTP2::RstStreamFrame
      loop do
        frame = expect(HTTP2::RstStreamFrame, timeout)
        # RST_STREAM for other streams would be unexpected.
        frame.stream_id.should eq(stream_id.to_u32)
        frame.error_code.should eq(code)
        return frame
      end
    end

    # Reads a complete header block (HEADERS plus CONTINUATION frames).
    def expect_headers(stream_id : Int? = nil, timeout : Time::Span = DEFAULT_TIMEOUT) : {Array({String, String}), HTTP2::HeadersFrame}
      frame = expect(HTTP2::HeadersFrame, timeout)
      frame.stream_id.should eq(stream_id.to_u32) if stream_id
      block = IO::Memory.new
      block.write(frame.fragment)
      ended = frame.end_headers?
      until ended
        cont = expect(HTTP2::ContinuationFrame, timeout, skip_noise: false)
        cont.stream_id.should eq(frame.stream_id)
        block.write(cont.fragment)
        ended = cont.end_headers?
      end
      {@decoder.decode(block.to_slice), frame}
    end

    # Reads frames for *stream_id* until END_STREAM, returning the response
    # header fields, body and trailers. Sends WINDOW_UPDATE frames when
    # *replenish* is set so large bodies can flow.
    def read_message(stream_id : Int, timeout : Time::Span = DEFAULT_TIMEOUT, replenish : Bool = false)
      headers, frame = expect_headers(stream_id, timeout)
      body = IO::Memory.new
      trailers = nil
      ended = frame.end_stream?
      until ended
        frame = next_frame(timeout)
        raise "Connection closed while reading stream #{stream_id}" unless frame
        case frame
        when HTTP2::DataFrame
          frame.stream_id.should eq(stream_id.to_u32)
          body.write(frame.data)
          if replenish && frame.flow_controlled_size > 0
            send_window_update(0, frame.flow_controlled_size)
            send_window_update(stream_id, frame.flow_controlled_size) unless frame.end_stream?
          end
          ended = frame.end_stream?
        when HTTP2::HeadersFrame
          block = IO::Memory.new
          block.write(frame.fragment)
          end_stream = frame.end_stream?
          until frame.as?(HTTP2::HeadersFrame).try(&.end_headers?) || frame.as?(HTTP2::ContinuationFrame).try(&.end_headers?)
            frame = expect(HTTP2::ContinuationFrame, timeout, skip_noise: false)
            block.write(frame.fragment)
          end
          trailers = @decoder.decode(block.to_slice)
          ended = end_stream
        else
          raise "Unexpected #{describe(frame)} while reading stream #{stream_id}" unless noise?(frame)
        end
      end
      {headers, body.to_s, trailers}
    end

    # Client side connection handshake: sends the preface and SETTINGS,
    # acknowledges the server's SETTINGS and waits for our SETTINGS to be
    # acknowledged.
    def handshake(params : Array({UInt16, UInt32}) = [] of {UInt16, UInt32}, timeout : Time::Span = DEFAULT_TIMEOUT) : HTTP2::SettingsFrame
      send_preface
      send_settings(params)
      exchange_settings(timeout)
    end

    # Server side handshake (when this peer plays the server).
    def server_handshake(params : Array({UInt16, UInt32}) = [] of {UInt16, UInt32}, timeout : Time::Span = DEFAULT_TIMEOUT) : HTTP2::SettingsFrame
      send_settings(params)
      exchange_settings(timeout)
    end

    private def exchange_settings(timeout) : HTTP2::SettingsFrame
      settings = nil
      acked = false
      stash = [] of HTTP2::Frame
      until settings && acked
        frame = next_frame(timeout)
        case frame
        when HTTP2::SettingsFrame
          if frame.ack?
            acked = true
          else
            settings = frame
            @remote_settings = frame
            send(HTTP2::SettingsFrame.ack)
          end
        when HTTP2::WindowUpdateFrame
        when nil
          raise "Connection closed during handshake"
        else
          stash << frame
        end
      end
      stash.each { |frame| @pending << frame }
      settings.not_nil!
    end

    def describe(frame : HTTP2::Frame) : String
      extra = case frame
              when HTTP2::GoawayFrame    then " #{frame.error_code} #{String.new(frame.debug_data)}"
              when HTTP2::RstStreamFrame then " #{frame.error_code}"
              when HTTP2::DataFrame      then " (#{frame.data.size} octets#{frame.end_stream? ? ", END_STREAM" : ""})"
              else                            ""
              end
      "#{frame.class.name.split("::").last}(stream #{frame.stream_id})#{extra}"
    end
  end

  # Serves a single connection of *server* over a UNIX socket pair and yields
  # a raw client peer connected to it.
  def self.with_raw_client(server : HTTP2::Server, &)
    client_io, server_io = UNIXSocket.pair
    done = Channel(Nil).new(1)
    spawn(name: "raw-server-connection") do
      server.handle_connection(server_io)
    ensure
      done.send(nil)
    end
    peer = RawPeer.new(client_io)
    begin
      yield peer
    ensure
      peer.close
      select
      when done.receive
      when timeout(DEFAULT_TIMEOUT)
        raise TimeoutError.new("Server connection did not terminate")
      end
    end
  end

  # Builds an `HTTP2::Client` whose connections are UNIX socket pairs whose
  # other end is a `RawPeer` playing the server. New peers are delivered on
  # the returned channel.
  def self.raw_server_client(settings : HTTP2::Settings = HTTP2::Client.default_settings,
                             options : HTTP2::ConnectionOptions = HTTP2::Client.default_options) : {HTTP2::Client, Channel(RawPeer)}
    peers = Channel(RawPeer).new(16)
    client = HTTP2::Client.new("example.com", settings, options: options) do
      client_io, server_io = UNIXSocket.pair
      peers.send(RawPeer.new(server_io, expect_preface: true))
      client_io.as(IO)
    end
    {client, peers}
  end

  # Starts *server* on an ephemeral TCP port and yields a client for it.
  def self.with_server(server : HTTP2::Server, client_settings : HTTP2::Settings = HTTP2::Client.default_settings,
                       client_options : HTTP2::ConnectionOptions = HTTP2::Client.default_options, &)
    address = server.bind_tcp("127.0.0.1", 0)
    done = Channel(Nil).new(1)
    spawn(name: "spec-server") do
      server.listen
    ensure
      done.send(nil)
    end
    client = HTTP2::Client.new("127.0.0.1", address.port, local_settings: client_settings, options: client_options)
    begin
      yield client, address
    ensure
      within(DEFAULT_TIMEOUT, "client close") { client.close } rescue nil
      server.close(1.second) unless server.closed?
      select
      when done.receive
      when timeout(DEFAULT_TIMEOUT)
        raise TimeoutError.new("Server did not stop listening")
      end
    end
  end

  # Shuts both directions of *io* down (making fibers blocked on it fail)
  # without closing it, then closes it once they had a moment to notice.
  # Closing a socket that a fiber on another thread waits on can leak its
  # event loop registration in Crystal 1.19 with execution contexts.
  def self.shutdown(io : IO) : Nil
    if socket = io.as?(Socket)
      socket.close_read rescue nil
      socket.close_write rescue nil
    else
      io.close rescue nil
    end
  end

  # Shuts *socket* down, gives fibers waiting on it time to wake up, then
  # closes it.
  def self.close_socket(socket : Socket) : Nil
    shutdown(socket)
    sleep 10.milliseconds
    socket.close rescue nil
  end

  # Counts the fibers whose name starts with *prefix* (to detect leaks).
  def self.fiber_count(prefix : String = "http2-") : Int32
    count = 0
    Fiber.each { |fiber| count += 1 if fiber.name.try &.starts_with?(prefix) }
    count
  end

  # Self-signed certificate for localhost / 127.0.0.1 generated with the
  # openssl CLI. `paths` is nil (and TLS specs are skipped) if the CLI is
  # not available or fails.
  module TLSFixture
    @@generated = false
    @@paths : {String, String}? = nil

    def self.paths : {String, String}?
      return @@paths if @@generated
      @@generated = true
      return nil unless openssl = Process.find_executable("openssl")
      dir = File.tempname("http2-tls-spec")
      Dir.mkdir_p(dir)
      at_exit { FileUtils.rm_rf(dir) rescue nil }
      cert = File.join(dir, "cert.pem")
      key = File.join(dir, "key.pem")
      status = Process.run(openssl, ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
                                     "-days", "1", "-subj", "/CN=localhost",
                                     "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"],
        output: Process::Redirect::Close, error: Process::Redirect::Close)
      @@paths = {cert, key} if status.success? && File.exists?(cert) && File.exists?(key)
      @@paths
    end

    def self.server_context(alpn : String? = "h2") : OpenSSL::SSL::Context::Server
      cert, key = paths.not_nil!
      context = OpenSSL::SSL::Context::Server.new
      context.certificate_chain = cert
      context.private_key = key
      context.alpn_protocol = alpn if alpn
      context
    end

    def self.client_context(alpn : String? = nil) : OpenSSL::SSL::Context::Client
      cert, _ = paths.not_nil!
      context = OpenSSL::SSL::Context::Client.new
      context.ca_certificates = cert
      context.alpn_protocol = alpn if alpn
      context
    end
  end
end
