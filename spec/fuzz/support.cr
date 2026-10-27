require "../../src/http2"
require "socket"
require "digest/sha1"

# A small mutation fuzzer for the HTTP/2 layer. Crystal has no libFuzzer
# integration, so this implements the usual pieces: a seed corpus captured
# from real client/server traffic, byte and frame level mutations, targets
# with invariants and a time bounded runner that saves failing inputs.
#
# Used by `spec/fuzz/*_spec.cr` (short fixed-seed runs) and
# `spec/fuzz/http2_fuzz.cr` (long campaigns, see `script/fuzz.sh`).
module Fuzz
  # Raised by a target when an invariant is violated.
  class Failure < Exception
  end

  # Upper bound for a single network target iteration.
  ITERATION_TIMEOUT = 5.seconds
  # How long the peer waits for running handlers after sending its input.
  SETTLE_TIME = 20.milliseconds

  # --- Mutations ---

  INTERESTING_8  = [0x00, 0x01, 0x05, 0x08, 0x10, 0x20, 0x3f, 0x40, 0x7f, 0x80, 0xc0, 0xfe, 0xff]
  INTERESTING_32 = [0_u32, 1_u32, 2_u32, 3_u32, 0xff_u32, 0x4000_u32, 0x4001_u32, 0xffff_u32, 0x10000_u32,
                    0x7fffffff_u32, 0x80000000_u32, 0xffffffff_u32, 0xffffff_u32, 65_535_u32]

  # Deterministic (seeded) mutation engine. Mutations operate on raw bytes
  # (bit flips, interesting values, inserts, deletes, duplications, splices
  # with other corpus entries, truncation) and on the HTTP/2 frame structure
  # (dropping, duplicating, swapping and rewriting frames).
  class Mutator
    getter random : Random

    def initialize(@random : Random, @corpus : Array(Bytes))
    end

    def mutate(input : Bytes) : Bytes
      data = input.to_a
      (1 + @random.rand(4)).times do
        data = case @random.rand(13)
               when 0 then flip_bit(data)
               when 1 then set_byte(data)
               when 2 then insert_bytes(data)
               when 3 then delete_range(data)
               when 4 then duplicate_range(data)
               when 5 then splice(data)
               when 6 then truncate(data)
               when 7 then set_u32(data)
               else        mutate_frames(data)
               end
      end
      Slice.new(data.size) { |i| data[i] }
    end

    private def flip_bit(data)
      return data if data.empty?
      i = @random.rand(data.size)
      data[i] ^= (1_u8 << @random.rand(8))
      data
    end

    private def set_byte(data)
      return data if data.empty?
      data[@random.rand(data.size)] = random_byte
      data
    end

    private def random_byte : UInt8
      @random.next_bool ? INTERESTING_8.sample(@random).to_u8 : @random.rand(256).to_u8
    end

    private def insert_bytes(data)
      at = @random.rand(data.size + 1)
      count = 1 + @random.rand(16)
      data.insert_all(at, Array.new(count) { random_byte })
    end

    private def delete_range(data)
      return data if data.empty?
      at = @random.rand(data.size)
      count = 1 + @random.rand(Math.min(32, data.size - at))
      data.delete_at(at, count)
      data
    end

    private def duplicate_range(data)
      return data if data.empty?
      at = @random.rand(data.size)
      count = 1 + @random.rand(Math.min(64, data.size - at))
      data.insert_all(@random.rand(data.size + 1), data[at, count])
    end

    private def splice(data)
      other = @corpus.sample(@random)
      return data if other.empty?
      from = @random.rand(other.size)
      count = 1 + @random.rand(other.size - from)
      if @random.next_bool
        # Crossover: our prefix followed by the other input's suffix.
        cut = @random.rand(data.size + 1)
        data[0, cut] + other[from, other.size - from].to_a
      else
        data.insert_all(@random.rand(data.size + 1), other[from, count].to_a)
      end
    end

    private def truncate(data)
      return data if data.empty?
      data[0, @random.rand(data.size)]
    end

    private def set_u32(data)
      return data if data.size < 4
      at = @random.rand(data.size - 3)
      value = INTERESTING_32.sample(@random)
      4.times { |i| data[at + i] = (value >> (24 - 8 * i)).to_u8! }
      data
    end

    # --- Frame level ---

    private def mutate_frames(data)
      prefix, frames, rest = Fuzz.split_frames(data)
      return set_byte(data) if frames.empty?
      case @random.rand(11)
      when 8, 9
        i = @random.rand(frames.size)
        frames[i] = toggle_flag(frames[i])
      when 10
        i = @random.rand(frames.size)
        if split = split_header_block(frames[i])
          frames[i] = split[0]
          frames.insert(i + 1, split[1])
        end
      when 0 then frames.delete_at(@random.rand(frames.size))
      when 1
        frame = frames.sample(@random)
        frames.insert(@random.rand(frames.size + 1), frame.dup)
      when 2
        i = @random.rand(frames.size)
        j = @random.rand(frames.size)
        frames[i], frames[j] = frames[j], frames[i]
      when 3 then frames.insert(@random.rand(frames.size + 1), synthetic_frame)
      else
        i = @random.rand(frames.size)
        frames[i] = rewrite_frame(frames[i])
      end
      result = prefix.dup
      frames.each { |frame| result.concat(frame) }
      result.concat(rest)
      result
    end

    # Toggles one of the meaningful flag bits (END_STREAM/ACK, END_HEADERS,
    # PADDED, PRIORITY).
    private def toggle_flag(frame : Array(UInt8)) : Array(UInt8)
      frame = frame.dup
      frame[4] ^= [0x1_u8, 0x4_u8, 0x8_u8, 0x20_u8].sample(@random)
      frame
    end

    # Splits a HEADERS or CONTINUATION frame (without padding or priority)
    # into itself and a CONTINUATION frame carrying the rest of the
    # fragment; either part may be empty.
    private def split_header_block(frame : Array(UInt8)) : {Array(UInt8), Array(UInt8)}?
      return nil unless frame[3] == 1 || frame[3] == 9
      return nil if frame[4] & 0x28 != 0
      fragment = frame[9, frame.size - 9]
      cut = @random.rand(fragment.size + 1)
      first = frame[0, 9] + fragment[0, cut]
      Fuzz.set_length(first, cut)
      end_headers = first[4] & 0x4
      first[4] &= ~0x4_u8
      second = [0_u8, 0_u8, 0_u8, 9_u8, end_headers] + frame[5, 4] + fragment[cut, fragment.size - cut]
      Fuzz.set_length(second, fragment.size - cut)
      {first, second}
    end

    # Changes the type, flags, stream identifier, length or payload of a
    # serialized frame.
    private def rewrite_frame(frame : Array(UInt8)) : Array(UInt8)
      frame = frame.dup
      case @random.rand(6)
      when 0 then frame[3] = @random.rand(3) == 0 ? @random.rand(256).to_u8 : @random.rand(10).to_u8
      when 1 then frame[4] = @random.next_bool ? (1_u8 << @random.rand(8)) ^ frame[4] : @random.rand(256).to_u8
      when 2
        id = [0_u32, 1_u32, 2_u32, 3_u32, 5_u32, 7_u32, 0x7fffffff_u32, 0x80000001_u32, @random.rand(UInt32::MAX)].sample(@random)
        4.times { |k| frame[5 + k] = (id >> (24 - 8 * k)).to_u8! }
      when 3
        length = ((frame[0].to_i32 << 16) | (frame[1].to_i32 << 8) | frame[2]) + @random.rand(-8..8)
        length = length.clamp(0, 0xffffff)
        frame[0] = (length >> 16).to_u8!
        frame[1] = (length >> 8).to_u8!
        frame[2] = length.to_u8!
      when 4
        payload = Array.new(@random.rand(32)) { random_byte }
        frame = frame[0, 9] + payload
        Fuzz.set_length(frame, payload.size)
      else
        # Mutate inside the payload only.
        if frame.size > 9
          frame[9 + @random.rand(frame.size - 9)] = random_byte
        end
      end
      frame
    end

    private def synthetic_frame : Array(UInt8)
      type = @random.rand(3) == 0 ? @random.rand(256) : @random.rand(10)
      payload = case type
                when 4    then Array.new(6 * @random.rand(4)) { random_byte }
                when 6    then Array.new(8) { random_byte }
                when 3, 8 then Array.new(4) { random_byte }
                when 2    then Array.new(5) { random_byte }
                when 7    then Array.new(8 + @random.rand(8)) { random_byte }
                else           Array.new(@random.rand(24)) { random_byte }
                end
      id = [0_u32, 1_u32, 3_u32, 2_u32, @random.rand(16).to_u32].sample(@random)
      frame = [0_u8, 0_u8, 0_u8, type.to_u8, @random.rand(256).to_u8]
      4.times { |k| frame << (id >> (24 - 8 * k)).to_u8! }
      frame.concat(payload)
      Fuzz.set_length(frame, payload.size)
      frame
    end
  end

  # Splits serialized HTTP/2 traffic into the client preface (if present),
  # complete frames and trailing bytes.
  def self.split_frames(data : Array(UInt8)) : {Array(UInt8), Array(Array(UInt8)), Array(UInt8)}
    preface = HTTP2::Connection::CLIENT_PREFACE
    offset = 0
    if data.size >= preface.size && (0...preface.size).all? { |i| data[i] == preface[i] }
      offset = preface.size
    end
    prefix = data[0, offset]
    frames = [] of Array(UInt8)
    while offset + 9 <= data.size
      length = (data[offset].to_i32 << 16) | (data[offset + 1].to_i32 << 8) | data[offset + 2]
      break if offset + 9 + length > data.size
      frames << data[offset, 9 + length]
      offset += 9 + length
    end
    {prefix, frames, data[offset, data.size - offset]}
  end

  def self.set_length(frame : Array(UInt8), length : Int32) : Nil
    frame[0] = (length >> 16).to_u8!
    frame[1] = (length >> 8).to_u8!
    frame[2] = length.to_u8!
  end

  # --- Corpus ---

  # Records everything written to an IO.
  class Recorder < IO
    getter log = IO::Memory.new

    def initialize(@io : IO)
      if buffered = @io.as?(IO::Buffered)
        buffered.sync = false
      end
    end

    def read(slice : Bytes) : Int32
      @io.read(slice)
    end

    def write(slice : Bytes) : Nil
      @log.write(slice)
      @io.write(slice)
    end

    def flush : Nil
      @io.flush
    end

    def close : Nil
      @io.close
    end

    def closed? : Bool
      @io.closed?
    end
  end

  # A request of a client scenario: header fields, optional body and
  # trailers.
  record Request, fields : Array({String, String}), body : Bytes? = nil, trailers : Array({String, String})? = nil,
    reset : Bool = false

  # Traffic captured from one client/server exchange: the requests the
  # client made, the bytes it sent and the bytes the server sent.
  record Capture, requests : Array(Request), client_bytes : Bytes, server_bytes : Bytes

  def self.request(path : String, method = "GET", extra = [] of {String, String}, body : Bytes? = nil,
                   trailers : Array({String, String})? = nil, reset = false) : Request
    fields = [{":method", method}, {":scheme", "http"}, {":authority", "example.com"}, {":path", path}]
    fields.concat(extra)
    Request.new(fields, body, trailers, reset)
  end

  # The handler used by the server target (and corpus capture): reads the
  # request and answers based on the path.
  def self.serve(stream : HTTP2::Stream) : Nil
    fields = stream.headers
    path = fields.find { |(name, _)| name == ":path" }.try(&.[1]) || "/"
    stream.body.skip_to_end
    case path
    when "/big"
      stream.send_headers([{":status", "200"}, {"content-type", "application/octet-stream"}])
      stream.send_data(Bytes.new(100_000, 7_u8), end_stream: true)
    when "/trailers"
      stream.send_headers([{":status", "200"}, {"content-type", "application/grpc"}])
      stream.send_data(Bytes[0, 0, 0, 0, 2, 8, 1])
      stream.send_trailers([{"grpc-status", "0"}, {"grpc-message", "OK"}])
    when "/empty"
      stream.send_headers([{":status", "204"}], end_stream: true)
    when "/headers"
      stream.send_headers([{":status", "200"}, {"x-large", "v" * 20_000}, {"set-cookie", "a=b; secure"}], end_stream: true)
    else
      stream.send_headers([{":status", "200"}, {"content-type", "text/plain"}, {"cache-control", "no-cache"}])
      stream.send_data("hello #{path}".to_slice, end_stream: true)
    end
  end

  # Client scenarios used to capture the seed corpus.
  def self.scenarios : Array({HTTP2::Settings, Array(Request)})
    grpc = [{"content-type", "application/grpc"}, {"te", "trailers"}, {"user-agent", "grpc-crystal/fuzz"}]
    [
      {HTTP2::Client.default_settings, [request("/")]},
      {HTTP2::Client.default_settings, [request("/post", "POST", [{"content-type", "text/plain"}], Bytes.new(3000, 'x'.ord.to_u8))]},
      {HTTP2::Client.default_settings, [request("/trailers", "POST", grpc, Bytes[0, 0, 0, 0, 0], [{"grpc-timeout", "1S"}])]},
      {HTTP2::Client.default_settings, [request("/headers", extra: [{"x-big", "b" * 20_000}, {"cookie", "session=1234567890abcdefghij"}, {"authorization", "Bearer token"}])]},
      {HTTP2::Client.default_settings, (1..5).map { |i| request("/s#{i}", extra: [{"x-n", i.to_s}]) }},
      {HTTP2::Client.default_settings, [request("/reset", "POST", body: Bytes.new(100), reset: true), request("/after")]},
      {HTTP2::Client.default_settings, [request("/big"), request("/empty", "HEAD")]},
      {HTTP2::Settings.new(header_table_size: 0_u32, enable_push: false, initial_window_size: 1000_u32, max_frame_size: 16_384_u32, max_header_list_size: 70_000_u32),
       [request("/big"), request("/headers")]},
      {HTTP2::Settings.new(header_table_size: 256_u32, enable_push: false, max_concurrent_streams: 2_u32, max_frame_size: 20_000_u32),
       [request("/a", extra: [{"accept", "*/*"}]), request("/a", extra: [{"accept", "*/*"}]), request("/trailers", "POST", grpc, Bytes.new(10))]},
    ]
  end

  # Runs every scenario between a real client and server and records the
  # traffic in both directions, plus handcrafted traffic using the frame
  # types and flags our own endpoints never send (priority, padding,
  # informational responses, unknown frames, ...).
  def self.capture_all : Array(Capture)
    scenarios.map { |(settings, requests)| capture(settings, requests) } + [handcrafted]
  end

  # Traffic in both directions exercising every frame type and flag.
  def self.handcrafted : Capture
    encoder = HTTP2::HPACK::Encoder.new
    priority = HTTP2::Priority.new(0_u32, 77_u8, true)
    client = IO::Memory.new
    client.write(HTTP2::Connection::CLIENT_PREFACE)
    [
      HTTP2::SettingsFrame.new([{1_u16, 8192_u32}, {3_u16, 50_u32}, {4_u16, 100_000_u32}, {0xff_u16, 1_u32}]),
      HTTP2::SettingsFrame.ack,
      HTTP2::HeadersFrame.new(1_u32, encoder.encode(request("/p", "POST").fields), priority: priority, padding: 4),
      HTTP2::DataFrame.new(1_u32, "abc".to_slice, padding: 6),
      HTTP2::PriorityFrame.new(3_u32, priority),
      HTTP2::PriorityFrame.new(1_u32, HTTP2::Priority.new(3_u32, 1_u8, false)),
      HTTP2::WindowUpdateFrame.new(0_u32, 1000_u32),
      HTTP2::WindowUpdateFrame.new(1_u32, 500_u32),
      HTTP2::PingFrame.new(Bytes[1, 2, 3, 4, 5, 6, 7, 8]),
      HTTP2::HeadersFrame.new(1_u32, encoder.encode([{"grpc-status", "0"}]), end_stream: true),
      HTTP2::HeadersFrame.new(3_u32, encoder.encode(request("/c").fields)[0, 5], end_headers: false),
      HTTP2::UnknownFrame.new(0xfa_u8, 0_u8, 0_u32, Bytes[1, 2]),
      HTTP2::RstStreamFrame.new(3_u32, HTTP2::ErrorCode::CANCEL),
      HTTP2::HeadersFrame.new(5_u32, encoder.encode(request("/c").fields), end_stream: true),
      HTTP2::GoawayFrame.new(0_u32, HTTP2::ErrorCode::NO_ERROR, "bye".to_slice),
    ].each &.write(client)

    server_encoder = HTTP2::HPACK::Encoder.new
    server = IO::Memory.new
    [
      HTTP2::SettingsFrame.new([{3_u16, 10_u32}, {5_u16, 20_000_u32}, {6_u16, 4000_u32}]),
      HTTP2::SettingsFrame.ack,
      HTTP2::HeadersFrame.new(1_u32, server_encoder.encode([{":status", "100"}])),
      HTTP2::HeadersFrame.new(1_u32, server_encoder.encode([{":status", "200"}, {"content-length", "5"}])[0, 3], end_headers: false, padding: 2, priority: priority),
      HTTP2::ContinuationFrame.new(1_u32, Bytes.empty, end_headers: false),
      HTTP2::DataFrame.new(1_u32, "hello".to_slice, padding: 10),
      HTTP2::PingFrame.new(Bytes[8, 7, 6, 5, 4, 3, 2, 1]),
      HTTP2::PriorityFrame.new(3_u32, priority),
      HTTP2::WindowUpdateFrame.new(3_u32, 70_000_u32),
      HTTP2::HeadersFrame.new(3_u32, server_encoder.encode([{":status", "204"}]), end_stream: true),
      HTTP2::RstStreamFrame.new(5_u32, HTTP2::ErrorCode::REFUSED_STREAM),
      HTTP2::UnknownFrame.new(0x10_u8, 0xff_u8, 7_u32, Bytes[0]),
      HTTP2::GoawayFrame.new(3_u32, HTTP2::ErrorCode::ENHANCE_YOUR_CALM, "calm".to_slice),
    ].each &.write(server)
    Capture.new([request("/a"), request("/b", "POST", body: Bytes.new(10)), request("/c")],
      client.to_slice.dup, server.to_slice.dup)
  end

  def self.capture(settings : HTTP2::Settings, requests : Array(Request)) : Capture
    client_io, server_io = UNIXSocket.pair
    client_rec = Recorder.new(client_io)
    server_rec = Recorder.new(server_io)
    server = HTTP2::Connection.new(server_rec, HTTP2::Connection::Role::Server, HTTP2::Server.default_settings, 1 << 20)
    server.on_stream = ->(stream : HTTP2::Stream) { serve(stream) rescue nil; nil }
    server_done = Channel(Nil).new(1)
    spawn { server.run; server_done.send(nil) }
    client = HTTP2::Connection.new(client_rec, HTTP2::Connection::Role::Client, settings, 1 << 20)
    client.start
    run_requests(client, requests, wait: true)
    sleep 20.milliseconds
    client.ping(2.seconds) rescue nil
    client.shutdown(2.seconds)
    select
    when server_done.receive
    when timeout(5.seconds)
      raise "Capture did not finish"
    end
    Capture.new(requests, client_rec.log.to_slice.dup, server_rec.log.to_slice.dup)
  end

  # Opens a stream per request and consumes the responses in fibers.
  # Returns a channel receiving one result per request: `nil` or an
  # unexpected exception.
  def self.run_requests(client : HTTP2::Connection, requests : Array(Request), wait : Bool) : Channel(Exception?)
    results = Channel(Exception?).new(requests.size)
    streams = requests.map do |request|
      begin
        client.open_stream(request.fields, end_stream: request.body.nil? && request.trailers.nil?)
      rescue e : HTTP2::Error
        e
      end
    end
    requests.zip(streams).each do |request, stream|
      spawn(name: "fuzz-request") do
        results.send(consume(stream, request))
      end
    end
    if wait
      requests.size.times do
        select
        when error = results.receive
          raise error if error
        when timeout(5.seconds)
          raise "Request did not finish"
        end
      end
    end
    results
  end

  private def self.consume(stream : HTTP2::Stream | HTTP2::Error, request : Request) : Exception?
    return nil if stream.is_a?(HTTP2::Error)
    if body = request.body
      stream.send_data(body, end_stream: request.trailers.nil? && !request.reset)
    end
    if request.reset
      stream.reset(HTTP2::ErrorCode::CANCEL)
      return nil
    end
    if trailers = request.trailers
      stream.send_trailers(trailers)
    end
    stream.headers
    stream.body.skip_to_end
    stream.trailers
    nil
  rescue HTTP2::Error | IO::Error
    nil
  rescue e
    e
  end

  # Header blocks (as length prefixed sequences sharing one dynamic table)
  # for the HPACK target.
  def self.hpack_corpus : Array(Bytes)
    lists = [
      [{":method", "GET"}, {":scheme", "https"}, {":path", "/"}, {":authority", "www.example.com"}],
      [{":method", "GET"}, {":scheme", "https"}, {":path", "/"}, {":authority", "www.example.com"}, {"cache-control", "no-cache"}],
      [{":method", "POST"}, {":path", "/grpc.Service/Method"}, {"content-type", "application/grpc"}, {"te", "trailers"}, {"grpc-timeout", "10S"}],
      [{":status", "200"}, {"set-cookie", "a=b"}, {"cookie", "x" * 40}, {"authorization", "secret"}],
      [{"x-custom", "v" * 2000}, {"x-other", "éè\u0000\xff"}],
      [{":status", "404"}, {"content-length", "0"}, {"date", "Mon, 21 Oct 2013 20:13:21 GMT"}],
    ]
    corpus = [] of Bytes
    [4096, 256, 0].each do |table_size|
      encoder = HTTP2::HPACK::Encoder.new(4096, huffman: table_size != 256)
      encoder.peer_max_table_size = table_size
      io = IO::Memory.new
      lists.each do |list|
        block = encoder.encode(list)
        io.write_bytes(block.size.to_u16, IO::ByteFormat::BigEndian)
        io.write(block)
      end
      corpus << io.to_slice.dup
    end
    corpus
  end

  # --- Targets ---

  # Parses *input* as a sequence of frames. Only `HTTP2::ConnectionError`,
  # `HTTP2::StreamError` and `IO::EOFError` (truncation) are acceptable;
  # decoded frames must survive a serialization round trip.
  def self.frame_target(input : Bytes, max_frame_size : Int32 = HTTP2::DEFAULT_MAX_FRAME_SIZE) : Nil
    io = IO::Memory.new(input)
    while frame = HTTP2::Frame.read(io, max_frame_size)
      again = HTTP2::Frame.read(IO::Memory.new(frame.to_slice), HTTP2::MAX_ALLOWED_FRAME_SIZE)
      unless again && again.class == frame.class && again.stream_id == frame.stream_id && again.flags == frame.flags
        raise Failure.new("Frame round trip mismatch: #{frame.inspect} vs #{again.inspect}")
      end
    end
  rescue HTTP2::ConnectionError | HTTP2::StreamError | IO::EOFError
  end

  # Decodes length prefixed header blocks with one decoder. Only
  # `DecompressionError` is acceptable; the dynamic table and header lists
  # must respect their limits and decoded lists must round trip.
  def self.hpack_target(input : Bytes, table_limit : Int32 = 4096, list_limit : Int32 = 16_384) : Nil
    decoder = HTTP2::HPACK::Decoder.new(table_limit, list_limit)
    io = IO::Memory.new(input)
    loop do
      size = io.read_bytes(UInt16, IO::ByteFormat::BigEndian) rescue break
      block = Bytes.new(Math.min(size.to_i32, io.size - io.pos))
      io.read_fully(block)
      headers = begin
        decoder.decode(block)
      rescue HTTP2::HPACK::DecompressionError
        next
      ensure
        table = decoder.table
        if table.size > table.max_size || table.max_size > table_limit
          raise Failure.new("Dynamic table exceeds its limit (#{table.size}/#{table.max_size}/#{table_limit})")
        end
      end
      list_size = headers.sum { |(name, value)| name.bytesize + value.bytesize + 32 }
      raise Failure.new("Header list of #{list_size} octets exceeds #{list_limit}") if list_size > list_limit
      encoded = HTTP2::HPACK::Encoder.new.encode(headers)
      again = HTTP2::HPACK::Decoder.new(4096, Int32::MAX).decode(encoded)
      raise Failure.new("HPACK round trip mismatch: #{headers.inspect} vs #{again.inspect}") unless again == headers
    end
  end

  # The HTTP/2 layer's live fibers.
  def self.http2_fibers : Set(Fiber)
    fibers = Set(Fiber).new
    Fiber.each { |fiber| fibers << fiber if fiber.name.try &.starts_with?("http2-") }
    fibers
  end

  # HTTP/2 fibers that are alive now but were not in *before*.
  def self.new_http2_fibers(before : Set(Fiber)) : Array(Fiber)
    http2_fibers.reject { |fiber| before.includes?(fiber) }
  end

  def self.target_options : HTTP2::ConnectionOptions
    HTTP2::ConnectionOptions.new(settings_timeout: 2.seconds, close_timeout: 500.milliseconds,
      keepalive_time: 1.second, keepalive_timeout: 1.second, min_ping_interval: 1.second)
  end

  # Feeds *input* (client to server traffic) to a server connection over a
  # socket pair, in chunks chosen by *random*.
  def self.server_target(input : Bytes, random : Random) : Nil
    errors = Channel(Exception).new(64)
    peer, server_io = UNIXSocket.pair
    connection = HTTP2::Connection.new(server_io, HTTP2::Connection::Role::Server,
      HTTP2::Settings.new(max_concurrent_streams: 10_u32, initial_window_size: 65_535_u32, max_header_list_size: 32_768_u32),
      65_535, target_options)
    connection.on_stream = ->(stream : HTTP2::Stream) do
      serve(stream)
  rescue HTTP2::Error | IO::Error
  rescue e
    errors.send(e) rescue nil
    end
    exercise(connection, peer, input, random, errors, preface: false)
  end

  # Feeds *input* (server to client traffic) to a client connection that
  # made *requests*.
  def self.client_target(input : Bytes, requests : Array(Request), random : Random) : Nil
    errors = Channel(Exception).new(64)
    peer, client_io = UNIXSocket.pair
    connection = HTTP2::Connection.new(client_io, HTTP2::Connection::Role::Client,
      HTTP2::Client.default_settings, 65_535, target_options)
    results = run_requests(connection, requests, wait: false)
    exercise(connection, peer, input, random, errors, preface: true) do
      requests.size.times do
        select
        when error = results.receive
          raise Failure.new("Unexpected exception in request: #{error.inspect_with_backtrace}") if error
        when timeout(2.seconds)
          raise Failure.new("Request did not terminate after the connection closed")
        end
      end
    end
  end

  private def self.exercise(connection, peer : UNIXSocket, input : Bytes, random : Random,
                            errors : Channel(Exception), preface : Bool, &) : Nil
    fibers_before = http2_fibers
    output_error = Channel(Exception?).new(1)
    done = Channel(Nil).new(1)
    chunks = chunk_sizes(input.size, random)
    spawn(name: "fuzz-connection") do
      connection.run
    ensure
      done.send(nil)
    end
    spawn_peer("fuzz-feed") do
      offset = 0
      chunks.each do |size|
        peer.write(input[offset, size])
        peer.flush
        offset += size
        Fiber.yield
      end
      # Give handlers a moment to respond before the peer goes away.
      settle = Time.instant + SETTLE_TIME
      while connection.running_handlers > 0 && Time.instant < settle
        sleep 1.millisecond
      end
      peer.close_write
    rescue IO::Error
    end
    spawn_peer("fuzz-drain") do
      output_error.send(validate_output(peer, preface))
    ensure
      # Closed by the fiber that waits on it (see `HTTP2::Connection#serialize_io?`).
      peer.close rescue nil
    end

    select
    when done.receive
    when timeout(ITERATION_TIMEOUT)
      shutdown(peer)
      raise Failure.new("Connection did not terminate within #{ITERATION_TIMEOUT}")
    end

    # Unexpected exceptions while processing frames close the connection
    # with a locally generated INTERNAL_ERROR.
    if (error = connection.close_error) && error.message.to_s.starts_with?("Connection error: INTERNAL_ERROR")
      raise Failure.new("Unexpected internal error: #{error.message}")
    end
    raise Failure.new("#{connection.active_streams} streams leaked") unless connection.active_streams == 0
    yield
    select
    when error = output_error.receive
      raise Failure.new("Malformed output: #{error.inspect_with_backtrace}") if error
    when timeout(2.seconds)
      raise Failure.new("Output did not end")
    end
    deadline = Time.instant + 2.seconds
    until connection.running_handlers == 0 && (leaked = new_http2_fibers(fibers_before)).empty?
      if Time.instant > deadline
        raise Failure.new("Leaked #{connection.running_handlers} handlers / fibers #{leaked.try(&.map(&.name))}")
      end
      sleep 1.millisecond
    end
    select
    when error = errors.receive
      raise Failure.new("Unexpected exception in handler: #{error.inspect_with_backtrace}")
    else
    end
  ensure
    shutdown(peer)
  end

  # Ends both directions without closing the socket under the feeding and
  # draining fibers.
  private def self.shutdown(peer : UNIXSocket) : Nil
    peer.close_read rescue nil
    peer.close_write rescue nil
  end

  # Spawns the peer's fibers. The draining fiber closes the socket itself:
  # closing a socket while a fiber on another thread starts waiting on it
  # can corrupt Crystal 1.19's event loop with execution contexts.
  private def self.spawn_peer(name : String, &block : ->) : Nil
    spawn(name: name, &block)
  end

  private def self.exercise(connection, peer, input, random, errors, preface : Bool) : Nil
    exercise(connection, peer, input, random, errors, preface) { }
  end

  private def self.chunk_sizes(total : Int32, random : Random) : Array(Int32)
    sizes = [] of Int32
    remaining = total
    while remaining > 0
      size = case random.rand(4)
             when 0 then 1 + random.rand(8)
             when 1 then remaining
             else        1 + random.rand(4096)
             end
      size = Math.min(size, remaining)
      sizes << size
      remaining -= size
    end
    sizes
  end

  # Reads everything the connection under test sent and checks that it is
  # well formed: valid frames whose header blocks decode.
  private def self.validate_output(io : IO, preface : Bool) : Exception?
    if preface
      bytes = Bytes.new(HTTP2::Connection::CLIENT_PREFACE.size)
      io.read_fully(bytes)
      return Failure.new("Invalid preface") unless bytes == HTTP2::Connection::CLIENT_PREFACE
    end
    decoder = HTTP2::HPACK::Decoder.new(4096, Int32::MAX)
    block = nil
    while frame = HTTP2::Frame.read(io, HTTP2::MAX_ALLOWED_FRAME_SIZE)
      case frame
      when HTTP2::HeadersFrame
        return Failure.new("HEADERS inside a header block") if block
        block = IO::Memory.new
        block.write(frame.fragment)
      when HTTP2::ContinuationFrame
        return Failure.new("CONTINUATION without HEADERS") unless block
        block.write(frame.fragment)
      else
        return Failure.new("#{frame.class} inside a header block") if block
      end
      if block && (frame.as?(HTTP2::HeadersFrame).try(&.end_headers?) || frame.as?(HTTP2::ContinuationFrame).try(&.end_headers?))
        decoder.decode(block.to_slice)
        block = nil
      end
    end
    nil
  rescue IO::EOFError | IO::Error
    # The transport may be shut down while a frame is being written.
    nil
  rescue e
    e
  end

  # --- Runner ---

  TARGETS = %w(frame hpack server client)

  # Inputs and helpers of one fuzz campaign.
  class Campaign
    getter iterations = 0
    getter failures = [] of {String, Bytes, String}

    @captures : Array(Capture)
    @server_corpus : Array(Bytes)
    @client_corpus : Array(Bytes)
    @frame_corpus : Array(Bytes)
    @hpack_corpus : Array(Bytes)

    def initialize(@seed : UInt64, @crash_dir : String? = nil, @log : IO? = nil)
      @random = Random.new(@seed)
      @captures = Fuzz.capture_all
      @server_corpus = @captures.map(&.client_bytes)
      @client_corpus = @captures.map(&.server_bytes)
      @frame_corpus = @client_corpus + @server_corpus.map { |bytes| bytes[HTTP2::Connection::CLIENT_PREFACE.size..] }
      @hpack_corpus = Fuzz.hpack_corpus
    end

    def corpus(target : String) : Array(Bytes)
      case target
      when "frame"  then @frame_corpus
      when "hpack"  then @hpack_corpus
      when "server" then @server_corpus
      else               @client_corpus
      end
    end

    # Runs *target* until *iterations* inputs were tried or *duration*
    # elapsed.
    def run(target : String, iterations : Int32? = nil, duration : Time::Span? = nil) : Nil
      corpus = corpus(target)
      mutator = Mutator.new(@random, corpus)
      deadline = duration.try { |d| Time.instant + d }
      count = 0
      loop do
        break if iterations && count >= iterations
        break if deadline && Time.instant >= deadline
        index = @random.rand(corpus.size)
        # Unmutated seeds are part of the run, too.
        input = count < corpus.size ? corpus[count] : mutator.mutate(corpus[index])
        input_random = Random.new(@random.next_u)
        Fuzz.current_input = {target, input}
        Fuzz.tick
        begin
          execute(target, input, index, input_random)
        rescue e : Failure
          record(target, input, e)
        end
        count += 1
        @iterations += 1
      end
    end

    # Runs a single input against *target*.
    def execute(target : String, input : Bytes, index : Int32 = 0, random : Random = Random.new(0)) : Nil
      case target
      when "frame"
        Fuzz.frame_target(input)
        Fuzz.frame_target(input, HTTP2::MAX_ALLOWED_FRAME_SIZE)
      when "hpack"
        Fuzz.hpack_target(input)
        Fuzz.hpack_target(input, 64, 256)
      when "server"
        Fuzz.server_target(input, random)
      when "client"
        Fuzz.client_target(input, @captures[index].requests, random)
      else
        raise ArgumentError.new("Unknown target #{target}")
      end
    rescue e : Failure
      raise e
    rescue e
      raise Failure.new("Unexpected #{e.class}: #{e.message}\n#{e.backtrace?.try(&.join("\n"))}")
    end

    private def record(target : String, input : Bytes, error : Exception) : Nil
      @failures << {target, input, error.message.to_s}
      @log.try &.puts "[#{target}] FAILURE: #{error.message.to_s.lines.first?}"
      if dir = @crash_dir
        Dir.mkdir_p(dir)
        name = "#{target}-#{Digest::SHA1.hexdigest(input)[0, 16]}"
        File.write(File.join(dir, "#{name}.bin"), input)
        File.write(File.join(dir, "#{name}.txt"), error.message.to_s)
      end
    end
  end

  class_property current_input : {String, Bytes}? = nil
  # Number of inputs started so far (read by the hang watchdog).
  @@progress = Atomic(Int64).new(0)

  def self.tick : Nil
    @@progress.add(1)
  end

  def self.progress : Int64
    @@progress.get
  end
end
