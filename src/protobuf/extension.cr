module Protobuf
  # An extension field declared with `extend` in a `.proto` file (or by
  # hand), independent of its value type. Generated code declares each
  # extension as a constant holding an `Extension(M, T)` and registers it
  # with `Protobuf::Registry`.
  class ExtensionField
    # The fully qualified name of the extension (`pkg.Scope.name`).
    getter full_name : String

    # The extension's field number.
    getter number : Int32

    def initialize(@full_name : String, @number : Int32)
    end

    # The fully qualified name of the extended message.
    def extendee : String
      raise NotImplementedError.new("extendee")
    end

    # The protobuf kind of the values (`:int32`, `:sint64`, `:message`,
    # `:group`, `:enum`, ...).
    def kind : Symbol
      raise NotImplementedError.new("kind")
    end

    def repeated? : Bool
      raise NotImplementedError.new("repeated?")
    end

    # :nodoc:
    def decode_into(message : Message, reader : Reader, wire_type : WireType, start : Int32) : Bool
      raise NotImplementedError.new("decode_into")
    end

    # :nodoc:
    def read_json_into(message : Message, pull : ::JSON::PullParser, context : JSON::Context) : Nil
      raise NotImplementedError.new("read_json_into")
    end

    def inspect(io : IO) : Nil
      io << "#<" << self.class.name << ' ' << @full_name << " = " << @number << '>'
    end
  end

  # The value of an extension stored in a message.
  class ExtensionValue
    def field : ExtensionField
      raise NotImplementedError.new("field")
    end

    # :nodoc:
    def write(writer : Writer, message_set : Bool) : Nil
      raise NotImplementedError.new("write")
    end

    # :nodoc:
    def write_json(json : ::JSON::Builder, options : JSON::PrintOptions) : Nil
      raise NotImplementedError.new("write_json")
    end

    # :nodoc:
    def same_value?(other : ExtensionValue) : Bool
      raise NotImplementedError.new("same_value?")
    end

    # :nodoc:
    def clone_value : ExtensionValue
      raise NotImplementedError.new("clone_value")
    end

    # :nodoc:
    def missing_required_fields(prefix : String, into : Array(String)) : Nil
      raise NotImplementedError.new("missing_required_fields")
    end

    # :nodoc:
    def empty? : Bool
      raise NotImplementedError.new("empty?")
    end
  end

  # An extension of message type *M* with values of type *T* (a scalar,
  # enum or message type, or an `Array` of those for repeated extensions).
  #
  # ```
  # EXT = Protobuf::Extension(Foo, Int32).new("pkg.ext", 100, type: :sint32)
  # foo.set_extension(EXT, 1)
  # foo.get_extension(EXT) # => 1
  # ```
  class Extension(M, T) < ExtensionField
    getter kind : Symbol
    getter? packed : Bool
    getter? utf8 : Bool

    def initialize(full_name : String, number : Int32, *, type : Symbol? = nil, @packed : Bool = false, @utf8 : Bool = true)
      super(full_name, number)
      @kind = type || default_kind
    end

    def extendee : String
      M.full_name
    end

    def repeated? : Bool
      {{ T < ::Array }}
    end

    private def default_kind : Symbol
      {% begin %}
      {% e = T < ::Array ? T.type_vars[0] : T %}
      {% if e < ::Protobuf::Message %}
        :message
      {% elsif e < ::Enum %}
        :enum
      {% elsif e == ::Int32 %}
        :int32
      {% elsif e == ::Int64 %}
        :int64
      {% elsif e == ::UInt32 %}
        :uint32
      {% elsif e == ::UInt64 %}
        :uint64
      {% elsif e == ::Float32 %}
        :float
      {% elsif e == ::Float64 %}
        :double
      {% elsif e == ::Bool %}
        :bool
      {% elsif e == ::String %}
        :string
      {% elsif e == ::Bytes %}
        :bytes
      {% else %}
        {% raise "Unsupported extension value type #{T}" %}
      {% end %}
      {% end %}
    end

    # :nodoc:
    def wire_type : WireType
      case @kind
      when :fixed64, :sfixed64, :double then WireType::Fixed64
      when :fixed32, :sfixed32, :float  then WireType::Fixed32
      when :string, :bytes, :message    then WireType::LengthDelimited
      when :group                       then WireType::StartGroup
      else                                   WireType::Varint
      end
    end

    # :nodoc:
    def entry(value : T) : ExtensionEntry(M, T)
      ExtensionEntry(M, T).new(self, value)
    end

    # --- Encoding ---

    # :nodoc:
    def encode(writer : Writer, value : T, message_set : Bool) : Nil
      {% if T < ::Array %}
        if @packed
          return if value.empty?
          writer.write_length_delimited(@number) do |packed|
            value.each { |element| encode_raw(packed, element) }
          end
        else
          value.each { |element| encode_element(writer, element) }
        end
      {% elsif T < ::Protobuf::Message %}
        if message_set && @kind == :message
          writer.write_tag(1, WireType::StartGroup)
          writer.write_tag(2, WireType::Varint)
          writer.write_varint(@number.to_u64)
          writer.write_tag(3, WireType::LengthDelimited)
          writer.write_message(value)
          writer.write_tag(1, WireType::EndGroup)
        else
          encode_element(writer, value)
        end
      {% else %}
        encode_element(writer, value)
      {% end %}
    end

    private def encode_element(writer : Writer, value) : Nil
      if @kind == :group
        {% if (T < ::Array ? T.type_vars[0] : T) < ::Protobuf::Message %}
          writer.write_group_field(@number, value)
        {% end %}
      else
        writer.write_tag(@number, wire_type)
        encode_raw(writer, value)
      end
    end

    private def encode_raw(writer : Writer, value) : Nil
      {% begin %}
      {% e = T < ::Array ? T.type_vars[0] : T %}
      {% if e < ::Protobuf::Message %}
        writer.write_message(value)
      {% elsif e < ::Enum %}
        writer.write_enum(value)
      {% elsif e == ::Int32 %}
        case @kind
        when :sint32   then writer.write_sint32(value)
        when :sfixed32 then writer.write_sfixed32(value)
        else                writer.write_int32(value)
        end
      {% elsif e == ::Int64 %}
        case @kind
        when :sint64   then writer.write_sint64(value)
        when :sfixed64 then writer.write_sfixed64(value)
        else                writer.write_int64(value)
        end
      {% elsif e == ::UInt32 %}
        @kind == :fixed32 ? writer.write_fixed32(value) : writer.write_uint32(value)
      {% elsif e == ::UInt64 %}
        @kind == :fixed64 ? writer.write_fixed64(value) : writer.write_uint64(value)
      {% elsif e == ::Float32 %}
        writer.write_float(value)
      {% elsif e == ::Float64 %}
        writer.write_double(value)
      {% elsif e == ::Bool %}
        writer.write_bool(value)
      {% elsif e == ::String %}
        writer.write_string(value)
      {% elsif e == ::Bytes %}
        writer.write_bytes(value)
      {% end %}
      {% end %}
    end

    # --- Decoding ---

    # Decodes one occurrence of the extension from *reader* into *message*.
    # Returns `false` (consuming nothing) if the wire type does not match.
    # :nodoc:
    def decode_into(message : Message, reader : Reader, wire_type : WireType, start : Int32) : Bool
      target = message.as(M)
      existing = target.__protobuf_extension_entry(@number).as?(ExtensionEntry(M, T)).try(&.value)
      {% if T < ::Array %}
        list = existing || T.new
        if wire_type.length_delimited? && packable?
          reader.read_packed do |packed|
            read_element(packed, target, start, true).try { |value| list << value }
          end
        elsif wire_type == self.wire_type
          read_element(reader, target, start, false).try { |value| list << value }
        else
          return false
        end
        target.__protobuf_set_extension_entry(entry(list))
      {% elsif T < ::Protobuf::Message %}
        if @kind == :group
          return false unless wire_type.start_group?
          value = existing || T.new
          reader.enter_group
          value.__protobuf_merge(reader, @number)
          reader.leave_group
        else
          return false unless wire_type.length_delimited?
          value = existing || T.new
          value.merge_from_protobuf(reader.read_sub_reader)
        end
        target.__protobuf_set_extension_entry(entry(value))
      {% else %}
        return false unless wire_type == self.wire_type
        if value = read_element(reader, target, start, false)
          target.__protobuf_set_extension_entry(entry(value))
        end
      {% end %}
      true
    end

    private def packable? : Bool
      !(@kind.in?(:string, :bytes, :message, :group))
    end

    # Reads one element; returns `nil` for unknown values of closed enums,
    # which are moved to the unknown fields.
    private def read_element(reader : Reader, message : M, start : Int32, packed : Bool)
      {% begin %}
      {% e = T < ::Array ? T.type_vars[0] : T %}
      {% if e < ::Protobuf::Message %}
        if @kind == :group
          value = {{e}}.new
          reader.enter_group
          value.__protobuf_merge(reader, @number)
          reader.leave_group
          value
        else
          {{e}}.new.tap(&.merge_from_protobuf(reader.read_sub_reader))
        end
      {% elsif e < ::Enum %}
        raw = reader.read_enum
        value = {{e}}.new(raw)
        {% if e.annotation(::Protobuf::ClosedEnum) %}
          unless {{e}}.valid?(value)
            if packed
              message.__protobuf_add_unknown_varint(@number, raw.to_i64.to_u64!)
            else
              message.__protobuf_add_unknown(reader.bytes[start, reader.pos - start])
            end
            return nil
          end
        {% end %}
        value
      {% elsif e == ::Int32 %}
        case @kind
        when :sint32   then reader.read_sint32
        when :sfixed32 then reader.read_sfixed32
        else                reader.read_int32
        end
      {% elsif e == ::Int64 %}
        case @kind
        when :sint64   then reader.read_sint64
        when :sfixed64 then reader.read_sfixed64
        else                reader.read_int64
        end
      {% elsif e == ::UInt32 %}
        @kind == :fixed32 ? reader.read_fixed32 : reader.read_uint32
      {% elsif e == ::UInt64 %}
        @kind == :fixed64 ? reader.read_fixed64 : reader.read_uint64
      {% elsif e == ::Float32 %}
        reader.read_float
      {% elsif e == ::Float64 %}
        reader.read_double
      {% elsif e == ::Bool %}
        reader.read_bool
      {% elsif e == ::String %}
        reader.read_string(@utf8)
      {% elsif e == ::Bytes %}
        reader.read_bytes
      {% end %}
      {% end %}
    end

    # --- JSON ---

    # :nodoc:
    def read_json_into(message : Message, pull : ::JSON::PullParser, context : JSON::Context) : Nil
      target = message.as(M)
      {% if T < ::Array %}
        if pull.kind.null?
          pull.read_null
          return
        end
        list = T.new
        pull.read_array do
          JSON.read_value(pull, {{T.type_vars[0]}}, context).try { |value| list << value }
        end
        target.__protobuf_set_extension_entry(entry(list))
      {% else %}
        {% unless T == ::Google::Protobuf::Value %}
          if pull.kind.null?
            pull.read_null
            return
          end
        {% end %}
        if value = JSON.read_value(pull, T, context)
          target.__protobuf_set_extension_entry(entry(value))
        end
      {% end %}
    end
  end

  # :nodoc:
  class ExtensionEntry(M, T) < ExtensionValue
    getter field : Extension(M, T)
    property value : T

    def initialize(@field : Extension(M, T), @value : T)
    end

    def write(writer : Writer, message_set : Bool) : Nil
      @field.encode(writer, @value, message_set)
    end

    def write_json(json : ::JSON::Builder, options : JSON::PrintOptions) : Nil
      JSON.write_value(json, @value, options)
    end

    def same_value?(other : ExtensionValue) : Bool
      other.is_a?(ExtensionEntry(M, T)) && other.value == @value
    end

    def clone_value : ExtensionValue
      ExtensionEntry(M, T).new(@field, @value.clone)
    end

    def empty? : Bool
      {% if T < ::Array %}
        @value.empty?
      {% else %}
        false
      {% end %}
    end

    def missing_required_fields(prefix : String, into : Array(String)) : Nil
      {% if T < ::Array %}
        {% if T.type_vars[0] < ::Protobuf::Message %}
          @value.each_with_index do |element, i|
            element.__protobuf_missing_required("#{prefix}(#{@field.full_name})[#{i}].", into)
          end
        {% end %}
      {% elsif T < ::Protobuf::Message %}
        @value.__protobuf_missing_required("#{prefix}(#{@field.full_name}).", into)
      {% end %}
    end
  end
end
