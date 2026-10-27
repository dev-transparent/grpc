require "spec"
require "./support"

# Short, deterministic (fixed seed) fuzz runs. Long randomized campaigns:
# `script/fuzz.sh`.
private CAMPAIGN = Fuzz::Campaign.new(20_261_026_u64)

private def fuzz(target : String, iterations : Int32)
  CAMPAIGN.run(target, iterations)
  failures = CAMPAIGN.failures.select { |(name, _, _)| name == target }
  failures.each do |(_, input, message)|
    puts "\n[#{target}] #{message}\ninput: #{input.hexstring}"
  end
  failures.size.should eq(0)
end

describe "HTTP/2 fuzzing" do
  it "keeps Frame.read within its error contract" do
    fuzz("frame", 3_000)
  end

  it "keeps a server connection well behaved on mutated client traffic" do
    fuzz("server", 600)
  end

  it "keeps a client connection well behaved on mutated server traffic" do
    fuzz("client", 600)
  end

  it "runs the unmutated seed corpus cleanly" do
    {"server", "client", "frame"}.each do |target|
      CAMPAIGN.corpus(target).each_with_index do |input, index|
        CAMPAIGN.execute(target, input, index)
      end
    end
  end

  describe Fuzz::Mutator do
    it "is deterministic for a seed" do
      corpus = [Bytes[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]]
      a = Fuzz::Mutator.new(Random.new(7), corpus)
      b = Fuzz::Mutator.new(Random.new(7), corpus)
      10.times { a.mutate(corpus[0]).should eq(b.mutate(corpus[0])) }
    end

    it "splits traffic into the preface and frames" do
      bytes = HTTP2::Connection::CLIENT_PREFACE.to_a + HTTP2::SettingsFrame.new.to_slice.to_a +
              HTTP2::PingFrame.new.to_slice.to_a + [1_u8, 2_u8]
      prefix, frames, rest = Fuzz.split_frames(bytes)
      prefix.size.should eq(24)
      frames.size.should eq(2)
      rest.should eq([1_u8, 2_u8])
    end
  end
end
