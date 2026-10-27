require "spec"
require "./support"

describe "HPACK fuzzing" do
  it "keeps the decoder within its limits and error contract" do
    campaign = Fuzz::Campaign.new(4_242_u64)
    campaign.run("hpack", 3_000)
    campaign.failures.each { |(_, input, message)| puts "\n#{message}\ninput: #{input.hexstring}" }
    campaign.failures.should be_empty
  end

  it "round trips random strings through Huffman coding" do
    random = Random.new(99)
    500.times do
      bytes = Bytes.new(random.rand(64)) { random.rand(256).to_u8 }
      HTTP2::HPACK::Huffman.decode(HTTP2::HPACK::Huffman.encode(bytes)).should eq(bytes)
    end
  end

  it "rejects random Huffman input only with DecompressionError" do
    random = Random.new(100)
    2_000.times do
      bytes = Bytes.new(random.rand(16)) { random.rand(256).to_u8 }
      begin
        HTTP2::HPACK::Huffman.decode(bytes)
      rescue HTTP2::HPACK::DecompressionError
      end
    end
  end

  it "round trips random header lists through an encoder and decoder pair" do
    random = Random.new(101)
    encoder = HTTP2::HPACK::Encoder.new
    decoder = HTTP2::HPACK::Decoder.new
    names = %w(:path content-type x-a x-b cookie authorization set-cookie user-agent)
    300.times do
      list = Array.new(random.rand(8)) do
        value = String.new(Bytes.new(random.rand(40)) { (32 + random.rand(95)).to_u8 })
        {names.sample(random), value}
      end
      if random.rand(10) == 0
        encoder.peer_max_table_size = [0, 64, 256, 4096].sample(random)
      end
      decoder.decode(encoder.encode(list)).should eq(list)
      decoder.table.size.should be <= 4096
    end
  end
end
