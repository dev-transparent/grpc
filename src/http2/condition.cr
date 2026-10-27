module HTTP2
  # A minimal fiber aware condition variable. All methods must be called while
  # holding the `Mutex` that protects the state being waited on.
  class Condition
    def initialize
      @waiters = Deque(Channel(Nil)).new
    end

    # Releases *mutex*, waits until `#broadcast` is called (or *timeout*
    # elapses) and reacquires *mutex*. Returns `false` on timeout.
    def wait(mutex : Mutex, timeout : Time::Span? = nil) : Bool
      channel = Channel(Nil).new(1)
      @waiters << channel
      mutex.unlock
      signalled = true
      begin
        if timeout
          select
          when channel.receive
          when timeout(timeout)
            signalled = false
          end
        else
          channel.receive
        end
      ensure
        mutex.lock
        @waiters.delete(channel)
      end
      signalled
    end

    # Wakes up all waiting fibers.
    def broadcast : Nil
      @waiters.each do |channel|
        select
        when channel.send(nil)
        else
        end
      end
      @waiters.clear
    end
  end
end
