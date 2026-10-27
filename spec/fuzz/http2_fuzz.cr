# Long running fuzz campaigns against the HTTP/2 layer. See script/fuzz.sh.
#
#   http2_fuzz <target|all> <iterations|duration> [seed] [crash_dir]
#   http2_fuzz replay <file.bin> [target]
#
# A duration is written with a unit suffix (`90s`, `10m`); a plain number
# is an iteration count. Failing inputs are written to *crash_dir*.
require "./support"

private def parse_budget(arg : String) : {Int32?, Time::Span?}
  case arg
  when /^(\d+)s$/ then {nil, $1.to_i.seconds}
  when /^(\d+)m$/ then {nil, $1.to_i.minutes}
  else                 {arg.to_i, nil}
  end
end

# Aborts the process (saving the current input) if an iteration hangs in
# CPU bound code, which fibers cannot preempt. Requires execution contexts.
private def start_watchdog(crash_dir : String) : Nil
  {% if flag?(:execution_context) %}
    Fiber::ExecutionContext::Isolated.new("fuzz-watchdog") do
      last = Fuzz.progress
      loop do
        sleep 30.seconds
        current = Fuzz.progress
        if current == last
          if input = Fuzz.current_input
            Dir.mkdir_p(crash_dir)
            name = "#{input[0]}-hang-#{Digest::SHA1.hexdigest(input[1])[0, 16]}"
            File.write(File.join(crash_dir, "#{name}.bin"), input[1])
            STDERR.puts "HANG detected, input saved to #{name}.bin"
          end
          exit 3
        end
        last = current
      end
    end
  {% end %}
end

if ARGV[0]? == "replay"
  path = ARGV[1]? || abort("usage: http2_fuzz replay <file.bin> [target]")
  target = ARGV[2]? || File.basename(path).split('-').first
  campaign = Fuzz::Campaign.new(0_u64)
  begin
    campaign.execute(target, File.read(path).to_slice)
    puts "#{path}: OK"
  rescue e : Fuzz::Failure
    puts "#{path}: FAILURE #{e.message}"
    exit 1
  end
  exit 0
end

targets = ARGV[0]? || "all"
budget = ARGV[1]? || "1000"
seed = (ARGV[2]? || Random::Secure.rand(UInt32::MAX).to_s).to_u64
crash_dir = ARGV[3]? || "tmp/fuzz/crashes"
iterations, duration = parse_budget(budget)
list = targets == "all" ? Fuzz::TARGETS : targets.split(',')
Log.setup(:none)

puts "seed=#{seed} targets=#{list.join(',')} budget=#{budget}"
start_watchdog(crash_dir)
campaign = Fuzz::Campaign.new(seed, crash_dir, STDOUT)
total_failures = 0
list.each do |target|
  started = Time.instant
  before = campaign.iterations
  failures_before = campaign.failures.size
  per_target = duration.try { |d| d / list.size }
  campaign.run(target, iterations, per_target)
  elapsed = Time.instant - started
  count = campaign.iterations - before
  failures = campaign.failures.size - failures_before
  total_failures += failures
  puts "#{target}: #{count} iterations in #{elapsed.total_seconds.round(1)}s (#{(count / elapsed.total_seconds).round}/s), #{failures} failures"
end
exit(total_failures > 0 ? 1 : 0)
