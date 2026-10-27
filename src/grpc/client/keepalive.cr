module GRPC
  # Client-side keepalive settings
  # (https://github.com/grpc/grpc/blob/master/doc/keepalive.md).
  #
  # Keepalive pings are implemented by the HTTP/2 transport; the channel only
  # carries these settings to every connection it creates (see
  # `Subchannel#configure_connection`).
  struct KeepaliveOptions
    # Interval between pings on an otherwise idle connection.
    getter time : Time::Span
    # Time to wait for a ping acknowledgement before closing the connection.
    getter timeout : Time::Span
    # Whether to send pings when there are no active calls.
    getter? permit_without_calls : Bool

    def initialize(@time : Time::Span, @timeout : Time::Span = 20.seconds, @permit_without_calls : Bool = false)
      raise ArgumentError.new("Keepalive time must be positive") unless @time > Time::Span.zero
      raise ArgumentError.new("Keepalive timeout must be positive") unless @timeout > Time::Span.zero
    end
  end
end
