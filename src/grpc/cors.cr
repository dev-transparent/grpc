module GRPC
  # Cross-origin resource sharing policy for gRPC-Web requests made by
  # browsers.
  #
  # ```
  # server = GRPC::Server.new(cors: GRPC::CORS.new(["https://app.example.com"]))
  # server = GRPC::Server.new(cors: GRPC::CORS.allow_all)
  # ```
  class CORS
    # Request headers gRPC-Web clients send.
    DEFAULT_ALLOWED_HEADERS = %w(content-type x-grpc-web x-user-agent grpc-timeout grpc-encoding grpc-accept-encoding authorization)
    # Response headers browsers may read.
    DEFAULT_EXPOSED_HEADERS = %w(grpc-status grpc-message grpc-status-details-bin grpc-encoding grpc-accept-encoding)

    # Allowed origins; `["*"]` allows any origin.
    getter origins : Array(String)
    getter? allow_credentials : Bool
    getter max_age : Time::Span
    # Additional request headers to allow (e.g. custom metadata keys). When
    # `nil`, the headers requested in a preflight are echoed back.
    getter extra_allowed_headers : Array(String)?
    # Additional response headers to expose (e.g. custom metadata keys).
    getter extra_exposed_headers : Array(String)

    def initialize(@origins : Array(String), *, @allow_credentials : Bool = false, @max_age : Time::Span = 24.hours,
                   @extra_allowed_headers : Array(String)? = nil, @extra_exposed_headers : Array(String) = [] of String)
    end

    # A policy allowing every origin.
    def self.allow_all(**options) : CORS
      new(["*"], **options)
    end

    def allows?(origin : String) : Bool
      @origins.includes?("*") || @origins.includes?(origin)
    end

    # Headers added to responses for requests from *origin*.
    def response_headers(origin : String) : Array({String, String})
      headers = [{"access-control-allow-origin", @origins.includes?("*") && !@allow_credentials ? "*" : origin}]
      headers << {"vary", "origin"} unless headers[0][1] == "*"
      headers << {"access-control-allow-credentials", "true"} if @allow_credentials
      headers << {"access-control-expose-headers", (DEFAULT_EXPOSED_HEADERS + @extra_exposed_headers).join(", ")}
      headers
    end

    # The value of `access-control-allow-headers` for a preflight.
    def allowed_headers(requested : String?) : String
      if extra = @extra_allowed_headers
        (DEFAULT_ALLOWED_HEADERS + extra).join(", ")
      else
        requested || DEFAULT_ALLOWED_HEADERS.join(", ")
      end
    end
  end
end
