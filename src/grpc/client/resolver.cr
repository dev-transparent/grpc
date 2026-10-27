module GRPC
  # A name resolver turns a channel `Target` into a list of addresses (and
  # optionally a service config), and keeps it up to date
  # (https://github.com/grpc/grpc/blob/master/doc/naming.md).
  #
  # Resolvers are created by a `Resolver::Provider` registered for a URI
  # scheme. Built-in schemes: `dns` (default), `ipv4`, `ipv6`, `unix`,
  # `unix-abstract` and `passthrough`. Custom resolvers subclass `Resolver`
  # and `Resolver::Provider` and are registered with `Resolver.register` or
  # passed to a single channel (`Channel.new(target, resolver: provider)`).
  # `ManualResolver` is a ready-made resolver whose addresses are set by the
  # application.
  #
  # Resolvers deliver results by calling the listener given to
  # `Provider#build`, from any fiber, at any time after `#start` was called.
  abstract class Resolver
    DEFAULT_PORT = 443

    # A resolved address of a server.
    struct Address
      enum Kind
        # A TCP endpoint; `host` is an IP address, or a host name resolved
        # when connecting (`passthrough`).
        TCP
        # A UNIX domain socket at `path`.
        Unix
        # A Linux abstract UNIX socket named `path`.
        UnixAbstract
        # Connections are made by the channel's custom IO factory.
        Custom
      end

      getter kind : Kind
      getter host : String
      getter port : Int32
      getter path : String

      def initialize(@kind : Kind, @host : String = "", @port : Int32 = 0, @path : String = "")
      end

      def self.tcp(host : String, port : Int32) : Address
        new(Kind::TCP, host: host, port: port)
      end

      def self.unix(path : String) : Address
        new(Kind::Unix, path: path)
      end

      # Parses `"host:port"`, `"[v6]:port"` or `"unix:/path"`.
      def self.parse(address : String, default_port : Int32 = DEFAULT_PORT) : Address
        if address.starts_with?("unix:")
          path = address.lchop("unix:")
          path = path.lchop("//") if path.starts_with?("///")
          raise ArgumentError.new("Empty UNIX socket path in #{address.inspect}") if path.empty?
          return unix(path)
        end
        host, port = Resolver.split_host_port(address, default_port)
        tcp(host, port)
      end

      def to_s(io : IO) : Nil
        case @kind
        in .tcp?
          if @host.includes?(':')
            io << '[' << @host << "]:" << @port
          else
            io << @host << ':' << @port
          end
        in .unix?          then io << "unix:" << @path
        in .unix_abstract? then io << "unix-abstract:" << @path
        in .custom?        then io << "custom:" << @path
        end
      end

      def inspect(io : IO) : Nil
        io << "#<GRPC::Resolver::Address " << self << '>'
      end
    end

    # The outcome of a resolution: addresses (and an optional service
    # config), or an error.
    struct Result
      getter addresses : Array(Address)
      # The service config in JSON, if the resolver provides one.
      getter service_config : String?
      # Set when resolution failed.
      getter error : String?

      def initialize(@addresses : Array(Address), @service_config : String? = nil, @error : String? = nil)
      end

      def self.error(message : String) : Result
        new([] of Address, nil, message)
      end

      def error? : Bool
        !@error.nil?
      end
    end

    alias Listener = Proc(Result, Nil)

    # Creates resolvers for one URI scheme.
    abstract class Provider
      # The URI scheme handled, e.g. `"dns"`.
      abstract def scheme : String

      # Creates a resolver for *target* delivering results to *listener*.
      abstract def build(target : Target, listener : Listener) : Resolver

      # The authority (`:authority` header and TLS server name) used for
      # calls on channels to *target*.
      def default_authority(target : Target) : String
        target.endpoint
      end

      # Raises `ArgumentError` if *target* is malformed for this scheme.
      def validate(target : Target) : Nil
      end
    end

    @@providers = {} of String => Provider
    @@registry_mutex = Mutex.new

    # Registers *provider* for its scheme, replacing any previous one.
    def self.register(provider : Provider) : Nil
      @@registry_mutex.synchronize { @@providers[provider.scheme.downcase] = provider }
    end

    def self.unregister(scheme : String) : Nil
      @@registry_mutex.synchronize { @@providers.delete(scheme.downcase) }
    end

    # The provider registered for *scheme*.
    def self.provider(scheme : String) : Provider?
      @@registry_mutex.synchronize { @@providers[scheme.downcase]? }
    end

    def self.registered?(scheme : String) : Bool
      !provider(scheme).nil?
    end

    # Starts resolving. Results may be delivered from within this call.
    abstract def start : Nil

    # Asks for a new resolution, e.g. after a connection failed. Resolvers
    # may rate limit or ignore this.
    abstract def resolve_now : Nil

    # Stops resolving; no results are delivered afterwards.
    abstract def shutdown : Nil

    # :nodoc:
    #
    # Splits `host:port`, `[v6]:port`, `[v6]`, a bare IPv6 address or a bare
    # host.
    def self.split_host_port(address : String, default_port : Int32 = DEFAULT_PORT) : {String, Int32}
      raise ArgumentError.new("Empty address") if address.empty?
      if address.starts_with?('[')
        host, bracket, rest = address.lchop('[').partition(']')
        raise ArgumentError.new("Invalid address #{address.inspect}") if bracket.empty? || host.empty?
        return {host, default_port} if rest.empty?
        raise ArgumentError.new("Invalid address #{address.inspect}") unless rest.starts_with?(':')
        {host, parse_port(rest.lchop(':'), address)}
      elsif address.count(':') == 1
        host, _, port = address.partition(':')
        raise ArgumentError.new("Invalid address #{address.inspect}") if host.empty?
        {host, port.empty? ? default_port : parse_port(port, address)}
      else
        {address, default_port}
      end
    end

    private def self.parse_port(port : String, address : String) : Int32
      value = port.to_i? if port.each_char.all?(&.ascii_number?)
      unless value && 0 <= value <= 65_535
        raise ArgumentError.new("Invalid port in address #{address.inspect}")
      end
      value
    end
  end

  # A resolver whose result is known up front (`ipv4:`, `ipv6:`, `unix:`,
  # `passthrough:` targets).
  class StaticResolver < Resolver
    def initialize(@result : Resolver::Result, @listener : Resolver::Listener)
      @shutdown = Atomic(Bool).new(false)
    end

    def start : Nil
      @listener.call(@result) unless @shutdown.get
    end

    # The result never changes: nothing to do.
    def resolve_now : Nil
    end

    def shutdown : Nil
      @shutdown.set(true)
    end

    # Base class of the providers of static resolvers.
    abstract class Provider < Resolver::Provider
      # Parses the addresses of *target*.
      abstract def addresses(target : Target) : Array(Resolver::Address)

      def build(target : Target, listener : Resolver::Listener) : Resolver
        result = begin
          Resolver::Result.new(addresses(target))
        rescue e : ArgumentError
          Resolver::Result.error(e.message || "Invalid target")
        end
        StaticResolver.new(result, listener)
      end

      def validate(target : Target) : Nil
        unless target.authority.empty?
          raise ArgumentError.new("#{scheme}: targets do not support an authority (#{target})")
        end
        addresses(target)
      end
    end

    # `ipv4:address[:port][,address[:port],...]`
    class IPv4Provider < Provider
      def scheme : String
        "ipv4"
      end

      def addresses(target : Target) : Array(Resolver::Address)
        StaticResolver.parse_list(target) do |entry|
          host, port = Resolver.split_host_port(entry)
          unless Socket::IPAddress.valid_v4?(host)
            raise ArgumentError.new("Invalid IPv4 address #{host.inspect} in #{target}")
          end
          Resolver::Address.tcp(host, port)
        end
      end

      def default_authority(target : Target) : String
        target.endpoint.split(',').first
      end
    end

    # `ipv6:address[:port][,address[:port],...]` where addresses with a port
    # are written in brackets (`[::1]:50051`).
    class IPv6Provider < Provider
      def scheme : String
        "ipv6"
      end

      def addresses(target : Target) : Array(Resolver::Address)
        StaticResolver.parse_list(target) do |entry|
          host, port = Resolver.split_host_port(entry)
          unless Socket::IPAddress.valid_v6?(host)
            raise ArgumentError.new("Invalid IPv6 address #{host.inspect} in #{target}")
          end
          Resolver::Address.tcp(host, port)
        end
      end

      def default_authority(target : Target) : String
        target.endpoint.split(',').first
      end
    end

    # `unix:relative_or_absolute_path` or `unix:///absolute_path`.
    class UnixProvider < Provider
      def scheme : String
        "unix"
      end

      def addresses(target : Target) : Array(Resolver::Address)
        path = target.hierarchical? ? "/#{target.endpoint}" : target.endpoint
        raise ArgumentError.new("Empty UNIX socket path in #{target}") if path.empty? || path == "/"
        [Resolver::Address.unix(path)]
      end

      def default_authority(target : Target) : String
        "localhost"
      end
    end

    # `unix-abstract:name`: a socket in the Linux abstract namespace.
    class UnixAbstractProvider < Provider
      def scheme : String
        "unix-abstract"
      end

      def addresses(target : Target) : Array(Resolver::Address)
        {% unless flag?(:linux) %}
          raise ArgumentError.new("unix-abstract: targets are only supported on Linux")
        {% end %}
        [Resolver::Address.new(Resolver::Address::Kind::UnixAbstract, path: target.endpoint)]
      end

      def default_authority(target : Target) : String
        "localhost"
      end
    end

    # `passthrough:///host:port`: the address is used as is; host names are
    # resolved by the operating system when connecting.
    class PassthroughProvider < Provider
      def scheme : String
        "passthrough"
      end

      def addresses(target : Target) : Array(Resolver::Address)
        [Resolver::Address.parse(target.endpoint)]
      end

      def validate(target : Target) : Nil
        addresses(target)
      end
    end

    # :nodoc:
    def self.parse_list(target : Target, & : String -> Resolver::Address) : Array(Resolver::Address)
      entries = target.endpoint.split(',')
      raise ArgumentError.new("No addresses in #{target}") if entries.all?(&.empty?)
      entries.map do |entry|
        raise ArgumentError.new("Empty address in #{target}") if entry.empty?
        yield entry
      end
    end
  end

  # A resolver controlled by the application: set its addresses (and
  # service config) with `#update`, at any time. Useful in tests and for
  # service discovery integrations.
  #
  # ```
  # resolver = GRPC::ManualResolver.new
  # resolver.update(["127.0.0.1:50051", "127.0.0.1:50052"])
  # channel = GRPC::Channel.new("manual:///my-service", resolver: resolver,
  #   service_config: %({"loadBalancingConfig": [{"round_robin": {}}]}))
  # ```
  #
  # One `ManualResolver` can serve several channels; they all receive every
  # update.
  class ManualResolver < Resolver::Provider
    getter scheme : String
    # The authority used by channels; defaults to the target's endpoint.
    property authority : String?

    @result : Resolver::Result? = nil
    @listeners = [] of Resolver::Listener
    @mutex = Mutex.new
    @resolve_now_count = Atomic(Int32).new(0)

    def initialize(@scheme : String = "manual", @authority : String? = nil)
    end

    # Publishes a new result.
    def update(addresses : Array(Resolver::Address), service_config : String? = nil) : Nil
      publish(Resolver::Result.new(addresses, service_config))
    end

    # Publishes a new result with addresses given as `"host:port"` or
    # `"unix:/path"` strings.
    def update(addresses : Array(String), service_config : String? = nil) : Nil
      update(addresses.map { |address| Resolver::Address.parse(address) }, service_config)
    end

    # Publishes a resolution error.
    def fail(message : String) : Nil
      publish(Resolver::Result.error(message))
    end

    # How many times channels asked for re-resolution.
    def resolve_now_count : Int32
      @resolve_now_count.get
    end

    def build(target : Target, listener : Resolver::Listener) : Resolver
      Instance.new(self, listener)
    end

    def default_authority(target : Target) : String
      @authority || target.endpoint
    end

    private def publish(result : Resolver::Result) : Nil
      listeners = @mutex.synchronize do
        @result = result
        @listeners.dup
      end
      listeners.each &.call(result)
    end

    protected def attach(listener : Resolver::Listener) : Nil
      result = @mutex.synchronize do
        @listeners << listener
        @result
      end
      listener.call(result) if result
    end

    protected def detach(listener : Resolver::Listener) : Nil
      @mutex.synchronize { @listeners.delete(listener) }
    end

    protected def requested_resolution : Nil
      @resolve_now_count.add(1)
    end

    # :nodoc:
    class Instance < Resolver
      def initialize(@provider : ManualResolver, @listener : Resolver::Listener)
      end

      def start : Nil
        @provider.attach(@listener)
      end

      def resolve_now : Nil
        @provider.requested_resolution
      end

      def shutdown : Nil
        @provider.detach(@listener)
      end
    end
  end
end
