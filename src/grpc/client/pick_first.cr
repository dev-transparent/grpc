module GRPC
  # The `pick_first` policy (the default): connects to the addresses in
  # order and sends every call to the first one that connects. When that
  # connection is lost the channel goes IDLE and reconnects on the next
  # call, starting from the first address again.
  #
  # Config: `{"shuffleAddressList": true}` randomizes the address order on
  # every resolver update (to spread clients over servers).
  #
  # When all addresses failed the policy reports TRANSIENT_FAILURE and keeps
  # it ("sticky") while retrying each address after its backoff, until one
  # connects.
  class PickFirst < LoadBalancer
    class Provider < LoadBalancer::Provider
      def name : String
        "pick_first"
      end

      def build(helper : LoadBalancer::Helper) : LoadBalancer
        PickFirst.new(helper)
      end

      def parse_config(config : JSON::Any) : JSON::Any
        hash = config.as_h? || raise ArgumentError.new("config must be an object")
        if (shuffle = hash["shuffleAddressList"]?) && shuffle.as_bool?.nil?
          raise ArgumentError.new("shuffleAddressList must be a boolean")
        end
        config
      end
    end

    @subchannels = [] of Subchannel
    @selected : Subchannel? = nil
    # Index of the subchannel being tried in the current connection pass.
    @index = 0
    @connecting = false
    # Set after a whole pass failed, until a subchannel becomes READY.
    @sticky_failure = false
    @state = ConnectivityState::Idle
    @last_error : String? = nil
    @shutdown = false
    # Set while IDLE after losing a connection: updates do not reconnect.
    @idle = false

    def initialize(@helper : LoadBalancer::Helper, @random : Random = Random.new)
    end

    def update(addresses : Array(Resolver::Address), config : JSON::Any) : Nil
      return if @shutdown
      addresses = addresses.uniq
      addresses = addresses.shuffle(@random) if config["shuffleAddressList"]?.try(&.as_bool?)

      existing = @subchannels.index_by(&.address)
      @subchannels = addresses.map { |address| existing.delete(address) || new_subchannel(address) }
      existing.each_value &.shutdown

      if (selected = @selected) && @subchannels.includes?(selected)
        return
      end
      @selected = nil
      start_pass unless @idle
    end

    def resolver_error(message : String) : Nil
      return if @shutdown
      return unless @subchannels.empty? || @state.transient_failure?
      @last_error = message
      @sticky_failure = true
      report(ConnectivityState::TransientFailure, LoadBalancer::FailPicker.new(Status.new(StatusCode::Unavailable, message)))
    end

    def exit_idle : Nil
      return if @shutdown || @selected || @connecting
      @idle = false
      start_pass
    end

    def shutdown : Nil
      @shutdown = true
      @subchannels.each &.shutdown
      @subchannels.clear
      @selected = nil
    end

    private def new_subchannel(address : Resolver::Address) : Subchannel
      subchannel = @helper.create_subchannel(address)
      subchannel.watch { |state, error| on_state_change(subchannel, state, error) }
      subchannel
    end

    # Starts trying the addresses in order.
    private def start_pass : Nil
      return if @subchannels.empty?
      @index = 0
      @connecting = true
      report(ConnectivityState::Connecting, LoadBalancer::QueuePicker.new) unless @sticky_failure
      try_next
    end

    private def try_next : Nil
      while subchannel = @subchannels[@index]?
        case subchannel.state
        when .ready?
          select_subchannel(subchannel)
          return
        when .idle?
          subchannel.request_connection
          return
        when .connecting?
          return
        else
          @index += 1
        end
      end
      # Every address failed.
      @connecting = false
      @sticky_failure = true
      message = "Failed to connect to all addresses; last error: #{@last_error || "unknown"}"
      report(ConnectivityState::TransientFailure, LoadBalancer::FailPicker.new(Status.new(StatusCode::Unavailable, message)))
      @helper.request_reresolution
      # Subchannels whose backoff already elapsed are IDLE: retry them now.
      @subchannels.each { |subchannel| subchannel.request_connection if subchannel.state.idle? }
    end

    private def on_state_change(subchannel : Subchannel, state : ConnectivityState, error : String?) : Nil
      return if @shutdown || !@subchannels.includes?(subchannel)
      @last_error = error if error

      if subchannel.same?(@selected)
        return if state.ready?
        # The connection was lost: go IDLE until the next call.
        @selected = nil
        @connecting = false
        @idle = true
        @helper.request_reresolution
        report(ConnectivityState::Idle, LoadBalancer::IdlePicker.new(@helper) { exit_idle })
        return
      end
      return if @selected

      case state
      when .ready?
        select_subchannel(subchannel)
      when .transient_failure?
        if @connecting && subchannel.same?(@subchannels[@index]?)
          @index += 1
          try_next
        end
      when .idle?
        # Backoff elapsed: retry while in sticky failure, or if this is the
        # address currently being tried.
        if @sticky_failure && !@connecting
          subchannel.request_connection
        elsif @connecting && subchannel.same?(@subchannels[@index]?)
          subchannel.request_connection
        end
      end
    end

    private def select_subchannel(subchannel : Subchannel) : Nil
      @selected = subchannel
      @connecting = false
      @sticky_failure = false
      # Drop the other connections (and attempts); keep fresh subchannels
      # for the next pass.
      @subchannels = @subchannels.map do |other|
        next other if other.same?(subchannel)
        other.shutdown
        new_subchannel(other.address)
      end
      report(ConnectivityState::Ready, LoadBalancer::SubchannelPicker.new(subchannel))
    end

    private def report(state : ConnectivityState, picker : LoadBalancer::Picker) : Nil
      @state = state
      @helper.update_state(state, picker)
    end
  end

  LoadBalancer.register(PickFirst::Provider.new)
end
