require "http/headers"
require "http/status"
require "openssl"
require "log"
require "./http2/errors"
require "./http2/frame"
require "./http2/settings"
require "./http2/options"
require "./http2/hpack"
require "./http2/condition"
require "./http2/header_validation"
require "./http2/stream"
require "./http2/metrics"
require "./http2/connection"
require "./http2/http1"

# A pure Crystal implementation of HTTP/2 (RFC 9113) and HPACK (RFC 7541).
module HTTP2
  VERSION = "0.1.0"
end

require "./http2/server"
require "./http2/client"
