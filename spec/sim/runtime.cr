# Deterministic simulation runtime.
#
# Requiring this file turns the process into a deterministic simulation:
#
# * time is virtual: `Time.instant`, `Time.utc`, `sleep` and `select ...
#   timeout` all use a simulated clock that only advances when every fiber
#   is blocked (then it jumps straight to the next timer);
# * randomness (`Random::Secure`, `Random.rand`, `Random.new`) comes from one seeded
#   generator;
# * fibers run on Crystal's single-threaded scheduler, whose FIFO run queue
#   is deterministic once time and I/O are.
#
# Together with `Sim::Network` (in-memory sockets) a run is a pure function
# of its seed. It must only be required by simulation programs, never by the
# library or the regular specs, and the program must be built without
# `-Dpreview_mt` / `-Dexecution_context`.
{% if flag?(:execution_context) || flag?(:preview_mt) %}
  {% raise "The simulation runtime requires the single-threaded scheduler (build without -Dpreview_mt / -Dexecution_context)" %}
{% end %}

module Sim
  # The virtual monotonic clock starts here (an arbitrary non-zero value).
  CLOCK_START_NS = 1_000_000_000_000_i64
  # The virtual wall clock: 2027-01-15T08:00:00Z at clock start.
  WALL_START_UNIX = 1_800_000_000_i64

  @@now_ns : Int64 = CLOCK_START_NS
  @@rng = Random::PCG32.new(0_u64)
  @@seed = 0_u64

  # Nanoseconds since the simulation started.
  def self.elapsed : Time::Span
    Time::Span.new(nanoseconds: @@now_ns - CLOCK_START_NS)
  end

  def self.now_ns : Int64
    @@now_ns
  end

  # Advances the virtual clock (never backwards).
  def self.advance_to(ns : Int64) : Nil
    @@now_ns = ns if ns > @@now_ns
  end

  def self.seed : UInt64
    @@seed
  end

  # The seeded generator for all simulation decisions.
  def self.rng : Random::PCG32
    @@rng
  end

  # Resets the virtual clock and reseeds every source of randomness.
  def self.reset(seed : UInt64) : Nil
    @@seed = seed
    @@now_ns = CLOCK_START_NS
    @@rng = Random::PCG32.new(seed)
    Random.thread_default.new_seed(seed ^ 0x9e3779b97f4a7c15_u64)
    EventLoop.instance.try &.reset
  end

  # A timer in the virtual timer heap.
  # :nodoc:
  class Timer
    enum Kind
      Sleep
      SelectTimeout
    end

    getter wake_ns : Int64
    getter seq : Int64
    getter fiber : Fiber
    getter kind : Kind
    property? cancelled = false

    def initialize(@wake_ns : Int64, @seq : Int64, @fiber : Fiber, @kind : Kind)
    end

    def <=>(other : Timer) : Int32
      cmp = @wake_ns <=> other.wake_ns
      cmp == 0 ? @seq <=> other.seq : cmp
    end
  end

  # The select-timeout event of one fiber.
  # :nodoc:
  class TimeoutEvent
    include Crystal::EventLoop::Event

    @timer : Timer? = nil

    def initialize(@fiber : Fiber)
    end

    def add(timeout : Time::Span) : Nil
      delete
      @timer = EventLoop.instance.not_nil!.add_timer(timeout, @fiber, Timer::Kind::SelectTimeout)
    end

    def delete : Nil
      @timer.try &.cancelled = true
      @timer = nil
    end

    def free : Nil
      delete
    end

    def clear : Nil
      @timer = nil
    end
  end

  # Raised (and reported) when every fiber is blocked and no timer is
  # pending: nothing can ever happen again.
  class DeadlockError < Exception
  end

  # An event loop running timers on the virtual clock. Real file descriptors
  # (STDOUT, files) are still served by the kqueue/epoll backend.
  {% if flag?(:darwin) || flag?(:freebsd) || flag?(:openbsd) || flag?(:netbsd) || flag?(:dragonfly) %}
    # :nodoc:
    alias Backend = Crystal::EventLoop::Kqueue
  {% else %}
    # :nodoc:
    alias Backend = Crystal::EventLoop::Epoll
  {% end %}

  class EventLoop < Backend
    @@instance : EventLoop? = nil

    def self.instance : EventLoop?
      @@instance
    end

    # Called when the simulation deadlocks; by default reports and exits.
    class_property on_deadlock : Proc(String, Nil) = ->(report : String) do
      STDERR.puts report
      STDERR.flush
      exit 3
    end

    @sim_timers = [] of Timer
    @sim_seq = 0_i64

    def initialize(parallelism : Int32)
      super(parallelism)
      @@instance = self
    end

    def reset : Nil
      @sim_timers.clear
      @sim_seq = 0_i64
    end

    def pending_timers : Int32
      @sim_timers.count { |timer| !timer.cancelled? }
    end

    # :nodoc:
    def add_timer(duration : Time::Span, fiber : Fiber, kind : Timer::Kind) : Timer
      duration = Time::Span.zero if duration < Time::Span.zero
      timer = Timer.new(Sim.now_ns + duration.total_nanoseconds.to_i64, @sim_seq += 1, fiber, kind)
      # Keep the list sorted (stable for equal wake times).
      index = @sim_timers.bsearch_index { |t| (t <=> timer) > 0 } || @sim_timers.size
      @sim_timers.insert(index, timer)
      timer
    end

    def sleep(duration : ::Time::Span) : Nil
      add_timer(duration, Fiber.current, Timer::Kind::Sleep)
      Fiber.suspend
    end

    def create_timeout_event(fiber : Fiber) : Crystal::EventLoop::Event
      TimeoutEvent.new(fiber)
    end

    def run(blocking : Bool) : Bool
      # Real I/O first (never waits).
      activated = false
      system_run(false) do |fiber|
        activated = true
        Crystal::Scheduler.enqueue(fiber)
      end
      return true if activated

      while timer = @sim_timers.shift?
        next if timer.cancelled?
        Sim.advance_to(timer.wake_ns)
        case timer.kind
        in .sleep?
          Crystal::Scheduler.enqueue(timer.fiber)
          return true
        in .select_timeout?
          fiber = timer.fiber
          next unless action = fiber.timeout_select_action
          fiber.timeout_select_action = nil
          next unless action.time_expired?
          fiber.@timeout_event.as?(TimeoutEvent).try &.clear
          Crystal::Scheduler.enqueue(fiber)
          return true
        end
      end

      return false unless blocking
      EventLoop.on_deadlock.call(deadlock_report)
      false
    end

    private def deadlock_report : String
      String.build do |io|
        io << "SIMULATION DEADLOCK at t=" << Sim.elapsed << " (seed " << Sim.seed << "): "
        io << "every fiber is blocked and no timer is pending.\nFibers:\n"
        Fiber.unsafe_each do |fiber|
          io << "  " << (fiber.name || "unnamed") << (fiber.dead? ? " (dead)" : "") << '\n'
        end
      end
    end
  end
end

# --- Runtime patches ---

module Crystal::System::Time
  def self.monotonic : {Int64, Int32}
    ns = Sim.now_ns
    {ns // 1_000_000_000, (ns % 1_000_000_000).to_i32}
  end

  # Seconds since 0001-01-01 (Crystal's internal epoch), as the real
  # implementation returns.
  def self.compute_utc_seconds_and_nanoseconds : {Int64, Int32}
    elapsed = Sim.now_ns - Sim::CLOCK_START_NS
    {62_135_596_800_i64 + Sim::WALL_START_UNIX + elapsed // 1_000_000_000, (elapsed % 1_000_000_000).to_i32}
  end
end

module Random::Secure
  def next_u
    Sim.rng.next_u
  end

  def random_bytes(buf : Bytes) : Nil
    Sim.rng.random_bytes(buf)
  end
end

abstract class Crystal::EventLoop
  def self.backend_class
    Sim::EventLoop
  end
end
