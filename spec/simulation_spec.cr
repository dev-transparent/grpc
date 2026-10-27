require "./spec_helper"

# Smoke test of the deterministic simulation (spec/sim): a few seeds must
# pass the oracle and replay with identical traces. The simulator patches
# the runtime, so it is built and run as a separate program. Set
# SKIP_SIMULATION=1 to skip; run large campaigns with script/sim.sh.
private SIM_BINARY = File.expand_path("../tmp/simulation_spec_sim", __DIR__)

private def run_sim(args : Array(String)) : {Bool, String}
  output = IO::Memory.new
  status = Process.run(SIM_BINARY, args, output: output, error: output)
  {status.success?, output.to_s}
end

private def trace_hash(output : String) : String
  output[/trace=([0-9a-f]+)/, 1]
end

describe "deterministic simulation" do
  it "passes the oracle and replays identically" do
    pending!("SKIP_SIMULATION is set") if ENV["SKIP_SIMULATION"]?
    Dir.mkdir_p(File.dirname(SIM_BINARY))
    build = IO::Memory.new
    status = Process.run("crystal", ["build", "spec/sim/sim.cr", "-o", SIM_BINARY],
      output: build, error: build, chdir: File.expand_path("..", __DIR__))
    fail "Building the simulator failed:\n#{build}" unless status.success?

    runs = [{11_u64, false}, {12_u64, false}, {13_u64, false}, {14_u64, false}, {15_u64, true}, {16_u64, true}]
    runs.each do |(seed, no_faults)|
      args = ["--seed=#{seed}", "--duration=10"]
      args << "--no-faults" if no_faults
      ok, output = run_sim(args)
      fail "Seed #{seed} failed:\n#{output}" unless ok
      ok_again, again = run_sim(args)
      ok_again.should be_true
      trace_hash(again).should eq(trace_hash(output))
    end
  end
end
