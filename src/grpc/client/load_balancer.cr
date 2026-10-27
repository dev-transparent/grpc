require "json"

module GRPC
  # A load balancing policy: manages subchannels for the resolved addresses
  # and decides which one each call uses
  # (https://github.com/grpc/grpc/blob/master/doc/load-balancing.md).
  #
  # Policies are created by a `LoadBalancer::Provider` registered by name
  # and selected by the service config (`loadBalancingConfig`) or the
  # channel's `load_balancing_policy` option. Built-in: `pick_first`
  # (default) and `round_robin`.
  #
  # All methods of a policy (and the subchannel state callbacks it
  # registers) are called serially by the channel, so policies need no
  # locking. They must not block. Policies publish their state and a
  # `Picker` with `Helper#update_state`; pickers are called concurrently by
  # calls and must be thread-safe (usually immutable).
  abstract class LoadBalancer
    # The channel side of a policy.
    abstract class Helper
      # Creates a subchannel (initially IDLE) for *address*.
      abstract def create_subchannel(address : Resolver::Address) : Subchannel

      # Publishes the policy's aggregate state and the picker used for new
      # calls.
      abstract def update_state(state : ConnectivityState, picker : Picker) : Nil

      # Asks the resolver to resolve again (e.g. after a connection loss).
      abstract def request_reresolution : Nil

      # Runs *block* serially with the policy's other callbacks, e.g. from a
      # picker that needs to call back into the policy.
      abstract def schedule(&block : ->) : Nil

      # The channel's authority.
      abstract def authority : String
    end

    # Information about a call being picked.
    struct PickInfo
      getter method_path : String
      getter metadata : Metadata

      def initialize(@method_path : String, @metadata : Metadata)
      end
    end

    # The outcome of a pick.
    struct PickResult
      enum Kind
        # Use `subchannel`.
        Complete
        # No decision yet: the call waits for the next picker.
        Queue
        # Fail the call with `status`, unless it is wait-for-ready (then it
        # is queued).
        Fail
        # Fail the call with `status`, even if it is wait-for-ready.
        Drop
      end

      getter kind : Kind
      getter subchannel : Subchannel?
      getter status : Status?

      def initialize(@kind : Kind, @subchannel : Subchannel? = nil, @status : Status? = nil)
      end

      def self.complete(subchannel : Subchannel) : PickResult
        new(Kind::Complete, subchannel)
      end

      def self.queue : PickResult
        new(Kind::Queue)
      end

      def self.fail(status : Status) : PickResult
        new(Kind::Fail, status: status)
      end

      def self.drop(status : Status) : PickResult
        new(Kind::Drop, status: status)
      end
    end

    # Chooses the subchannel for a call. Called concurrently.
    abstract class Picker
      abstract def pick(info : PickInfo) : PickResult
    end

    # Queues every call.
    class QueuePicker < Picker
      def pick(info : PickInfo) : PickResult
        PickResult.queue
      end
    end

    # Fails every call with *status* (wait-for-ready calls are queued).
    class FailPicker < Picker
      getter status : Status

      def initialize(@status : Status)
      end

      def pick(info : PickInfo) : PickResult
        PickResult.fail(@status)
      end
    end

    # Always picks one subchannel.
    class SubchannelPicker < Picker
      getter subchannel : Subchannel

      def initialize(@subchannel : Subchannel)
      end

      def pick(info : PickInfo) : PickResult
        PickResult.complete(@subchannel)
      end
    end

    # Queues calls and asks the policy to leave IDLE (once).
    class IdlePicker < Picker
      def initialize(@helper : Helper, &@exit_idle : ->)
        @triggered = Atomic(Bool).new(false)
      end

      def pick(info : PickInfo) : PickResult
        unless @triggered.swap(true)
          exit_idle = @exit_idle
          @helper.schedule { exit_idle.call }
        end
        PickResult.queue
      end
    end

    # Creates policies of one kind.
    abstract class Provider
      # The policy name used in service configs, e.g. `"round_robin"`.
      abstract def name : String

      abstract def build(helper : Helper) : LoadBalancer

      # Validates the policy's config from `loadBalancingConfig`, returning
      # it (possibly normalized). Raise `ArgumentError` if it is invalid.
      def parse_config(config : JSON::Any) : JSON::Any
        raise ArgumentError.new("config must be an object") unless config.as_h?
        config
      end
    end

    @@providers = {} of String => Provider
    @@registry_mutex = Mutex.new

    # Registers *provider* under its name, replacing any previous one.
    def self.register(provider : Provider) : Nil
      @@registry_mutex.synchronize { @@providers[provider.name] = provider }
    end

    def self.provider(name : String) : Provider?
      @@registry_mutex.synchronize { @@providers[name]? }
    end

    def self.names : Array(String)
      @@registry_mutex.synchronize { @@providers.keys }
    end

    # Receives new addresses (never empty) and the policy's config.
    abstract def update(addresses : Array(Resolver::Address), config : JSON::Any) : Nil

    # The resolver failed (or returned no addresses). Policies that have no
    # usable addresses should report TRANSIENT_FAILURE.
    abstract def resolver_error(message : String) : Nil

    # A call was started while the policy is IDLE: start connecting.
    abstract def exit_idle : Nil

    # Releases all subchannels.
    abstract def shutdown : Nil
  end
end
