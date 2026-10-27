# Deterministic simulation test of the gRPC stack.
#
# Runs real gRPC servers and clients (HTTP/2, protobuf, load balancing,
# retries, keepalive, ...) on a simulated network with virtual time, under a
# randomized workload and fault schedule derived from a seed, and checks the
# results with an oracle. Every run is a pure function of its seed, so any
# failure can be replayed exactly:
#
#   crystal build spec/sim/sim.cr -o bin/sim
#   bin/sim --seed=1234             # one seed
#   bin/sim --seed=1234 --verbose   # with the full event trace
#   script/sim.sh 500               # many seeds in parallel
#
# Output: one summary line including a hash of the event trace; running the
# same seed twice must print the same hash. Exits 1 if the oracle found
# violations, 3 on a simulation deadlock.
require "option_parser"
require "./world"

seed = 1_u64
duration = 30.seconds
verbose = false
faults = true

OptionParser.parse do |parser|
  parser.on("--seed=SEED", "Simulation seed") { |value| seed = value.to_u64 }
  parser.on("--duration=SECONDS", "Virtual duration of the workload") { |value| duration = value.to_f.seconds }
  parser.on("--verbose", "Print the event trace") { verbose = true }
  parser.on("--no-faults", "Disable fault injection") { faults = false }
end

Log.setup(:none)
Sim.reset(seed)
trace = Sim::Trace.new
trace.verbose = verbose
config = Sim::Config.new(Random::PCG32.new(seed), duration, faults)
world = Sim::World.new(config, trace)
violations = world.run

ops = world.clients.sum(&.ops.size)
codes = world.clients.flat_map(&.ops).compact_map(&.code).tally.to_a.sort_by! { |(code, _)| code.value }
summary = codes.map { |(code, count)| "#{code}=#{count}" }.join(" ")
puts "seed=#{seed} #{config} ops=#{ops} [#{summary}] virtual=#{Sim.elapsed} events=#{trace.events} trace=#{trace.hash.to_s(16)} #{violations.empty? ? "OK" : "FAILED"}"
violations.first(20).each { |violation| puts "  VIOLATION #{violation}" }
puts "  ... #{violations.size - 20} more" if violations.size > 20
exit(violations.empty? ? 0 : 1)
