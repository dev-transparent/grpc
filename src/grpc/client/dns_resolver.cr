module GRPC
  # The default resolver, for `dns:[//authority/]host[:port]` targets (and
  # targets without a scheme). Returns all A and AAAA records of the host
  # (IP literals are used directly).
  #
  # Results are refreshed every `refresh_interval`, and when the channel asks
  # for re-resolution (a connection failed or was lost), but never more often
  # than every `min_interval`. Failed lookups are retried with exponential
  # backoff. Service configs are not looked up in DNS TXT records; use the
  # channel's `service_config` option instead.
  #
  # Customize resolution by registering a configured provider:
  #
  # ```
  # GRPC::Resolver.register(GRPC::DNSResolver::Provider.new(refresh_interval: 5.minutes))
  # ```
  class DNSResolver < Resolver
    Log = ::Log.for("grpc.dns")

    alias Lookup = Proc(String, Int32, Array(Resolver::Address))

    # Resolves *host* with the operating system resolver (getaddrinfo).
    DEFAULT_LOOKUP = ->(host : String, port : Int32) do
      addresses = [] of Resolver::Address
      Socket::Addrinfo.tcp(host, port).each do |info|
        ip = info.ip_address
        address = Resolver::Address.tcp(ip.address, port)
        addresses << address unless addresses.includes?(address)
      end
      addresses
    end

    class Provider < Resolver::Provider
      # Minimum time between two resolutions.
      getter min_interval : Time::Span
      # Time between periodic re-resolutions (`nil` to only re-resolve on
      # request).
      getter refresh_interval : Time::Span?
      # Backoff between attempts after a failed lookup.
      getter backoff : ConnectionBackoff
      # Performs the actual lookup.
      getter lookup : Lookup

      def initialize(*, @min_interval : Time::Span = 30.seconds, @refresh_interval : Time::Span? = 30.minutes,
                     @backoff : ConnectionBackoff = ConnectionBackoff.new(initial: 1.second, max: 120.seconds),
                     @lookup : Lookup = DEFAULT_LOOKUP)
      end

      # Uses the block for lookups, e.g. to stub DNS in tests.
      def self.new(*, min_interval : Time::Span = 30.seconds, refresh_interval : Time::Span? = 30.minutes,
                   backoff : ConnectionBackoff = ConnectionBackoff.new(initial: 1.second, max: 120.seconds),
                   &lookup : String, Int32 -> Array(Resolver::Address))
        new(min_interval: min_interval, refresh_interval: refresh_interval, backoff: backoff, lookup: lookup)
      end

      def scheme : String
        "dns"
      end

      def build(target : Target, listener : Resolver::Listener) : Resolver
        host, port = DNSResolver.host_port(target)
        DNSResolver.new(host, port, listener, self)
      end

      def validate(target : Target) : Nil
        unless target.authority.empty?
          raise ArgumentError.new("Custom DNS servers are not supported (#{target})")
        end
        DNSResolver.host_port(target)
      end

      def default_authority(target : Target) : String
        target.endpoint
      end
    end

    @wake = ::Channel(Nil).new(1)
    @stop = ::Channel(Nil).new
    @stopped = Atomic(Bool).new(false)

    def initialize(@host : String, @port : Int32, @listener : Resolver::Listener, @provider : Provider)
    end

    def start : Nil
      spawn(name: "grpc-dns-resolver") { run }
    end

    def resolve_now : Nil
      select
      when @wake.send(nil)
      else
      end
    end

    def shutdown : Nil
      @stop.close unless @stopped.swap(true)
    end

    # :nodoc:
    def self.host_port(target : Target) : {String, Int32}
      endpoint = target.endpoint
      raise ArgumentError.new("Missing host in target #{target.original.inspect}") if endpoint.empty?
      Resolver.split_host_port(endpoint)
    end

    private def run : Nil
      backoff = Backoff.new(@provider.backoff)
      loop do
        started = Time.instant
        result = resolve
        return if @stopped.get
        @listener.call(result)

        delay = if result.error?
                  backoff.next_delay
                else
                  backoff.reset
                  @provider.refresh_interval
                end
        case wait(delay)
        in .stopped? then return
        in .timeout?
        in .requested?
          # Re-resolution requests are rate limited to one per min_interval.
          remaining = started + @provider.min_interval - Time.instant
          return if remaining > Time::Span.zero && !sleep_until_stopped(remaining)
        end
      end
    end

    private def resolve : Resolver::Result
      if Socket::IPAddress.valid?(@host)
        return Resolver::Result.new([Resolver::Address.tcp(@host, @port)])
      end
      addresses = @provider.lookup.call(@host, @port)
      return Resolver::Result.error("DNS resolution of #{@host} returned no addresses") if addresses.empty?
      Resolver::Result.new(addresses)
    rescue e
      Log.debug { "DNS resolution of #{@host} failed: #{e.message}" }
      Resolver::Result.error("DNS resolution of #{@host} failed: #{e.message}")
    end

    private enum Wakeup
      Requested
      Timeout
      Stopped
    end

    # Waits for a re-resolution request or *timeout*.
    private def wait(timeout : Time::Span?) : Wakeup
      if timeout
        select
        when @wake.receive
          return Wakeup::Requested
        when @stop.receive?
          return Wakeup::Stopped
        when timeout(timeout)
          return Wakeup::Timeout
        end
      else
        select
        when @wake.receive
          return Wakeup::Requested
        when @stop.receive?
          return Wakeup::Stopped
        end
      end
    end

    private def sleep_until_stopped(span : Time::Span) : Bool
      select
      when @stop.receive?
        return false
      when timeout(span)
      end
      !@stopped.get
    end
  end

  Resolver.register(DNSResolver::Provider.new)
  Resolver.register(StaticResolver::IPv4Provider.new)
  Resolver.register(StaticResolver::IPv6Provider.new)
  Resolver.register(StaticResolver::UnixProvider.new)
  Resolver.register(StaticResolver::UnixAbstractProvider.new)
  Resolver.register(StaticResolver::PassthroughProvider.new)
end
