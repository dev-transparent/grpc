require "./huffman_table"

module HTTP2::HPACK
  # Huffman coding as defined in RFC 7541 section 5.2 and Appendix B.
  module Huffman
    EOS = 256

    # Binary decoding tree stored as a flat array. Node `n` has children at
    # `TREE[n * 2]` (bit 0) and `TREE[n * 2 + 1]` (bit 1). A negative value
    # `-(sym + 1)` denotes a leaf for symbol `sym`; zero means "no child".
    TREE = begin
      tree = Array(Int32).new(1024, 0)
      next_node = 1
      CODES.each_with_index do |(code, length), sym|
        node = 0
        (length - 1).downto(0) do |i|
          bit = ((code >> i) & 1).to_i32
          slot = node * 2 + bit
          if i == 0
            tree[slot] = -(sym + 1)
          else
            if tree[slot] == 0
              tree[slot] = next_node
              next_node += 1
            end
            node = tree[slot]
          end
        end
      end
      tree
    end

    # Returns the number of octets *data* occupies once Huffman encoded.
    def self.encoded_size(data : Bytes) : Int32
      bits = 0_i64
      data.each { |byte| bits += CODES[byte][1] }
      ((bits + 7) // 8).to_i32
    end

    # Huffman encodes *data* into *io*.
    def self.encode(data : Bytes, io : IO) : Nil
      acc = 0_u64
      bits = 0
      data.each do |byte|
        code, length = CODES[byte]
        acc = (acc << length) | code
        bits += length
        while bits >= 8
          bits -= 8
          io.write_byte((acc >> bits).to_u8!)
        end
        acc &= (1_u64 << bits) - 1
      end
      if bits > 0
        # Pad with the most significant bits of EOS (all ones).
        io.write_byte(((acc << (8 - bits)) | (0xff_u64 >> bits)).to_u8!)
      end
    end

    def self.encode(data : Bytes) : Bytes
      io = IO::Memory.new(encoded_size(data))
      encode(data, io)
      io.to_slice
    end

    # Decodes Huffman encoded *data*. Raises `DecompressionError` if the data
    # contains the EOS symbol or invalid padding.
    def self.decode(data : Bytes) : Bytes
      io = IO::Memory.new(data.size * 8 // 5 + 1)
      node = 0
      pad_bits = 0
      pad_all_ones = true
      data.each do |byte|
        7.downto(0) do |i|
          bit = (byte >> i) & 1
          child = TREE[node * 2 + bit]
          pad_bits += 1
          pad_all_ones &&= bit == 1
          if child < 0
            sym = -child - 1
            raise DecompressionError.new("EOS symbol in Huffman encoded string") if sym == EOS
            io.write_byte(sym.to_u8)
            node = 0
            pad_bits = 0
            pad_all_ones = true
          elsif child == 0
            raise DecompressionError.new("Invalid Huffman code")
          else
            node = child
          end
        end
      end
      raise DecompressionError.new("Huffman padding longer than 7 bits") if pad_bits > 7
      raise DecompressionError.new("Huffman padding is not a prefix of EOS") unless pad_all_ones
      io.to_slice
    end
  end
end
