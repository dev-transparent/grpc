require "openssl"

module GRPC
  # Transport security of a channel: plaintext (`.insecure`) or TLS
  # (`.tls`), optionally with a client certificate (mutual TLS).
  #
  # ```
  # # TLS verified against the system roots:
  # GRPC::Channel.new("dns:///api.example.com:443", credentials: GRPC::ChannelCredentials.tls)
  #
  # # A private CA, a client certificate and a server name override:
  # credentials = GRPC::ChannelCredentials.tls(
  #   ca_file: "ca.pem", cert_file: "client.pem", key_file: "client.key",
  #   server_name_override: "backend.internal")
  # ```
  #
  # Call credentials attached with `#with_call_credentials` are used for
  # every call on the channel.
  abstract class ChannelCredentials
    # Plaintext HTTP/2 ("h2c").
    def self.insecure : ChannelCredentials
      Insecure.new
    end

    # TLS with ALPN `h2`. Without *ca_file*/*ca_pem* the server certificate is
    # verified against the system trust store. *cert_file*/*cert_pem* and
    # *key_file*/*key_pem* configure a client certificate for mutual TLS.
    # *server_name_override* replaces the host name used for SNI and
    # certificate verification (and the default `:authority`).
    def self.tls(*, ca_file : String? = nil, ca_pem : String? = nil,
                 cert_file : String? = nil, cert_pem : String? = nil,
                 key_file : String? = nil, key_pem : String? = nil,
                 server_name_override : String? = nil, verify : Bool = true) : ChannelCredentials
      context = verify ? OpenSSL::SSL::Context::Client.new : OpenSSL::SSL::Context::Client.insecure
      TLS.with_pem_file(ca_file, ca_pem) { |path| context.ca_certificates = path }
      cert = cert_file || cert_pem
      key = key_file || key_pem
      if cert.nil? != key.nil?
        raise ArgumentError.new("A client certificate and its private key must be given together")
      end
      TLS.with_pem_file(cert_file, cert_pem) { |path| context.certificate_chain = path }
      TLS.with_pem_file(key_file, key_pem) { |path| context.private_key = path }
      TLS.new(context, server_name_override)
    end

    # TLS using a fully configured OpenSSL *context* (ALPN is set to `h2`).
    def self.tls(context : OpenSSL::SSL::Context::Client, *, server_name_override : String? = nil) : ChannelCredentials
      TLS.new(context, server_name_override)
    end

    @call_credentials : CallCredentials? = nil

    # Whether connections are encrypted and authenticated.
    abstract def secure? : Bool

    # The TLS context, for secure credentials.
    def tls_context : OpenSSL::SSL::Context::Client?
      nil
    end

    # The host name to verify the server certificate against instead of the
    # target's host.
    def server_name_override : String?
      nil
    end

    # Call credentials applied to every call on channels using these
    # credentials.
    def call_credentials : CallCredentials?
      @call_credentials
    end

    # Returns a copy of these credentials that also applies *credentials*
    # to every call (a "composite" channel credential).
    def with_call_credentials(credentials : CallCredentials) : ChannelCredentials
      copy = dup
      copy.call_credentials = (existing = @call_credentials) ? existing.compose(credentials) : credentials
      copy
    end

    protected setter call_credentials : CallCredentials?

    # Plaintext credentials.
    class Insecure < ChannelCredentials
      def secure? : Bool
        false
      end
    end

    # TLS credentials.
    class TLS < ChannelCredentials
      getter context : OpenSSL::SSL::Context::Client
      getter server_name_override : String?

      def initialize(@context : OpenSSL::SSL::Context::Client, @server_name_override : String? = nil)
        @context.alpn_protocol = "h2"
      end

      def secure? : Bool
        true
      end

      def tls_context : OpenSSL::SSL::Context::Client?
        @context
      end

      # :nodoc:
      #
      # OpenSSL loads certificates from files; PEM strings are written to a
      # private temporary file first.
      def self.with_pem_file(file : String?, pem : String?, & : String ->) : Nil
        if file && pem
          raise ArgumentError.new("Give either a file or PEM data, not both")
        end
        if file
          yield file
        elsif pem
          tempfile = File.tempfile("grpc-credentials", ".pem")
          begin
            File.chmod(tempfile.path, 0o600)
            tempfile.print(pem)
            tempfile.close
            yield tempfile.path
          ensure
            tempfile.delete
          end
        end
      end
    end
  end

  # Credentials attached to individual calls as metadata, e.g. OAuth bearer
  # tokens. A provider is invoked for every call attempt and returns the
  # metadata to add.
  #
  # ```
  # token = GRPC::CallCredentials.bearer("secret-token")
  # dynamic = GRPC::CallCredentials.new do |context|
  #   {"authorization" => "Bearer #{fetch_token(context.service_url)}"}
  # end
  # client = MyService::Client.new(channel, call_credentials: token)
  # client.with_options(call_credentials: dynamic).my_call(request)
  # ```
  #
  # By default call credentials are only sent over secure (TLS) channels;
  # calls on plaintext channels fail with `UNAUTHENTICATED`. Pass
  # `allow_insecure: true` to send them anyway (e.g. to a local proxy).
  #
  # A provider raising `GRPC::Error` fails the call with that status (codes
  # reserved for the application, like `INVALID_ARGUMENT`, are reported as
  # `INTERNAL`, see gRFC A54); any other exception fails the call with
  # `UNAVAILABLE`.
  abstract class CallCredentials
    # Information about the call passed to providers.
    struct Context
      # `https://<authority>/<package.Service>`, the audience commonly used
      # for JWT tokens.
      getter service_url : String
      # The method name, e.g. `SayHello`.
      getter method_name : String
      # The full method path, e.g. `/helloworld.Greeter/SayHello`.
      getter method_path : String
      getter authority : String
      # Whether the call is made over a secure transport.
      getter? secure : Bool

      def initialize(@method_path : String, @authority : String, @secure : Bool)
        service, _, @method_name = @method_path.lchop('/').rpartition('/')
        @service_url = "https://#{@authority}/#{service}"
      end
    end

    # Creates credentials from a block returning the metadata to add.
    def self.new(*, allow_insecure : Bool = false, &provider : Context -> Metadata | Hash(String, String)) : CallCredentials
      ProcCredentials.new(provider, allow_insecure)
    end

    # Sends `authorization: Bearer <token>`.
    def self.bearer(token : String, *, allow_insecure : Bool = false) : CallCredentials
      metadata = Metadata{"authorization" => "Bearer #{token}"}
      ProcCredentials.new(->(_context : Context) { metadata.as(Metadata | Hash(String, String)) }, allow_insecure)
    end

    # Returns the metadata to add to a call. May block (e.g. to refresh a
    # token).
    abstract def metadata(context : Context) : Metadata | Hash(String, String)

    # Whether these credentials may only be sent over secure channels.
    def requires_secure_transport? : Bool
      true
    end

    # Combines these credentials with *other*; the metadata of both is sent.
    def compose(other : CallCredentials) : CallCredentials
      Composite.new([self, other] of CallCredentials)
    end

    # :ditto:
    def +(other : CallCredentials) : CallCredentials
      compose(other)
    end

    # Codes a credentials provider may not produce (gRFC A54); they are
    # converted to INTERNAL.
    RESERVED_CODES = {
      StatusCode::InvalidArgument, StatusCode::NotFound, StatusCode::AlreadyExists,
      StatusCode::FailedPrecondition, StatusCode::Aborted, StatusCode::OutOfRange, StatusCode::DataLoss,
    }

    # :nodoc:
    #
    # Collects the metadata of *credentials* for a call, converting
    # failures to the statuses described above.
    def self.apply(credentials : CallCredentials, context : Context, metadata : Metadata) : Nil
      if !context.secure? && credentials.requires_secure_transport?
        raise Error.new(StatusCode::Unauthenticated,
          "Call credentials require a secure channel (use allow_insecure: true to override)")
      end
      if credentials.is_a?(Composite)
        credentials.credentials.each { |inner| apply(inner, context, metadata) }
        return
      end
      result = begin
        credentials.metadata(context)
      rescue e : Error
        code = RESERVED_CODES.includes?(e.code) ? StatusCode::Internal : e.code
        raise Error.new(code, "Call credentials failed: #{e.status.message}")
      rescue e
        raise Error.new(StatusCode::Unavailable, "Call credentials failed: #{e.message}")
      end
      begin
        case result
        in Metadata then metadata.merge!(result)
        in Hash     then result.each { |key, value| metadata.add(key, value) }
        end
      rescue e : Metadata::InvalidError
        raise Error.new(StatusCode::Internal, "Call credentials returned invalid metadata: #{e.message}")
      end
    end

    # :nodoc:
    class ProcCredentials < CallCredentials
      def initialize(@provider : Proc(Context, Metadata | Hash(String, String)), @allow_insecure : Bool)
      end

      def metadata(context : Context) : Metadata | Hash(String, String)
        @provider.call(context)
      end

      def requires_secure_transport? : Bool
        !@allow_insecure
      end
    end

    # Several credentials applied in order.
    class Composite < CallCredentials
      getter credentials : Array(CallCredentials)

      def initialize(@credentials : Array(CallCredentials))
      end

      def metadata(context : Context) : Metadata | Hash(String, String)
        combined = Metadata.new
        @credentials.each { |credentials| CallCredentials.apply(credentials, context, combined) }
        combined
      end

      def requires_secure_transport? : Bool
        @credentials.any?(&.requires_secure_transport?)
      end

      def compose(other : CallCredentials) : CallCredentials
        Composite.new(@credentials + [other] of CallCredentials)
      end
    end
  end
end
