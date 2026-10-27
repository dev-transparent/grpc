module HTTP2::HPACK
  # Raised when a header block cannot be decoded. This is a connection error
  # of type COMPRESSION_ERROR.
  class DecompressionError < Exception
  end

  # The static table from RFC 7541 Appendix A (1-indexed).
  STATIC_TABLE = [
    {":authority", ""},
    {":method", "GET"},
    {":method", "POST"},
    {":path", "/"},
    {":path", "/index.html"},
    {":scheme", "http"},
    {":scheme", "https"},
    {":status", "200"},
    {":status", "204"},
    {":status", "206"},
    {":status", "304"},
    {":status", "400"},
    {":status", "404"},
    {":status", "500"},
    {"accept-charset", ""},
    {"accept-encoding", "gzip, deflate"},
    {"accept-language", ""},
    {"accept-ranges", ""},
    {"accept", ""},
    {"access-control-allow-origin", ""},
    {"age", ""},
    {"allow", ""},
    {"authorization", ""},
    {"cache-control", ""},
    {"content-disposition", ""},
    {"content-encoding", ""},
    {"content-language", ""},
    {"content-length", ""},
    {"content-location", ""},
    {"content-range", ""},
    {"content-type", ""},
    {"cookie", ""},
    {"date", ""},
    {"etag", ""},
    {"expect", ""},
    {"expires", ""},
    {"from", ""},
    {"host", ""},
    {"if-match", ""},
    {"if-modified-since", ""},
    {"if-none-match", ""},
    {"if-range", ""},
    {"if-unmodified-since", ""},
    {"last-modified", ""},
    {"link", ""},
    {"location", ""},
    {"max-forwards", ""},
    {"proxy-authenticate", ""},
    {"proxy-authorization", ""},
    {"range", ""},
    {"referer", ""},
    {"refresh", ""},
    {"retry-after", ""},
    {"server", ""},
    {"set-cookie", ""},
    {"strict-transport-security", ""},
    {"transfer-encoding", ""},
    {"user-agent", ""},
    {"vary", ""},
    {"via", ""},
    {"www-authenticate", ""},
  ]

  STATIC_TABLE_SIZE = STATIC_TABLE.size

  # Maps {name, value} to its static index.
  STATIC_FIELD_INDEX = begin
    index = {} of {String, String} => Int32
    STATIC_TABLE.each_with_index { |field, i| index[field] ||= i + 1 }
    index
  end

  # Maps name to the lowest static index carrying that name.
  STATIC_NAME_INDEX = begin
    index = {} of String => Int32
    STATIC_TABLE.each_with_index { |(name, _), i| index[name] ||= i + 1 }
    index
  end

  # Per-entry overhead used when computing table sizes (RFC 7541 section 4.1).
  ENTRY_OVERHEAD = 32

  # The dynamic table (RFC 7541 section 2.3.2). The most recently inserted
  # entry has the lowest index.
  class DynamicTable
    getter size : Int32 = 0
    getter max_size : Int32

    def initialize(@max_size : Int32 = 4096)
      @entries = Deque({String, String}).new
    end

    def length : Int32
      @entries.size
    end

    # Returns the entry at the 0-based dynamic index, or `nil`.
    def [](index : Int32) : {String, String}?
      @entries[index]?
    end

    def self.entry_size(name : String, value : String) : Int32
      name.bytesize + value.bytesize + ENTRY_OVERHEAD
    end

    def add(name : String, value : String) : Nil
      entry_size = DynamicTable.entry_size(name, value)
      if entry_size > @max_size
        # Adding an entry larger than the table empties it (section 4.4).
        @entries.clear
        @size = 0
        return
      end
      evict(@max_size - entry_size)
      @entries.unshift({name, value})
      @size += entry_size
    end

    def max_size=(max_size : Int32) : Nil
      @max_size = max_size
      evict(max_size)
    end

    # Returns the 0-based index of an entry matching name and value, and of an
    # entry matching only the name.
    def find(name : String, value : String) : {Int32?, Int32?}
      name_index = nil
      @entries.each_with_index do |(n, v), i|
        if n == name
          return {i, i} if v == value
          name_index ||= i
        end
      end
      {nil, name_index}
    end

    private def evict(target : Int32)
      while @size > target && (entry = @entries.pop?)
        @size -= DynamicTable.entry_size(*entry)
      end
    end
  end
end
