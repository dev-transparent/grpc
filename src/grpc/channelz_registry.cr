require "weak_ref"

module GRPC
  # Call counters of a channel or server (exposed by channelz).
  class CallMetrics
    getter started = Atomic(Int64).new(0_i64)
    getter succeeded = Atomic(Int64).new(0_i64)
    getter failed = Atomic(Int64).new(0_i64)
    # Unix time in nanoseconds of the last call start (0 if never).
    getter last_started = Atomic(Int64).new(0_i64)

    def record_start : Nil
      @started.add(1)
      @last_started.set(Time.utc.to_unix_ns.to_i64)
    end

    def record_end(ok : Bool) : Nil
      (ok ? @succeeded : @failed).add(1)
    end
  end

  # Tracks live channels and servers for the channelz service, without
  # keeping them alive (entries are weak references).
  # :nodoc:
  module ChannelzRegistry
    @@channels = [] of WeakRef(Channel)
    @@servers = [] of WeakRef(Server)
    @@mutex = Mutex.new
    @@next_id = Atomic(Int64).new(0_i64)

    def self.next_id : Int64
      # Shares the id space with HTTP/2 connections (sockets).
      HTTP2::ConnectionMetrics.next_id
    end

    def self.register(channel : Channel) : Nil
      @@mutex.synchronize { @@channels << WeakRef.new(channel) }
    end

    def self.register(server : Server) : Nil
      @@mutex.synchronize { @@servers << WeakRef.new(server) }
    end

    def self.channels : Array(Channel)
      @@mutex.synchronize do
        @@channels.reject! { |ref| ref.value.nil? }
        @@channels.compact_map(&.value)
      end
    end

    def self.servers : Array(Server)
      @@mutex.synchronize do
        @@servers.reject! { |ref| ref.value.nil? }
        @@servers.compact_map(&.value)
      end
    end
  end
end
