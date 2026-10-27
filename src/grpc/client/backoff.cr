module GRPC
  # Parameters of the exponential backoff used between connection attempts
  # (https://github.com/grpc/grpc/blob/master/doc/connection-backoff.md).
  #
  # ```
  # GRPC::Channel.new("dns:///svc:443", backoff: GRPC::ConnectionBackoff.new(initial: 100.milliseconds, max: 5.seconds))
  # ```
  struct ConnectionBackoff
    # Delay before the second attempt.
    getter initial : Time::Span
    # Factor applied to the delay after every failed attempt.
    getter multiplier : Float64
    # Randomization (+/- this fraction) applied to every delay but the first.
    getter jitter : Float64
    # Upper bound of the delay.
    getter max : Time::Span
    # Minimum time given to a single connection attempt.
    getter min_connect_timeout : Time::Span

    def initialize(@initial : Time::Span = 1.second, @multiplier : Float64 = 1.6, @jitter : Float64 = 0.2,
                   @max : Time::Span = 120.seconds, @min_connect_timeout : Time::Span = 20.seconds)
      raise ArgumentError.new("Backoff initial delay must be positive") unless @initial > Time::Span.zero
      raise ArgumentError.new("Backoff max delay must be >= initial delay") if @max < @initial
      raise ArgumentError.new("Backoff multiplier must be >= 1") if @multiplier < 1
      raise ArgumentError.new("Backoff jitter must be in [0, 1)") unless 0 <= @jitter < 1
      raise ArgumentError.new("Min connect timeout must be positive") unless @min_connect_timeout > Time::Span.zero
    end
  end

  # :nodoc:
  #
  # The state of a connection backoff: each call to `#next_delay` returns
  # the time to wait between the start of an attempt and the start of the
  # next one. Not thread-safe; callers synchronize.
  class Backoff
    getter config : ConnectionBackoff
    @current : Time::Span? = nil

    def initialize(@config : ConnectionBackoff = ConnectionBackoff.new, @random : Random? = nil)
    end

    # Returns the delay for the next attempt: the initial delay first, then
    # growing by the multiplier with jitter, capped at the maximum.
    def next_delay : Time::Span
      if current = @current
        current = Math.min(current * @config.multiplier, @config.max)
        @current = current
        jitter = current * @config.jitter
        current + jitter * (((random = @random) ? random.rand : Random.rand) * 2 - 1)
      else
        @current = @config.initial
        @config.initial
      end
    end

    # Restarts from the initial delay (after a successful connection).
    def reset : Nil
      @current = nil
    end
  end
end
