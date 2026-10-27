# grpc.cr

A pure Crystal implementation of [gRPC](https://grpc.io), built from the ground up:

- **HTTP/2** (`HTTP2`): RFC 9113 + HPACK (RFC 7541), client and server, flow control,
  multiplexing, cleartext (prior knowledge), h2c upgrade, HTTP/1.1 on the same port, and
  TLS with ALPN. Keepalive, connection age/idle limits, two-phase graceful shutdown and
  DoS protections (rapid reset, control-frame floods). Passes the full
  [h2spec](https://github.com/summerwind/h2spec) conformance suite, including strict mode
  (147/147).
- **Protocol Buffers** (`Protobuf`): binary wire format and proto3 JSON mapping, a macro
  DSL for messages, proto2/editions semantics (defaults, closed enums, groups, extensions,
  required fields, MessageSet), bundled well-known types, a type registry with embedded
  descriptors, and code generation from `.proto` files (proto2, proto3 and editions
  2023–2026) either at compile time with `GRPC.import_proto` (a pure Crystal `.proto`
  parser, no `protoc` needed) or with `protoc-gen-crystal`, a `protoc` plugin. Both share
  one generator and produce identical code. Passes all 5,649 binary and JSON tests of
  protobuf's official conformance suite (proto2, proto3 and editions, recommended tests
  included).
- **gRPC** (`GRPC`): all four call kinds with metadata, deadlines, cancellation,
  compression (gzip/deflate), interceptors and message size limits.
  - Client: name resolution (`dns`, `ipv4`, `ipv6`, `unix`, custom resolvers),
    load balancing (`pick_first`, `round_robin`, custom policies), connectivity states and
    connection backoff, wait-for-ready, service config, retries and hedging (gRFC A6),
    TLS/mTLS channel credentials and per-call credentials, keepalive.
  - Server: gRPC-Web and gRPC-Web-text (HTTP/2 and HTTP/1.1, with CORS), keepalive
    enforcement and connection management, reflection (v1 and v1alpha), channelz,
    health checking, stats hooks with a metrics collector, generic handlers for proxies.
  - Interoperates with the official implementations: the standard gRPC interop test
    cases pass in both directions against gRPC C-core (`grpcio`) and grpc-go, over
    cleartext and TLS, and grpc-go's soak tests pass.

No C dependencies beyond Crystal's standard library (OpenSSL for TLS, zlib for compression).

## Installation

Add the shard to your `shard.yml`:

```yaml
dependencies:
  grpc:
    github: dev-transparent/grpc
```

Build the code generator and put it on your `PATH` (or pass it with `--plugin`):

```sh
crystal build lib/grpc/src/protoc-gen-crystal.cr -o bin/protoc-gen-crystal
```

Requires Crystal >= 1.19 and `protoc` for code generation.

## Quick start

Define a service:

```protobuf
syntax = "proto3";
package helloworld;

service Greeter {
  rpc SayHello (HelloRequest) returns (HelloReply);
  rpc SayHelloStream (stream HelloRequest) returns (stream HelloReply);
}

message HelloRequest { string name = 1; }
message HelloReply { string message = 1; }
```

Then either import it at compile time (no extra tooling) or generate code with `protoc`.

### Option 1: `GRPC.import_proto` (compile time)

```crystal
require "grpc"

GRPC.import_proto "proto/helloworld.proto"
```

The macro parses the `.proto` file (and its imports) with a pure Crystal parser while
your program compiles, and defines the messages, `Helloworld::Greeter::Service` and
`Helloworld::Greeter::Client` exactly as `protoc-gen-crystal` would. No `protoc` needed.

- Paths are relative to the calling file. Extra arguments are include paths for imports:
  `GRPC.import_proto "proto/app/v1/api.proto", "proto"`. The bundled well-known types
  (`google/protobuf/*.proto`) are always importable.
- Imported files are generated too, and a file imported through several `import_proto`
  calls is only defined once.
- Errors in `.proto` files are reported at the `import_proto` call with the `.proto`
  file, line and column.
- `Protobuf.import_proto` does the same for message-only code (no services).
- Call it at the top level of a file.
- To see the generated code, pass `dump: true`, or run the runner directly:
  `crystal run lib/grpc/src/protobuf/compiler/import_runner.cr -- [-I DIR] file.proto`.

Supports proto2, proto3 and editions (2023/2024).

### Option 2: `protoc-gen-crystal`

For `protoc`/`buf` workflows or checked-in generated code, generate Crystal code:

```sh
protoc --plugin=protoc-gen-crystal=bin/protoc-gen-crystal --crystal_out=src/proto helloworld.proto
```

This produces `helloworld.pb.cr` (messages) and `helloworld_grpc.pb.cr` (service base
class and client stub), with the same definitions `GRPC.import_proto` produces: both
front ends feed one `Protobuf::Compiler::Generator`. Generated files do not require the runtime themselves; require
`"grpc"` (or just `"grpc/protobuf"` for message-only code) first.

### Server

```crystal
require "grpc"
require "./proto/helloworld_grpc.pb"

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
server.bind("0.0.0.0:50051")
server.listen
```

### Client

```crystal
require "grpc"
require "./proto/helloworld_grpc.pb"

client = Helloworld::Greeter::Client.new("localhost:50051", default_timeout: 5.seconds)

reply = client.say_hello(Helloworld::HelloRequest.new(name: "World"))
puts reply.message # => "Hello World"

call = client.say_hello_stream
spawn do
  %w(Ada Grace).each { |name| call.send(Helloworld::HelloRequest.new(name: name)) }
  call.close_send
end
call.each { |reply| puts reply.message }
```

See [`examples/helloworld`](examples/helloworld) for a runnable version.

## gRPC guide

### Service methods

For each RPC the generated `Service` base class declares an abstract method:

| RPC kind          | Server method signature                          | Return value      |
|-------------------|--------------------------------------------------|-------------------|
| unary             | `name(request, context)`                         | response message  |
| server streaming  | `name(request, responses, context)`              | ignored           |
| client streaming  | `name(requests, context)`                        | response message  |
| bidi streaming    | `name(requests, responses, context)`             | ignored           |

`requests` is a `GRPC::RequestStream(T)` (an `Iterator(T)`; also `#receive?`) and
`responses` a `GRPC::ResponseStream(T)` (`#send` / `#<<`).

Raise `GRPC::Error.new(code, message)` to fail a call with a status; any other exception
becomes `UNKNOWN`. `GRPC::StatusCode` members are autocast from symbols:
`GRPC::Error.new(:not_found, "no such user")`.

### Client stubs

| RPC kind          | Client method                                             |
|-------------------|-----------------------------------------------------------|
| unary             | `name(request) : Response` and `name_call(request) : GRPC::UnaryCall(Response)` |
| server streaming  | `name(request) : GRPC::ServerStreamingCall(Response)` (an `Iterator`) |
| client streaming  | `name : GRPC::ClientStreamingCall(Request, Response)`, or `name { \|call\| call << req }` returning the response |
| bidi streaming    | `name : GRPC::BidiStreamingCall(Request, Response)`       |

Every method accepts `metadata:` (`GRPC::Metadata` or `Hash(String, String)`) and
`deadline:` (a `Time::Span` timeout or an absolute `Time`). Failed calls raise
`GRPC::Error`, with `#code`, `#status` and trailing `#metadata`. Streaming calls expose
`#headers`, `#trailers`, `#status` and `#cancel`.

They also accept `options:` (a `GRPC::CallOptions` with `wait_for_ready`,
`call_credentials`, `compression`, `timeout` and message size limits), and
`client.with_options(...)` returns a stub sharing the channel with different defaults.

### Channels

A `GRPC::Channel` resolves its target, load balances over the resolved addresses and
multiplexes calls over HTTP/2 connections, reconnecting with exponential backoff.
Several stubs can share a channel:

```crystal
channel = GRPC::Channel.new("localhost:50051")                  # cleartext (DNS)
channel = GRPC::Channel.new("dns:///api.internal:443",
  credentials: GRPC::ChannelCredentials.tls)                    # TLS with system roots
channel = GRPC::Channel.new("ipv4:10.0.0.1:50051,10.0.0.2:50051",
  load_balancing_policy: GRPC::RoundRobinConfig.new)
channel = GRPC::Channel.new("unix:/tmp/app.sock")               # UNIX socket
client = Helloworld::Greeter::Client.new(channel, metadata: {"x-team" => "a"})

channel.state                       # => GRPC::ConnectivityState::Ready
channel.wait_for_state_change(state, 5.seconds)
channel.shutdown
```

Targets follow gRPC's naming spec (`dns:`, `ipv4:`, `ipv6:`, `unix:`, `passthrough:`, or
your own `GRPC::Resolver::Provider` registered with `GRPC::Resolver.register`). Custom
load balancing policies implement `GRPC::LoadBalancer`. Other channel options include
`backoff:` (`GRPC::ConnectionBackoff`), `idle_timeout:`, `keepalive:`
(`GRPC::KeepaliveOptions`), `stats_handlers:` and retry buffer limits.

### Service config, retries and hedging

`GRPC::ServiceConfig` is a typed, validated, `JSON::Serializable` object in gRPC's
standard [service config](https://github.com/grpc/grpc/blob/master/doc/service_config.md)
format, so the same file works with other gRPC implementations. Build it in code:

```crystal
config = GRPC::ServiceConfig.new(
  load_balancing_config: [GRPC::RoundRobinConfig.new] of GRPC::LoadBalancingConfig,
  method_configs: [
    GRPC::ServiceConfig::MethodConfig.new(
      names: [GRPC::ServiceConfig::MethodName.new("helloworld.Greeter")],
      timeout: 2.seconds,
      wait_for_ready: true,
      retry_policy: GRPC::ServiceConfig::RetryPolicy.new(
        max_attempts: 4, initial_backoff: 100.milliseconds, max_backoff: 1.second,
        backoff_multiplier: 2.0, retryable_status_codes: Set{GRPC::StatusCode::Unavailable})),
  ],
  retry_throttling: GRPC::ServiceConfig::RetryThrottling.new(max_tokens: 10, token_ratio: 0.1))
channel = GRPC::Channel.new("dns:///api:50051", service_config: config)
```

or load it from a file (`GRPC::ServiceConfig.load("service_config.json")`, or `.parse(json)`):

```json
{
  "loadBalancingConfig": [{"round_robin": {}}],
  "methodConfig": [{
    "name": [{"service": "helloworld.Greeter"}],
    "timeout": "2s",
    "waitForReady": true,
    "retryPolicy": {
      "maxAttempts": 4, "initialBackoff": "0.1s", "maxBackoff": "1s",
      "backoffMultiplier": 2, "retryableStatusCodes": ["UNAVAILABLE"]
    }
  }],
  "retryThrottling": {"maxTokens": 10, "tokenRatio": 0.1}
}
```

Durations are `Time::Span`, status codes are `GRPC::StatusCode`, and the deprecated
`loadBalancingPolicy` is the `ServiceConfig::LoadBalancingPolicy` enum. Load balancing
configs are typed per policy (`GRPC::PickFirstConfig`, `GRPC::RoundRobinConfig`); custom
policies parse their own `GRPC::LoadBalancingConfig` subclass in
`LoadBalancer::Provider#parse_config`, and entries for policies that aren't registered
are skipped as gRPC requires. Invalid configs raise `GRPC::ServiceConfig::Error`;
`#to_json` writes the config back in the standard format.

Retries and hedging follow gRFC A6: buffered requests are replayed on new attempts until
the call commits, server pushback (`grpc-retry-pushback-ms`) is honoured, and streams
refused by a server (REFUSED_STREAM, GOAWAY) are retried transparently.

### Credentials

```crystal
tls = GRPC::ChannelCredentials.tls(ca_file: "ca.pem", cert_file: "client.pem",
  key_file: "client.key", server_name_override: "api.internal")      # mTLS
token = GRPC::CallCredentials.bearer("secret")                         # per call
channel = GRPC::Channel.new("dns:///api:443", credentials: tls.with_call_credentials(token))
client.say_hello(request, options: GRPC::CallOptions.new(call_credentials: token))
```

Call credentials are only sent over secure channels unless created with
`allow_insecure: true`.

### Metadata

```crystal
# Client
call = client.say_hello_call(request, metadata: {"x-request-id" => "42"})
call.response
call.headers["x-served-by"]?
call.trailers

# Server
def say_hello(request, context)
  context.metadata["x-request-id"]?            # incoming
  context.response_metadata["x-served-by"] = "a" # sent as headers
  context.trailers["x-cost-bin"] = Bytes[1, 2]  # -bin keys carry binary values
  ...
end
```

### Deadlines and cancellation

Clients send deadlines as `grpc-timeout`; when it expires the call fails with
`DEADLINE_EXCEEDED` and the stream is reset. On the server, `context.time_remaining`,
`context.deadline_exceeded?`, `context.cancelled?`, `context.on_cancel { }` and
`context.check_cancelled!` let handlers stop work early.

### Compression

```crystal
client = Helloworld::Greeter::Client.new(channel, compression: "gzip") # requests
server = GRPC::Server.new(compression: "gzip")                         # responses by default
context.compression = "deflate"                                        # per call
```

### Interceptors

```crystal
server.intercept do |context, continuation|
  raise GRPC::Error.new(:unauthenticated) unless context.metadata["authorization"]? == "Bearer secret"
  continuation.call
end

client.intercept do |info, continuation|
  info.metadata["authorization"] = "Bearer secret"
  continuation.call
end
```

Subclass `GRPC::ServerInterceptor` / `GRPC::ClientInterceptor` for reusable interceptors.

### TLS

```crystal
context = OpenSSL::SSL::Context::Server.new
context.certificate_chain = "server.crt"
context.private_key = "server.key"
server.bind_tls("0.0.0.0", 50051, context)

client = Helloworld::Greeter::Client.new("https://localhost:50051")
```

### Health checking

```crystal
require "grpc/health"

health = GRPC::HealthService.new
server.handle(health)
health.set_status("helloworld.Greeter", :serving)
```

### Reflection and channelz

```crystal
require "grpc/reflection"
require "grpc/channelz"

GRPC::Reflection.enable(server)   # grpc.reflection.v1 and v1alpha (grpcurl, Postman, ...)
server.handle(GRPC::Channelz.new) # live channels, subchannels, servers and sockets (grpcdebug)
```

### gRPC-Web

Servers accept gRPC-Web (`application/grpc-web`) and gRPC-Web-text
(`application/grpc-web-text`) requests out of the box, over HTTP/2 and over HTTP/1.1 on
the same port, so browsers can call them without a proxy. Enable CORS for browser
origins:

```crystal
server = GRPC::Server.new(cors: GRPC::CORS.new(["https://app.example.com"],
  extra_exposed_headers: ["x-request-id"]))
```

Pass `web: false` to disable gRPC-Web, or `http1: false` to only disable HTTP/1.1.

### Keepalive and connection management

```crystal
options = HTTP2::Server.default_options      # gRPC's defaults
options.max_connection_age = 30.minutes       # ask clients to reconnect (load rebalancing)
options.max_connection_age_grace = 1.minute
options.max_connection_idle = 5.minutes
options.min_ping_interval = 1.minute          # keepalive enforcement policy
server = GRPC::Server.new(connection_options: options)

channel = GRPC::Channel.new("api:50051", keepalive: GRPC::KeepaliveOptions.new(30.seconds, 10.seconds))
```

`HTTP2::ConnectionOptions` also holds the DoS limits (rapid reset, PING/SETTINGS/empty
frame floods, queued control frames, running handlers) with conservative defaults.

### Observability

```crystal
metrics = GRPC::MetricsCollector.new          # per-method counts, bytes, latency histograms
server = GRPC::Server.new(stats_handlers: [metrics] of GRPC::StatsHandler)
channel = GRPC::Channel.new("api:50051", stats_handlers: [MyTracer.new] of GRPC::StatsHandler)
metrics.snapshot["/helloworld.Greeter/SayHello"].completed[GRPC::StatusCode::Ok]
```

A `GRPC::StatsHandler` receives `Begin`, `InHeader`, `OutHeader`, `InPayload`,
`OutPayload`, `Trailer` and `End` events for every client and server call, the building
block for metrics, tracing and logging integrations.

### Generic handlers

`server.handle_unknown { |call| ... }` receives calls to unregistered methods as raw
bytes (`call.read_raw_message` / `call.send_raw_message`), e.g. to build a proxy.

## Protocol Buffers

Generated messages are plain Crystal classes using the `Protobuf::Message` DSL, which can
also be written by hand:

```crystal
class Person
  include Protobuf::Message

  field name : String, 1
  field id : Int32, 2, type: :sint32
  field email : String, 3, optional: true # String?, with presence
  field address : Address, 4              # messages are always nilable
  repeated tags : String, 5
  map scores : Hash(String, Int64), 6

  oneof contact do
    field phone : String, 7
    field pager : String, 8
  end
end

person = Person.new(name: "Ada", tags: ["math"])
bytes = person.to_protobuf
Person.from_protobuf(bytes) == person # => true
person.contact_case                   # => nil
person.to_json                        # => %({"name":"Ada","tags":["math"]})
```

- Scalar types map to `String`, `Bytes`, `Bool`, `Int32`, `Int64`, `UInt32`, `UInt64`,
  `Float32`, `Float64`; use `type:` for `sint32`, `sint64`, `fixed32`, `fixed64`,
  `sfixed32`, `sfixed64` and `type: :group` for group / `DELIMITED` encoded messages.
  Enums are Crystal enums.
- Proto packages become modules (`foo.bar` → `Foo::Bar`); nested types become nested
  classes; field names that clash with Crystal keywords or runtime methods get a trailing
  underscore (the proto name is kept for JSON with `proto_name:`).
- Unknown fields are preserved and re-serialized; parsing follows protobuf merge semantics
  and rejects malformed data with `Protobuf::DecodeError` (recursion limit 100).
- Well-known types (`Google::Protobuf::Timestamp`, `Any`, `Struct`, wrappers, ...) and
  `descriptor.proto` are bundled, with helpers such as `Any.pack` / `#unpack`,
  `Timestamp.from_time` / `#to_time` and `Duration.from_span` / `#to_span`.

### JSON

Every message supports the [proto3 JSON mapping](https://protobuf.dev/programming-guides/json/):

```crystal
json = message.to_json                                  # lowerCamelCase names
json = message.to_json(emit_defaults: true,             # print fields without presence
  preserve_proto_field_names: true, enums_as_ints: true, indent: "  ")
message = Foo.from_json(json)
message = Foo.from_json(json, ignore_unknown_fields: true)
message.merge_from_json(more_json)
```

Messages also implement `to_json(JSON::Builder)` and `.new(JSON::PullParser)`, so they
work inside `[...].to_json`, `Array(Foo).from_json`, `JSON::Serializable` types, etc.
64-bit integers are strings, bytes are base64 (standard or URL-safe, padding optional),
floats accept `"NaN"`/`"Infinity"`, enums use names (numbers accepted), and well-known
types use their special forms (`Any` with `@type` through the registry, RFC 3339
`Timestamp`, `"1.5s"` `Duration`, `FieldMask`, `Struct`/`Value`/`ListValue`, wrappers,
`NullValue`). Invalid input raises `Protobuf::JSON::ParseError` (duplicate fields, several
oneof members, out-of-range numbers, ...); values that cannot be printed (an out-of-range
`Timestamp`, an `Any` of an unregistered type, invalid UTF-8 in a proto2 string) raise
`Protobuf::JSON::SerializeError`.

### proto2 and editions

- **Presence and defaults**: fields with explicit presence (proto2 `optional`/`required`,
  proto3 `optional`, editions `EXPLICIT`) are nilable, `nil` meaning "not set". Each such
  scalar field also gets `#<name>_or_default`, returning the `[default = ...]` value (or
  the zero value / first enum value) when the field is unset:

  ```crystal
  message.timeout           # => nil
  message.timeout_or_default # => 30
  ```
- **Closed enums** (proto2 enums, `features.enum_type = CLOSED`): unknown values read from
  the wire go to the unknown fields (singular, repeated, packed and map fields) instead of
  the field.
- **Groups** and editions `DELIMITED` fields are regular message fields.
- **Extensions** are constants holding `Protobuf::Extension(Extendee, ValueType)`:

  ```crystal
  message.set_extension(Pkg::MY_EXT, 5)
  message.get_extension(Pkg::MY_EXT)    # => 5
  message.has_extension?(Pkg::MY_EXT)
  message.clear_extension(Pkg::MY_EXT)
  message.extension_fields              # extensions set on the message
  ```

  Registered extensions (all generated ones, or `Protobuf::Registry.register_extension`)
  are parsed from binary and JSON (`"[pkg.my_ext]"`); others stay in the unknown fields
  and are parsed by `get_extension`. MessageSet (`message_set_wire_format`) is supported.
- **Required fields** are not enforced while parsing; check them with
  `message.missing_required_fields` (paths like `child.a`), `#required_fields_set?`,
  `#check_required_fields!` or `Foo.from_protobuf(bytes, check_required: true)`, which
  raise `Protobuf::RequiredFieldsError`.

### Registry and descriptors

Generated code registers every file with its serialized `FileDescriptorProto` (without
source info, identical for `protoc-gen-crystal` and `import_proto`), its message classes
and its extensions:

```crystal
Protobuf::Registry.message_class("google.protobuf.Duration")   # => Google::Protobuf::Duration
Protobuf::Registry.file_descriptor("helloworld.proto")         # FileDescriptorProto
Protobuf::Registry.file_descriptor_bytes("helloworld.proto")   # serialized descriptor
Protobuf::Registry.file_containing_symbol("helloworld.Greeter.SayHello")
Protobuf::Registry.file_with_dependencies("helloworld.proto")  # with transitive imports
Protobuf::Registry.services                                    # ["helloworld.Greeter"]
Protobuf::Registry.extensions_of("pkg.Options")                # / extension_numbers
Protobuf::Registry.file_containing_extension("pkg.Options", 1000)
Helloworld::HelloRequest.full_name                             # => "helloworld.HelloRequest"
Helloworld::HelloRequest.descriptor                            # DescriptorProto
```

Message classes can be used dynamically through `Protobuf::MessageClass`
(`klass.from_protobuf(bytes)`, `klass.from_json(json)`, `klass.new_message`).

### Plugin options

`--crystal_opt=grpc=false` skips service files; `--crystal_opt=require=grpc` adds
`require "grpc"` to every generated file; `--crystal_opt=experimental_editions=true`
accepts protoc's in-development edition `UNSTABLE`.

### `.proto` parser

The parser behind `import_proto` reproduces protoc's descriptors byte for byte (checked
against protoc on the spec protos and protobuf's own unittest protos): options of every
kind including custom options with aggregate (text format) values, `[default = ...]`
normalization, json names, extension and reserved ranges, source-retention stripping,
edition 2024 `export`/`local` and `import option`, edition 2026 and `UNSTABLE`. The
language feature protos (`google/protobuf/cpp_features.proto`, ...) are bundled for
imports.

### Limitations

- Text format is not implemented (the conformance testee reports it as skipped).
- Map entries containing unknown fields keep the entry and drop those fields (as C++
  does; upb keeps such entries as unknown fields).
- `Any` type URLs and JSON resolve types only through the registry (types compiled into
  the program).
- Extension values have no `[default = ...]` accessor.
- Code generated with `protoc-gen-crystal` and `import_proto` for the same file must not be
  mixed in one program.

## HTTP/2

The HTTP/2 layer is usable on its own:

```crystal
require "grpc/http2"

server = HTTP2::Server.new do |context|
  context.response.headers["content-type"] = "text/plain"
  context.response.print "Hello #{context.request.path}"
end
server.bind_tcp("127.0.0.1", 8080)
server.listen

client = HTTP2::Client.new("127.0.0.1", 8080)
client.get("/").body_text # => "Hello /"
```

Set `server.http1_handler` (any `HTTP::Handler`) to also serve HTTP/1.1 on the same port
(and accept h2c upgrades); `HTTP2::ConnectionOptions` configures keepalive, connection
lifetime and abuse limits for both servers and clients.

## Development

```sh
crystal spec                                  # all specs
crystal spec -Dpreview_mt -Dexecution_context # the same, multi-threaded
script/h2spec.sh -S                           # h2spec conformance (strict)
PYTHON=/path/to/venv/bin/python script/interop.sh  # interop vs. grpcio and grpc-go
script/soak.sh                                # grpc-go soak tests (rpc_soak, channel_soak)
crystal run --release bench/soak.cr -- --duration=300  # in-process soak (leaks, heap)
script/fuzz.sh all 10m                        # HTTP/2 + HPACK fuzzing
DETERMINISM=1 script/sim.sh 1000              # deterministic simulation campaign
script/generate_well_known_types.sh           # regenerate bundled protos (self-hosting)
script/generate_spec_protos.sh                # regenerate protobuf spec fixtures
script/generate_grpc_spec_protos.sh           # regenerate gRPC spec fixtures
script/conformance.sh                         # protobuf conformance suite (builds the runner)
script/fuzz_protobuf.sh 150                   # protobuf fuzzing, 150 s per target
```

### Deterministic simulation testing

`spec/sim` runs the real stack (HTTP/2, protobuf, servers, channels with load balancing,
retries, hedging and keepalive) inside a deterministic simulation, in the style of
FoundationDB and TigerBeetle:

- **Virtual time.** A simulated event loop replaces Crystal's: `Time.instant`,
  `Time.utc`, `sleep` and `select ... timeout` use a virtual clock that jumps to the next
  timer whenever every fiber is blocked. Minutes of traffic run in about a second.
- **Simulated network.** In-memory TCP connections with seeded latency, jitter,
  bandwidth, random segment splitting and a flow-control window.
- **Faults.** Partitions (one- or two-way), connection resets, server crashes and
  restarts, graceful drains, latency spikes, resolver changes, tiny segments and windows.
- **Seeded randomness.** `Random::Secure` and the default generators are seeded, and the
  single-threaded scheduler makes every run a pure function of its seed.
- **Oracle.** Each run checks:
  - responses are correct, with in-order, exactly-once delivery for streams
  - requests execute at most once unless a retry policy allows more
  - only legitimate status codes are returned (stricter without faults)
  - deadlines are honoured, every call completes, and bulk transfers succeed without faults
  - nothing leaks at shutdown: connections, server calls or fibers
- **Determinism self-check.** Every run prints a hash of its event trace; replaying a seed
  must reproduce it exactly.

```sh
crystal build spec/sim/sim.cr -o bin/sim
bin/sim --seed=1234 --verbose         # replay one seed with its event trace
script/sim.sh 1000                    # 1000 seeds in parallel
DETERMINISM=1 script/sim.sh 200       # also replay every seed and compare traces
NO_FAULTS=1 script/sim.sh 200         # without faults (stricter oracle)
```

Seeds reproduce a run for a given version of the harness; changing the workload or
the stack changes what a seed does.

Generated `*.pb.cr` files are checked in and verified against the generator by the
specs, so don't run `crystal tool format` over them.

The interop script runs the official gRPC interop test cases in ten combinations:
Crystal↔Crystal, Crystal↔grpcio (gRPC C-core) and Crystal↔grpc-go in both directions,
each over cleartext and TLS (with gRPC's test certificates in `spec/interop/certs`). It
needs a Python with `grpcio` and `grpcio-tools`, and the grpc-go interop binaries
(`go install google.golang.org/grpc/interop/{client,server}@latest`); missing ones are
skipped.

What is verified, and how:

| Area | Verification |
|------|--------------|
| HTTP/2 | h2spec strict 147/147; specs for every frame, HPACK (RFC 7541 Appendix C), stream state, flow control, keepalive, shutdown and abuse rule; fault-injection network tests; fuzzing of frames, HPACK and both connection roles |
| Protocol Buffers | protobuf's official conformance suite (5,649 binary and JSON tests, 0 failures); golden tests against `protoc`; randomized differential tests against Python's protobuf; fuzzing of the decoder, JSON and `.proto` parser; parser output identical to `protoc`'s |
| gRPC | interop matrix above; grpc-go `rpc_soak` (20,000 iterations, 16 threads) and `channel_soak`; reflection checked with grpcio-reflection and grpcurl; channelz with grpcdebug; gRPC-Web with the sonora client; in-process soak with leak and heap checks |
| Concurrency | the whole suite also runs on a multi-threaded execution context |
| Whole system | deterministic simulation: thousands of seeded runs of servers and clients under randomized workloads and faults, checked by an oracle and replayable from their seed |

## License

MIT
