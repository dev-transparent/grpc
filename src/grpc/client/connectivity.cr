module GRPC
  # Connectivity state of a channel or subchannel
  # (https://github.com/grpc/grpc/blob/master/doc/connectivity-semantics-and-api.md).
  enum ConnectivityState
    # No connection and no attempt in progress. Channels start (and return
    # after the idle timeout) in this state; calls make them connect.
    Idle
    # A connection is being established.
    Connecting
    # A connection is established and calls can be sent.
    Ready
    # Connecting failed; a new attempt is made after a backoff delay.
    TransientFailure
    # Shut down for good.
    Shutdown
  end

  # :nodoc:
  #
  # Lets any number of fibers wait for "something changed" notifications
  # without missing one: waiters take the current channel, which `#notify`
  # closes (waking everybody) and replaces.
  class ChangeNotifier
    @channel = ::Channel(Nil).new
    @mutex = Mutex.new

    # The channel closed by the next `#notify`.
    def current : ::Channel(Nil)
      @mutex.synchronize { @channel }
    end

    def notify : Nil
      channel = @mutex.synchronize do
        previous = @channel
        @channel = ::Channel(Nil).new
        previous
      end
      channel.close
    end
  end

  # :nodoc:
  #
  # Runs callbacks one at a time and in order, like grpc-core's
  # WorkSerializer. The fiber that schedules work while the serializer is
  # idle runs it (and everything scheduled meanwhile, including work scheduled
  # by the callbacks themselves) before `#run` returns. Callbacks must not
  # block.
  class WorkSerializer
    Log = ::Log.for("grpc.client")

    @queue = Deque(Proc(Nil)).new
    @mutex = Mutex.new
    @running = false

    def run(&block : ->) : Nil
      drain if enqueue(&block)
    end

    # Queues *block* without running it. Returns `true` if the caller must
    # run the queue with `#drain` (it was idle). This lets callers enqueue
    # while holding their own lock (preserving the order of notifications)
    # and drain after releasing it.
    def enqueue(&block : ->) : Bool
      @mutex.synchronize do
        @queue << block
        return false if @running
        @running = true
      end
    end

    # :nodoc:
    def drain : Nil
      loop do
        work = @mutex.synchronize do
          if @queue.empty?
            @running = false
            return
          end
          @queue.shift
        end
        begin
          work.call
        rescue e
          Log.error(exception: e) { "Unhandled exception in channel callback" }
        end
      end
    end
  end
end
