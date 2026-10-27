require "log"
require "base64"
require "./http2"
require "./protobuf"

# A pure Crystal implementation of gRPC over HTTP/2.
module GRPC
  VERSION = "0.1.0"

  Log = ::Log.for("grpc")
end

require "./grpc/status"
require "./grpc/metadata"
require "./grpc/codec"
require "./grpc/stats"
require "./grpc/channelz_registry"
require "./grpc/cors"
require "./grpc/server_transport"
require "./grpc/server_context"
require "./grpc/server"
require "./grpc/client_call"
require "./grpc/client"
require "./grpc/import_proto"
