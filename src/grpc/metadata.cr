require "base64"

module GRPC
  # Custom metadata sent with a call as headers or trailers. Keys are
  # case-insensitive (stored lowercase) and may have multiple values.
  #
  # Keys ending in `-bin` carry binary values; they are base64 encoded on the
  # wire transparently, so their values are raw bytes stored in a `String`.
  #
  # ```
  # metadata = GRPC::Metadata{"authorization" => "Bearer token"}
  # metadata.add("trace-bin", Bytes[1, 2, 3])
  # metadata["authorization"] # => "Bearer token"
  # ```
  class Metadata
    include Enumerable({String, String})

    # Headers managed by the gRPC protocol itself, never exposed as metadata.
    RESERVED = Set{
      "content-type", "te", "user-agent", "host", "content-length", "connection",
      "grpc-timeout", "grpc-encoding", "grpc-accept-encoding", "grpc-status",
      "grpc-message", "grpc-status-details-bin", "accept-encoding", "content-encoding",
    }

    class InvalidError < ArgumentError
    end

    @entries = [] of {String, String}

    def initialize
    end

    def initialize(hash : Hash(String, String))
      hash.each { |key, value| add(key, value) }
    end

    def self.new(metadata : Metadata) : Metadata
      metadata.dup
    end

    # Returns the first value for *key*. Raises `KeyError` if missing.
    def [](key : String) : String
      self[key]? || raise KeyError.new("Missing metadata key #{key.inspect}")
    end

    # Returns the first value for *key*, or `nil`.
    def []?(key : String) : String?
      key = key.downcase
      @entries.each { |(k, v)| return v if k == key }
      nil
    end

    # Replaces all values of *key* with *value*.
    def []=(key : String, value : String | Bytes) : Nil
      delete(key)
      add(key, value)
    end

    # Adds a value for *key*, keeping existing values.
    def add(key : String, value : String | Bytes) : self
      key = Metadata.validate_key(key)
      value = String.new(value) if value.is_a?(Bytes)
      Metadata.validate_value(key, value)
      @entries << {key, value}
      self
    end

    # Returns all values for *key*.
    def get_all(key : String) : Array(String)
      key = key.downcase
      @entries.compact_map { |(k, v)| v if k == key }
    end

    def has_key?(key : String) : Bool
      key = key.downcase
      @entries.any? { |(k, _)| k == key }
    end

    # Removes all values for *key*.
    def delete(key : String) : Nil
      key = key.downcase
      @entries.reject! { |(k, _)| k == key }
    end

    def each(& : {String, String} ->) : Nil
      @entries.each { |entry| yield entry }
    end

    def size : Int32
      @entries.size
    end

    def empty? : Bool
      @entries.empty?
    end

    def keys : Array(String)
      @entries.map(&.[0]).uniq!
    end

    # Adds all entries of *other*.
    def merge!(other : Metadata) : self
      other.each { |(key, value)| @entries << {key, value} }
      self
    end

    def dup : Metadata
      copy = Metadata.new
      copy.merge!(self)
    end

    # Returns a hash of the first value of each key.
    def to_h : Hash(String, String)
      hash = {} of String => String
      @entries.each { |(k, v)| hash[k] = v unless hash.has_key?(k) }
      hash
    end

    def ==(other : Metadata) : Bool
      to_a == other.to_a
    end

    def inspect(io : IO) : Nil
      io << "GRPC::Metadata{"
      @entries.each_with_index do |(k, v), i|
        io << ", " if i > 0
        k.inspect(io)
        io << " => "
        v.inspect(io)
      end
      io << '}'
    end

    # Converts metadata to HTTP/2 header fields, base64-encoding binary
    # values.
    def to_fields(fields : Array({String, String}) = [] of {String, String}) : Array({String, String})
      @entries.each do |(key, value)|
        if key.ends_with?("-bin")
          fields << {key, Base64.strict_encode(value).rstrip('=')}
        else
          fields << {key, value}
        end
      end
      fields
    end

    # Builds metadata from HTTP/2 header fields, skipping pseudo-headers and
    # reserved headers, and decoding binary values.
    def self.from_fields(fields : Enumerable({String, String})) : Metadata
      metadata = Metadata.new
      fields.each do |(key, value)|
        next if key.starts_with?(':') || RESERVED.includes?(key)
        if key.ends_with?("-bin")
          decoded = begin
            Base64.decode_string(value)
          rescue Base64::Error
            next
          end
          metadata.add_unchecked(key, decoded)
        else
          metadata.add_unchecked(key, value)
        end
      end
      metadata
    end

    protected def add_unchecked(key : String, value : String) : Nil
      @entries << {key, value}
    end

    # Validates and normalizes a metadata key.
    def self.validate_key(key : String) : String
      key = key.downcase
      raise InvalidError.new("Empty metadata key") if key.empty?
      key.each_char do |char|
        unless char.ascii_lowercase? || char.ascii_number? || char.in?('-', '_', '.')
          raise InvalidError.new("Invalid metadata key #{key.inspect}")
        end
      end
      raise InvalidError.new("Reserved metadata key #{key.inspect}") if RESERVED.includes?(key) || key.starts_with?("grpc-")
      key
    end

    # Validates an ASCII metadata value.
    def self.validate_value(key : String, value : String) : Nil
      return if key.ends_with?("-bin")
      value.each_byte do |byte|
        unless 0x20 <= byte <= 0x7e
          raise InvalidError.new("Invalid character in value of metadata key #{key.inspect}; use a -bin key for binary data")
        end
      end
    end
  end
end
