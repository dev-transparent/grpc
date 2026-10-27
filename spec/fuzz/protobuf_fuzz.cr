# Long randomized fuzzing campaigns for the protobuf runtime (see
# script/fuzz_protobuf.sh):
#
#   crystal build --release spec/fuzz/protobuf_fuzz.cr -o bin/protobuf_fuzz
#   bin/protobuf_fuzz [--seed N] [--seconds N] [--out DIR] [binary|json|proto|python ...]
#
# Runs each target for the given time (in rounds of a few thousand inputs)
# and writes failing inputs to DIR (default tmp/fuzz/protobuf). The `python`
# target compares the binary decoder with Python's protobuf on mutated
# inputs (requires PYTHON with protobuf and grpcio-tools).
require "./protobuf_fuzz_support"
require "./protobuf_python_differential"

seed = Random.new.rand(UInt64::MAX)
seconds = 60
out_dir = File.join(ProtobufFuzz::ROOT, "tmp", "fuzz", "protobuf")
targets = [] of String
args = ARGV.dup
until args.empty?
  case arg = args.shift
  when "--seed"    then seed = args.shift.to_u64
  when "--seconds" then seconds = args.shift.to_i
  when "--out"     then out_dir = args.shift
  else                  targets << arg
  end
end
targets = %w(binary json proto python) if targets.empty?
Dir.mkdir_p(out_dir)

total_findings = 0
targets.each do |target|
  campaign = ProtobufFuzz::Campaign.new(seed)
  deadline = Time.instant + seconds.seconds
  rounds = 0
  python = target == "python" ? ProtobufFuzz::PythonDifferential.new(seed) : nil
  if target == "python" && !python.try(&.available?)
    puts "[python] skipped: Python protobuf is not available"
    next
  end
  while Time.instant < deadline
    case target
    when "binary" then campaign.fuzz_binary(2_000)
    when "json"   then campaign.fuzz_json(1_000)
    when "proto"  then campaign.fuzz_proto(300)
    when "python" then python.not_nil!.run(500)
    else               abort "unknown target #{target}"
    end
    rounds += 1
  end
  findings = python ? python.findings : campaign.findings
  executions = python ? python.executions : campaign.executions
  findings.each_with_index do |finding, i|
    File.write(File.join(out_dir, "#{target}-#{seed}-#{i}.bin"), finding.input)
    File.write(File.join(out_dir, "#{target}-#{seed}-#{i}.txt"), finding.message)
  end
  extra = python ? "" : ", accepted #{campaign.accepted[target]? || 0}, rejected #{campaign.rejected[target]? || 0}"
  puts "[#{target}] seed #{seed}: #{executions} executions in #{rounds} rounds#{extra}, #{findings.size} findings"
  findings.first(5).each { |finding| puts "  #{finding.message.lines.first}\n  input: #{finding.input.hexstring[0, 200]}" }
  total_findings += findings.size
end
exit(total_findings == 0 ? 0 : 1)
