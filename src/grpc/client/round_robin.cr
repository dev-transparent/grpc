module GRPC
  # The `round_robin` policy: connects to every address and spreads calls
  # over all READY connections in turn. Lost connections are re-established
  # immediately (subject to backoff).
  #
  # The channel is READY while any connection is READY, CONNECTING while
  # any is connecting, and TRANSIENT_FAILURE when all failed. A failed
  # subchannel counts as failed until it becomes READY again (so the channel
  # does not flap between CONNECTING and TRANSIENT_FAILURE).
  class RoundRobin < LoadBalancer
    class Provider < LoadBalancer::Provider
      def name : String
        "round_robin"
      end

      def build(helper : LoadBalancer::Helper) : LoadBalancer
        RoundRobin.new(helper)
      end

      def parse_config(config : JSON::Any) : LoadBalancingConfig
        RoundRobinConfig.from_json(config.to_json)
      end
    end

    # Picks the READY subchannels in turn.
    class Picker < LoadBalancer::Picker
      getter subchannels : Array(Subchannel)

      def initialize(@subchannels : Array(Subchannel), start : Int32 = 0)
        @next = Atomic(UInt32).new(start.to_u32)
      end

      def pick(info : LoadBalancer::PickInfo) : LoadBalancer::PickResult
        index = @next.add(1, :relaxed) % @subchannels.size
        LoadBalancer::PickResult.complete(@subchannels[index])
      end
    end

    @subchannels = [] of Subchannel
    # Effective state per subchannel (failures are sticky until READY).
    @states = {} of Subchannel => ConnectivityState
    @last_error : String? = nil
    @shutdown = false

    def initialize(@helper : LoadBalancer::Helper, @random : Random = Random.new)
    end

    def update(addresses : Array(Resolver::Address), config : LoadBalancingConfig) : Nil
      return if @shutdown
      existing = @subchannels.index_by(&.address)
      @subchannels = addresses.uniq.map do |address|
        existing.delete(address) || begin
          subchannel = @helper.create_subchannel(address)
          @states[subchannel] = ConnectivityState::Idle
          subchannel.watch { |state, error| on_state_change(subchannel, state, error) }
          subchannel.request_connection
          subchannel
        end
      end
      existing.each_value do |subchannel|
        @states.delete(subchannel)
        subchannel.shutdown
      end
      publish
    end

    def resolver_error(message : String) : Nil
      return if @shutdown
      @last_error = message
      # Keep using the previous addresses, if any.
      if @subchannels.empty?
        @helper.update_state(ConnectivityState::TransientFailure,
          LoadBalancer::FailPicker.new(Status.new(StatusCode::Unavailable, message)))
      end
    end

    def exit_idle : Nil
      @subchannels.each { |subchannel| subchannel.request_connection if subchannel.state.idle? }
    end

    def shutdown : Nil
      @shutdown = true
      @subchannels.each &.shutdown
      @subchannels.clear
      @states.clear
    end

    private def on_state_change(subchannel : Subchannel, state : ConnectivityState, error : String?) : Nil
      return if @shutdown
      previous = @states[subchannel]? || return
      @last_error = error if error

      case state
      when .idle?
        @helper.request_reresolution if previous.ready?
        subchannel.request_connection
      when .transient_failure?
        @helper.request_reresolution
      end

      sticky = previous.transient_failure? && (state.connecting? || state.idle?)
      @states[subchannel] = sticky ? ConnectivityState::TransientFailure : state
      publish
    end

    private def publish : Nil
      return if @subchannels.empty?
      ready = @subchannels.select { |subchannel| @states[subchannel]?.try(&.ready?) }
      if ready.any?
        @helper.update_state(ConnectivityState::Ready, Picker.new(ready, @random.rand(ready.size)))
      elsif @subchannels.any? { |subchannel| @states[subchannel]?.try { |s| s.connecting? || s.idle? } }
        @helper.update_state(ConnectivityState::Connecting, LoadBalancer::QueuePicker.new)
      else
        message = "Failed to connect to all addresses; last error: #{@last_error || "unknown"}"
        @helper.update_state(ConnectivityState::TransientFailure,
          LoadBalancer::FailPicker.new(Status.new(StatusCode::Unavailable, message)))
      end
    end
  end

  LoadBalancer.register(RoundRobin::Provider.new)
end
