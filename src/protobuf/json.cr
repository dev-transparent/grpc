require "json"
require "base64"

module Protobuf
  # The proto3 JSON mapping (https://protobuf.dev/programming-guides/json/).
  #
  # Every message gets JSON methods:
  #
  # ```
  # json = message.to_json                      # compact JSON
  # json = message.to_json(emit_defaults: true) # with options
  # message = Foo.from_json(json)               # parse
  # message = Foo.from_json(json, ignore_unknown_fields: true)
  # ```
  #
  # Messages also implement `to_json(JSON::Builder)` and
  # `.new(JSON::PullParser)`, so they work with the standard library
  # (`[message].to_json`, `Array(Foo).from_json(...)`), using the default
  # options. Well-known types use their special JSON representations;
  # `google.protobuf.Any` resolves types through `Protobuf::Registry`.
  #
  # NOTE: inside `module Protobuf`, `JSON` refers to this module; use
  # `::JSON` for the standard library.
  module JSON
    # Raised when JSON input cannot be parsed as the requested message.
    class ParseError < Protobuf::Error
    end

    # Raised when a message cannot be represented in JSON (e.g. a
    # `Timestamp` out of range, or an `Any` whose type is not registered).
    class SerializeError < Protobuf::Error
    end

    # Options for printing messages as JSON.
    record PrintOptions,
      # Print fields without presence (proto3 scalars, repeated and map
      # fields) even when they hold their default value. Also known as
      # `always_print_fields_with_no_presence`.
      emit_defaults : Bool = false,
      # Use the original proto field names instead of lowerCamelCase JSON
      # names.
      preserve_proto_field_names : Bool = false,
      # Print enum values as numbers instead of names.
      enums_as_ints : Bool = false,
      # Nesting of `Any` values being printed (internal).
      any_depth : Int32 = 0

    # Options for parsing JSON into messages.
    record ParseOptions,
      # Skip unknown fields (and unknown enum value names) instead of
      # raising `ParseError`.
      ignore_unknown_fields : Bool = false,
      # Maximum nesting depth of messages.
      recursion_limit : Int32 = DEFAULT_RECURSION_LIMIT

    # Holds the parse options and nesting depth while parsing.
    # :nodoc:
    class Context
      getter options : ParseOptions
      property depth : Int32 = 0

      def initialize(@options : ParseOptions)
      end

      def ignore_unknown_fields? : Bool
        @options.ignore_unknown_fields
      end

      def nest(pull : ::JSON::PullParser, &)
        @depth += 1
        JSON.error(pull, "Message nesting exceeds the recursion limit") if @depth > @options.recursion_limit
        begin
          yield
        ensure
          @depth -= 1
        end
      end
    end

    # :nodoc:
    def self.error(pull : ::JSON::PullParser?, message : String) : NoReturn
      if pull
        raise ParseError.new("#{message} at line #{pull.line_number}, column #{pull.column_number}")
      else
        raise ParseError.new(message)
      end
    end

    # Runs the block, converting errors of the standard JSON parser into
    # `ParseError`.
    # :nodoc:
    def self.parsing(&)
      yield
    rescue ex : ::JSON::ParseException
      raise ParseError.new(ex.message, cause: ex)
    rescue ex : ArgumentError | OverflowError | IndexError
      # Defensive: invalid input must surface as a ParseError.
      raise ParseError.new(ex.message || ex.class.name, cause: ex)
    end

    # Parses a complete JSON document as message *type*.
    # :nodoc:
    def self.parse_document(input : String | IO, type : T.class, options : ParseOptions) : T forall T
      parsing do
        pull = ::JSON::PullParser.new(validated(input))
        message = read_message(pull, T, Context.new(options))
        error(pull, "Unexpected content after the JSON value") unless pull.kind.eof?
        message
      end
    end

    # Returns *input* as a string, raising `ParseError` unless it is valid
    # UTF-8 (the JSON parser does not check strings).
    # :nodoc:
    def self.validated(input : String | IO) : String
      text = input.is_a?(IO) ? input.gets_to_end : input
      raise ParseError.new("JSON input is not valid UTF-8") unless text.valid_encoding?
      text
    end

    # :nodoc:
    def self.read_message(pull : ::JSON::PullParser, type : T.class, context : Context) : T forall T
      message = T.new
      context.nest(pull) { message.protobuf_json_merge(pull, context) }
      message
    end

    # Writes a message as a complete JSON document.
    # :nodoc:
    def self.generate(message : Protobuf::Message, options : PrintOptions, indent : String? = nil) : String
      String.build { |io| generate(io, message, options, indent) }
    end

    # :nodoc:
    def self.generate(io : IO, message : Protobuf::Message, options : PrintOptions, indent : String? = nil) : Nil
      builder = ::JSON::Builder.new(io)
      builder.indent = indent if indent
      # Nesting is bounded by the decoder's and `Any`'s recursion limits.
      builder.max_nesting = 100_000
      builder.document { message.protobuf_json_write(builder, options) }
    rescue ex : ::JSON::Error
      raise SerializeError.new(ex.message, cause: ex)
    end

    # --- Field names ---

    # The default JSON name of a field (protoc's `ToJsonName`).
    def self.json_name(name : String) : String
      String.build do |io|
        capitalize_next = false
        name.each_char do |char|
          if char == '_'
            capitalize_next = true
          elsif capitalize_next
            io << char.upcase
            capitalize_next = false
          else
            io << char
          end
        end
      end
    end

    # --- Writing values ---

    # Writes *value* (any field value type) as JSON.
    # :nodoc:
    def self.write_value(json : ::JSON::Builder, value : T, options : PrintOptions) : Nil forall T
      {% if T <= ::Protobuf::Message %}
        value.protobuf_json_write(json, options)
      {% elsif T < ::Enum %}
        write_enum(json, value, options)
      {% elsif T <= ::Array %}
        json.array { value.each { |element| write_value(json, element, options) } }
      {% elsif T == ::Int32 || T == ::UInt32 %}
        json.number(value)
      {% elsif T == ::Int64 || T == ::UInt64 %}
        json.string(value.to_s)
      {% elsif T == ::Float32 || T == ::Float64 %}
        write_float(json, value)
      {% elsif T == ::Bool %}
        json.bool(value)
      {% elsif T == ::String %}
        json.string(check_utf8(value))
      {% elsif T == ::Bytes %}
        json.string(Base64.strict_encode(value))
      {% else %}
        {% raise "Unsupported protobuf JSON value type #{T}" %}
      {% end %}
    end

    # :nodoc:
    def self.write_float(json : ::JSON::Builder, value : Float32 | Float64) : Nil
      if value.nan?
        json.string("NaN")
      elsif value.infinite?
        json.string(value > 0 ? "Infinity" : "-Infinity")
      else
        json.raw(format_float(value))
      end
    end

    # Formats a finite float as a JSON number using the shortest
    # representation that round trips ("1.5", "-0.0", "1.0e+20").
    # :nodoc:
    def self.format_float(value : Float32 | Float64) : String
      value.to_s
    end

    # :nodoc:
    def self.write_enum(json : ::JSON::Builder, value : T, options : PrintOptions) : Nil forall T
      {% if T.annotation(::Protobuf::TypeName) && T.annotation(::Protobuf::TypeName)[0] == "google.protobuf.NullValue" %}
        json.null
      {% else %}
        if !options.enums_as_ints && (name = enum_name(value))
          json.string(name)
        else
          json.number(value.value.to_i32!)
        end
      {% end %}
    end

    # Returns the proto name of an enum value, or `nil` for unknown values.
    def self.enum_name(value : T) : String? forall T
      {% begin %}
        {% overrides = T.annotation(::Protobuf::EnumValueNames) %}
        {% overrides = overrides ? overrides[0] : {} of Nil => Nil %}
        {% seen = [] of Nil %}
        case value.value
        {% for c in T.constants %}
          {% v = T.constant(c) %}
          {% unless seen.includes?(v) %}
            {% seen << v %}
            when {{v}} then {{overrides[c.stringify] || c.stringify}}
          {% end %}
        {% end %}
        else
          nil
        end
      {% end %}
    end

    # Returns the enum value with the proto name *name*, or `nil`.
    def self.enum_value(type : T.class, name : String) : T? forall T
      {% begin %}
        {% overrides = T.annotation(::Protobuf::EnumValueNames) %}
        {% overrides = overrides ? overrides[0] : {} of Nil => Nil %}
        case name
        {% for c in T.constants %}
          when {{overrides[c.stringify] || c.stringify}} then T.new({{T.constant(c)}})
        {% end %}
        else
          nil
        end
      {% end %}
    end

    # Returns the JSON object key for a map key.
    # :nodoc:
    def self.map_key(key) : String
      key.is_a?(String) ? check_utf8(key) : key.to_s
    end

    # Returns *value*, raising `SerializeError` if it is not valid UTF-8
    # (possible in proto2 strings, which are not validated when parsed).
    # :nodoc:
    def self.check_utf8(value : String) : String
      raise SerializeError.new("String field contains invalid UTF-8") unless value.valid_encoding?
      value
    end

    # --- Reading values ---

    # Reads a value of *type* (any field value type). Returns `nil` only
    # for unknown enum value names when unknown fields are ignored.
    # :nodoc:
    def self.read_value(pull : ::JSON::PullParser, type : T.class, context : Context) : T? forall T
      {% if T <= ::Protobuf::Message %}
        read_message(pull, T, context)
      {% elsif T < ::Enum %}
        read_enum(pull, T, context)
      {% elsif T == ::Int32 || T == ::Int64 || T == ::UInt32 || T == ::UInt64 %}
        read_integer(pull, T)
      {% elsif T == ::Float32 || T == ::Float64 %}
        read_float(pull, T)
      {% elsif T == ::Bool %}
        error(pull, "Expected a boolean, found #{describe(pull)}") unless pull.kind.bool?
        pull.read_bool
      {% elsif T == ::String %}
        error(pull, "Expected a string, found #{describe(pull)}") unless pull.kind.string?
        pull.read_string
      {% elsif T == ::Bytes %}
        error(pull, "Expected a base64 string, found #{describe(pull)}") unless pull.kind.string?
        decode_base64(pull.read_string) || error(pull, "Invalid base64 data")
      {% else %}
        {% raise "Unsupported protobuf JSON value type #{T}" %}
      {% end %}
    end

    # :nodoc:
    def self.describe(pull : ::JSON::PullParser) : String
      case pull.kind
      when .null?         then "null"
      when .bool?         then "a boolean"
      when .int?, .float? then "a number"
      when .string?       then "a string"
      when .begin_array?  then "an array"
      when .begin_object? then "an object"
      else                     pull.kind.to_s
      end
    end

    # :nodoc:
    def self.read_enum(pull : ::JSON::PullParser, type : T.class, context : Context) : T? forall T
      case pull.kind
      when .string?
        name = pull.read_string
        if value = enum_value(T, name)
          return value
        end
        return nil if context.ignore_unknown_fields?
        error(pull, "Unknown value #{name.inspect} for enum #{enum_type_name(T)}")
      when .int?, .float?
        number = parse_integer(pull.raw_value)
        unless number && Int32::MIN <= number <= Int32::MAX
          error(pull, "Invalid value #{pull.raw_value} for enum #{enum_type_name(T)}")
        end
        pull.read_next
        value = T.new(number.to_i32)
        {% if T.annotation(::Protobuf::ClosedEnum) %}
          unless T.valid?(value)
            return nil if context.ignore_unknown_fields?
            error(pull, "Unknown value #{number} for closed enum #{enum_type_name(T)}")
          end
        {% end %}
        value
      when .null?
        {% if T.annotation(::Protobuf::TypeName) && T.annotation(::Protobuf::TypeName)[0] == "google.protobuf.NullValue" %}
          pull.read_null
          T.new(0)
        {% else %}
          error(pull, "Expected an enum value for #{enum_type_name(T)}, found null")
        {% end %}
      else
        error(pull, "Expected an enum value for #{enum_type_name(T)}, found #{describe(pull)}")
      end
    end

    # :nodoc:
    def self.enum_type_name(type : T.class) : String forall T
      {% if ann = T.annotation(::Protobuf::TypeName) %}
        {{ann[0]}}
      {% else %}
        {{T.stringify}}
      {% end %}
    end

    # Integer field values are JSON numbers or strings; exponent notation
    # is accepted when the value is integral.
    # :nodoc:
    def self.read_integer(pull : ::JSON::PullParser, type : T.class) : T forall T
      text = case pull.kind
             when .int?, .float?
               pull.raw_value.tap { pull.read_next }
             when .string?
               pull.read_string
             else
               error(pull, "Expected an integer, found #{describe(pull)}")
             end
      value = parse_integer(text) || error(pull, "Invalid integer #{text.inspect}")
      unless T::MIN <= value <= T::MAX
        error(pull, "Integer #{text} is out of range for #{T}")
      end
      T.new(value)
    end

    NUMBER = /\A(-)?(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?\z/

    # Parses a JSON number that must denote an integer (exactly, without
    # going through floating point). Returns `nil` if *text* is not a
    # number or not integral.
    # :nodoc:
    def self.parse_integer(text : String) : Int128?
      return nil if text.bytesize > 64
      match = NUMBER.match(text) || return nil
      fraction = match[3]? || ""
      exponent = match[4]?.try { |e| e.to_i? || return nil } || 0
      digits = (match[2] + fraction).lstrip('0')
      return 0.to_i128 if digits.empty?
      shift = exponent.to_i64 - fraction.size
      if shift >= 0
        return nil if digits.size + shift > 39
        digits += "0" * shift
      else
        cut = -shift
        return nil if cut >= digits.size
        return nil unless digits[(digits.size - cut)..].each_char.all?('0')
        digits = digits[0, digits.size - cut]
      end
      value = digits.to_i128? || return nil
      match[1]? ? -value : value
    end

    # :nodoc:
    def self.read_float(pull : ::JSON::PullParser, type : T.class) : T forall T
      text = case pull.kind
             when .int?, .float?
               pull.raw_value.tap { pull.read_next }
             when .string?
               pull.read_string
             else
               error(pull, "Expected a number, found #{describe(pull)}")
             end
      value = case text
              when "NaN"       then Float64::NAN
              when "Infinity"  then Float64::INFINITY
              when "-Infinity" then -Float64::INFINITY
              else
                error(pull, "Invalid number #{text.inspect}") unless NUMBER.matches?(text)
                parsed = text.to_f64? || error(pull, "Number #{text} is out of range")
                error(pull, "Number #{text} is out of range") if parsed.infinite?
                {% if T == ::Float32 %}
                  # Values that round to the largest float are accepted.
                  error(pull, "Number #{text} is out of range for float") if parsed.to_f32!.infinite?
                {% end %}
                parsed
              end
      {% if T == ::Float32 %}
        value.to_f32!
      {% else %}
        value
      {% end %}
    end

    # Decodes standard or URL-safe base64, with or without padding.
    # Returns `nil` if *text* is not valid base64.
    def self.decode_base64(text : String) : Bytes?
      bytes = text.to_slice
      size = bytes.size
      while size > 0 && bytes[size - 1] == '='.ord
        size -= 1
      end
      padding = bytes.size - size
      return nil if padding > 2
      return nil if padding > 0 && bytes.size % 4 != 0
      return nil if size % 4 == 1
      output = Bytes.new(size * 3 // 4)
      buffer = 0_u32
      bits = 0
      out_pos = 0
      size.times do |i|
        sextet = base64_value(bytes[i]) || return nil
        buffer = (buffer << 6) | sextet
        bits += 6
        if bits >= 8
          bits -= 8
          output[out_pos] = ((buffer >> bits) & 0xff).to_u8
          out_pos += 1
        end
      end
      output[0, out_pos]
    end

    private def self.base64_value(byte : UInt8) : UInt32?
      case byte
      when 'A'.ord..'Z'.ord then (byte - 'A'.ord).to_u32
      when 'a'.ord..'z'.ord then (byte - 'a'.ord + 26).to_u32
      when '0'.ord..'9'.ord then (byte - '0'.ord + 52).to_u32
      when '+'.ord, '-'.ord then 62_u32
      when '/'.ord, '_'.ord then 63_u32
      else                       nil
      end
    end

    # Parses a JSON object key as a map key of *type*.
    # :nodoc:
    def self.read_map_key(pull : ::JSON::PullParser, key : String, type : T.class) : T forall T
      {% if T == ::String %}
        key
      {% elsif T == ::Bool %}
        case key
        when "true"  then true
        when "false" then false
        else              error(pull, "Invalid boolean map key #{key.inspect}")
        end
      {% else %}
        value = parse_integer(key) || error(pull, "Invalid integer map key #{key.inspect}")
        unless T::MIN <= value <= T::MAX
          error(pull, "Map key #{key} is out of range for #{T}")
        end
        T.new(value)
      {% end %}
    end
  end
end
