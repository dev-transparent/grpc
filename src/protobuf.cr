require "./protobuf/wire"
require "./protobuf/message"
require "./protobuf/extension"
require "./protobuf/registry"
require "./protobuf/json"
require "./protobuf/well_known_types"
require "./protobuf/json/well_known"
require "./protobuf/import_proto"

# A Protocol Buffers runtime: binary wire format encoding and decoding, the
# proto3 JSON mapping, extensions, a registry of the compiled `.proto` files
# and a macro DSL (`Protobuf::Message`) used by generated and hand-written
# messages.
module Protobuf
  VERSION = "0.1.0"
end
