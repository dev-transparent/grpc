module Protobuf
  # Gives the fully qualified proto name of a generated message or enum,
  # e.g. `@[Protobuf::TypeName("google.protobuf.Duration")]`.
  annotation TypeName
  end

  # Marks an enum as closed (proto2 enums, editions `enum_type = CLOSED`):
  # unknown values read from the wire are kept as unknown fields instead of
  # being stored in the field.
  annotation ClosedEnum
  end

  # Gives the proto names of enum members whose Crystal name differs, e.g.
  # `@[Protobuf::EnumValueNames({"Foo" => "foo"})]`.
  annotation EnumValueNames
  end

  # Marks a message using the MessageSet wire format
  # (`option message_set_wire_format = true`).
  annotation MessageSet
  end

  # Include this module in a class to turn it into a protobuf message. Fields
  # are declared with the `field`, `repeated`, `map` and `oneof` macros; the
  # accessors, constructor, encoder and decoder are generated once the program
  # has been parsed, so field types may refer to classes and enums declared
  # later.
  #
  # ```
  # class Person
  #   include Protobuf::Message
  #
  #   field name : String, 1
  #   field id : Int32, 2
  #   field email : String, 3, optional: true # String?, with presence
  #   repeated phones : PhoneNumber, 4
  #   map attributes : Hash(String, String), 5
  #
  #   oneof contact do
  #     field mobile : String, 6
  #     field landline : String, 7
  #   end
  # end
  #
  # person = Person.new(name: "Ada", id: 1)
  # bytes = person.to_protobuf
  # Person.from_protobuf(bytes) == person # => true
  # person.to_json                        # => %({"name":"Ada","id":1})
  # ```
  #
  # Field types map to protobuf scalar types as follows: `String` (string),
  # `Bytes` (bytes), `Bool` (bool), `Int32` (int32), `Int64` (int64), `UInt32`
  # (uint32), `UInt64` (uint64), `Float32` (float), `Float64` (double), any
  # `Enum` (enum) and any `Protobuf::Message` (message). Use the `type:`
  # option for the other encodings, e.g. `type: :sint32`, `type: :fixed64`,
  # and `type: :group` for messages using group (delimited) encoding.
  #
  # Singular message fields, `optional: true` / `required: true` fields and
  # oneof members are nilable; `nil` means "not set". For such scalar fields
  # `#<name>_or_default` returns the field's default value (given with
  # `default:`, as for proto2 `[default = ...]`) when the field is not set.
  #
  # Other field options: `json_name:` (the JSON name, by default the
  # lowerCamelCase proto name), `proto_name:` (the proto field name when it
  # differs from the Crystal name), `utf8: false` (do not validate UTF-8 in
  # string fields) and, for repeated scalars, `packed: false`.
  #
  # The proto name of the message (used by `Any`, the registry and JSON) is
  # given with `@[Protobuf::TypeName("pkg.Message")]`; it defaults to the
  # Crystal class name.
  module Message
    macro included
      PROTOBUF_FIELD_DEFS = [] of Nil

      extend ::Protobuf::Message::ClassMethods

      macro finished
        __protobuf_generate
      end
    end

    # Class methods of every message class. `Protobuf::MessageClass` is an
    # alias of this module and can be used to hold message classes, as
    # returned by `Protobuf::Registry.message_class`.
    module ClassMethods
      # The fully qualified proto name of the message.
      abstract def full_name : String

      # Returns a new message with all fields unset.
      abstract def new_message : ::Protobuf::Message

      # Parses a message from protobuf binary data.
      abstract def from_protobuf(bytes : ::Bytes) : ::Protobuf::Message

      # Parses a message from JSON.
      abstract def from_json(input : ::String | ::IO, options : ::Protobuf::JSON::ParseOptions) : ::Protobuf::Message

      # The message's descriptor, from `Protobuf::Registry`.
      abstract def descriptor : ::Google::Protobuf::DescriptorProto

      # :nodoc:
      abstract def __protobuf_json_read(pull : ::JSON::PullParser, context : ::Protobuf::JSON::Context) : ::Protobuf::Message

      # Like `.from_json`, with keyword options.
      def from_json(input : ::String | ::IO, *, ignore_unknown_fields : ::Bool = false) : ::Protobuf::Message
        from_json(input, ::Protobuf::JSON::ParseOptions.new(ignore_unknown_fields: ignore_unknown_fields))
      end
    end

    # Declares a singular field.
    macro field(decl, number, type = nil, optional = false, oneof = nil, default = nil, utf8 = true, required = false, json_name = nil, proto_name = nil)
      {% PROTOBUF_FIELD_DEFS << {name: decl.var, type: decl.type, number: number, kind: type, label: :singular, optional: optional || required, oneof: oneof, default: default, utf8: utf8, packed: false, required: required, json_name: json_name, proto_name: proto_name} %}
    end

    # Declares a repeated field. Scalar numeric fields are packed unless
    # `packed: false` is given.
    macro repeated(decl, number, type = nil, packed = true, utf8 = true, json_name = nil, proto_name = nil)
      {% PROTOBUF_FIELD_DEFS << {name: decl.var, type: decl.type, number: number, kind: type, label: :repeated, optional: false, oneof: nil, default: nil, utf8: utf8, packed: packed, required: false, json_name: json_name, proto_name: proto_name} %}
    end

    # Declares a map field. The declared type must be a `Hash(K, V)`; use
    # `key_type:` / `value_type:` for non-default scalar encodings.
    macro map(decl, number, key_type = nil, value_type = nil, utf8 = true, json_name = nil, proto_name = nil)
      {% PROTOBUF_FIELD_DEFS << {name: decl.var, type: decl.type, number: number, kind: nil, key_kind: key_type, value_kind: value_type, label: :map, optional: false, oneof: nil, default: nil, utf8: utf8, packed: false, required: false, json_name: json_name, proto_name: proto_name} %}
    end

    # Declares a group of mutually exclusive fields. Setting one member clears
    # the others. Generates `#<name>` returning the value of the member that
    # is set, `#<name>_case` returning its name as a `Symbol`, and
    # `#clear_<name>`.
    macro oneof(name, &block)
      {% calls = block.body.is_a?(Expressions) ? block.body.expressions : [block.body] %}
      {% for call in calls %}
        {% if call.is_a?(Call) && call.name == "field" %}
          field {{call.args.splat}}, {% for arg in call.named_args || [] of Nil %}{{arg.name.id}}: {{arg.value}}, {% end %}oneof: {{name.id.symbolize}}
        {% elsif !call.is_a?(Nop) %}
          {% raise "oneof blocks may only contain `field` declarations" %}
        {% end %}
      {% end %}
    end

    # :nodoc:
    macro __protobuf_read_value(kind, type, reader, utf8, number = 0)
      {% if kind == :enum %}
        {{type}}.new({{reader}}.read_enum)
      {% elsif kind == :message %}
        {{type}}.new.tap(&.merge_from_protobuf({{reader}}.read_sub_reader))
      {% elsif kind == :group %}
        {{type}}.new.tap do |%group|
          {{reader}}.enter_group
          %group.__protobuf_merge({{reader}}, {{number}})
          {{reader}}.leave_group
        end
      {% elsif kind == :string %}
        {{reader}}.read_string({{utf8}})
      {% else %}
        {{reader}}.read_{{kind.id}}
      {% end %}
    end

    # :nodoc:
    macro __protobuf_default(kind, type)
      {% if kind == :string %}
        ""
      {% elsif kind == :bytes %}
        ::Bytes.empty
      {% elsif kind == :bool %}
        false
      {% elsif kind == :message || kind == :group %}
        {{type}}.new
      {% else %}
        {{type}}.new(0)
      {% end %}
    end

    # The default of a field with explicit presence that has no `default:`:
    # the zero value, or the first value of an enum (proto2 semantics).
    # :nodoc:
    macro __protobuf_presence_default(kind, type)
      {% if kind == :enum %}
        ({{type}}.values.first? || {{type}}.new(0))
      {% else %}
        ::Protobuf::Message.__protobuf_default({{kind}}, {{type}})
      {% end %}
    end

    # :nodoc:
    macro __protobuf_generate
      {%
        scalar_kinds = {
          "String" => :string, "Slice(UInt8)" => :bytes, "Bool" => :bool,
          "Int32" => :int32, "Int64" => :int64, "UInt32" => :uint32, "UInt64" => :uint64,
          "Float32" => :float, "Float64" => :double,
        }
        wire_types = {
          :int32 => 0, :int64 => 0, :uint32 => 0, :uint64 => 0, :sint32 => 0, :sint64 => 0,
          :bool => 0, :enum => 0, :fixed64 => 1, :sfixed64 => 1, :double => 1,
          :string => 2, :bytes => 2, :message => 2, :group => 3, :fixed32 => 5, :sfixed32 => 5, :float => 5,
        }
        packable = [:int32, :int64, :uint32, :uint64, :sint32, :sint64, :bool, :enum,
                    :fixed32, :sfixed32, :float, :fixed64, :sfixed64, :double]
        null_types = ["google.protobuf.Value", "google.protobuf.NullValue"]

        type_name_ann = @type.annotation(::Protobuf::TypeName)
        full_name = type_name_ann ? type_name_ann[0] : @type.stringify.gsub(/::/, ".")
        message_set = !!@type.annotation(::Protobuf::MessageSet)

        fields = [] of Nil
        numbers = [] of Nil
        PROTOBUF_FIELD_DEFS.sort_by { |f| f[:number] }.each do |f|
          raise "Duplicate protobuf field number #{f[:number]} in #{@type}" if numbers.includes?(f[:number])
          numbers << f[:number]

          proto_name = f[:proto_name] || f[:name].stringify
          parts = proto_name.split("_")
          default_json = parts[0]
          parts[1..].each { |part| default_json = default_json + (part.empty? ? "" : part[0..0].upcase + part[1..]) }
          json_name = f[:json_name] || default_json

          if f[:label] == :map
            key_type = f[:type].type_vars[0].resolve
            value_type = f[:type].type_vars[1].resolve
            key_kind = f[:key_kind] || scalar_kinds[key_type.stringify]
            value_kind = f[:value_kind] || scalar_kinds[value_type.stringify] ||
                         (value_type < ::Enum ? :enum : (value_type < ::Protobuf::Message ? :message : nil))
            raise "Unsupported map key type #{key_type} for #{@type}##{f[:name]}" unless key_kind
            raise "Unsupported map value type #{value_type} for #{@type}##{f[:name]}" unless value_kind
            value_ann = value_kind == :enum ? value_type.annotation(::Protobuf::TypeName) : nil
            fields << {name: f[:name], number: f[:number], label: :map, kind: :message, key_type: key_type, key_kind: key_kind,
                       value_type: value_type, value_kind: value_kind, utf8: f[:utf8], oneof: nil,
                       value_closed: value_kind == :enum && !!value_type.annotation(::Protobuf::ClosedEnum),
                       value_null: value_ann && null_types.includes?(value_ann[0]) || (value_kind == :message && value_type.annotation(::Protobuf::TypeName) && value_type.annotation(::Protobuf::TypeName)[0] == "google.protobuf.Value"),
                       proto_name: proto_name, json_name: json_name, required: false, nilable: false}
          else
            type = f[:type].resolve
            kind = f[:kind] || scalar_kinds[type.stringify] ||
                   (type < ::Enum ? :enum : (type < ::Protobuf::Message ? :message : nil))
            raise "Unsupported protobuf field type #{type} for #{@type}##{f[:name]}" unless kind
            message = kind == :message || kind == :group
            nilable = f[:label] == :singular && (message || f[:optional] || f[:oneof])
            type_ann = (kind == :enum || message) ? type.annotation(::Protobuf::TypeName) : nil
            fields << {name: f[:name], number: f[:number], label: f[:label], type: type, kind: kind, nilable: nilable,
                       oneof: f[:oneof], default: f[:default], utf8: f[:utf8], message: message,
                       packed: f[:label] == :repeated && f[:packed] && packable.includes?(kind),
                       closed: kind == :enum && !!type.annotation(::Protobuf::ClosedEnum),
                       accepts_null: type_ann && null_types.includes?(type_ann[0]),
                       required: f[:required], proto_name: proto_name, json_name: json_name}
          end
        end
        oneofs = [] of Nil
        fields.each { |f| oneofs << f[:oneof] if f[:oneof] && !oneofs.includes?(f[:oneof]) }
        method_names = fields.map(&.[:name].stringify)
      %}

      # --- Accessors ---
      {% for f in fields %}
        {% if f[:label] == :repeated %}
          property {{f[:name]}} : ::Array(::{{f[:type]}})
        {% elsif f[:label] == :map %}
          property {{f[:name]}} : ::Hash(::{{f[:key_type]}}, ::{{f[:value_type]}})
        {% elsif f[:oneof] %}
          getter {{f[:name]}} : ::{{f[:type]}}?

          # Sets this member of the `{{f[:oneof].id}}` oneof, clearing the others.
          def {{f[:name]}}=(value : ::{{f[:type]}}?) : ::{{f[:type]}}?
            {% for g in fields %}
              {% if g[:oneof] == f[:oneof] && g[:name] != f[:name] %}
                @{{g[:name]}} = nil unless value.nil?
              {% end %}
            {% end %}
            @{{f[:name]}} = value
          end
        {% elsif f[:nilable] %}
          property {{f[:name]}} : ::{{f[:type]}}?
        {% else %}
          property {{f[:name]}} : ::{{f[:type]}}
        {% end %}

        {% if f[:nilable] && !f[:message] && !method_names.includes?("#{f[:name]}_or_default") %}
          # Returns the value of `{{f[:name]}}`, or its default value if it is not set.
          def {{f[:name]}}_or_default : ::{{f[:type]}}
            value = @{{f[:name]}}
            return value unless value.nil?
            {% if f[:default] != nil %}
              {{f[:default]}}
            {% else %}
              ::Protobuf::Message.__protobuf_presence_default({{f[:kind]}}, ::{{f[:type]}})
            {% end %}
          end
        {% end %}
      {% end %}

      @_protobuf_unknown : ::IO::Memory? = nil
      @_protobuf_extensions : ::Hash(::Int32, ::Protobuf::ExtensionValue)? = nil

      {% for o in oneofs %}
        {% members = fields.select { |f| f[:oneof] == o } %}
        # Returns the value of the member of the `{{o.id}}` oneof that is set.
        def {{o.id}} : ({{members.map { |m| "::" + m[:type].stringify }.join(" | ").id}})?
          {% for m in members %}
            unless (value = @{{m[:name]}}).nil?
              return value
            end
          {% end %}
          nil
        end

        # Returns the name of the member of the `{{o.id}}` oneof that is set.
        def {{o.id}}_case : ::Symbol?
          {% for m in members %}
            return {{m[:name].symbolize}} unless @{{m[:name]}}.nil?
          {% end %}
          nil
        end

        # Clears the `{{o.id}}` oneof.
        def clear_{{o.id}} : ::Nil
          {% for m in members %}
            @{{m[:name]}} = nil
          {% end %}
        end
      {% end %}

      # --- Constructor ---
      {% if fields.empty? %}
        def initialize
        end
      {% else %}
        def initialize(*,
          {% for f in fields %}
            {% if f[:label] == :repeated %}
              @{{f[:name]}} : ::Array(::{{f[:type]}}) = [] of ::{{f[:type]}},
            {% elsif f[:label] == :map %}
              @{{f[:name]}} : ::Hash(::{{f[:key_type]}}, ::{{f[:value_type]}}) = {} of ::{{f[:key_type]}} => ::{{f[:value_type]}},
            {% elsif f[:nilable] %}
              @{{f[:name]}} : ::{{f[:type]}}? = nil,
            {% elsif f[:default] != nil %}
              @{{f[:name]}} : ::{{f[:type]}} = {{f[:default]}},
            {% else %}
              @{{f[:name]}} : ::{{f[:type]}} = ::Protobuf::Message.__protobuf_default({{f[:kind]}}, ::{{f[:type]}}),
            {% end %}
          {% end %}
        )
          {% for o in oneofs %}
            {% members = fields.select { |f| f[:oneof] == o } %}
            if [{{members.map { |m| "@#{m[:name]}".id }.splat}}].count { |value| !value.nil? } > 1
              raise ::ArgumentError.new("At most one member of oneof {{o.id}} may be set")
            end
          {% end %}
        end
      {% end %}

      # --- Metadata ---

      # The fully qualified proto name of the message.
      def self.full_name : ::String
        {{full_name}}
      end

      # Returns a new message with all fields unset.
      def self.new_message : self
        new
      end

      # The message's descriptor, from `Protobuf::Registry`. Raises
      # `Protobuf::Error` if the message's file is not registered.
      def self.descriptor : ::Google::Protobuf::DescriptorProto
        ::Protobuf::Registry.message_descriptor(full_name) ||
          raise ::Protobuf::Error.new("Message {{full_name.id}} is not registered")
      end

      # The descriptor of the file defining the message, from
      # `Protobuf::Registry`.
      def self.file_descriptor : ::Google::Protobuf::FileDescriptorProto
        ::Protobuf::Registry.file_containing_symbol(full_name) ||
          raise ::Protobuf::Error.new("Message {{full_name.id}} is not registered")
      end

      # --- Encoding ---

      # Serializes the message in protobuf binary format to *io*.
      def to_protobuf(io : ::IO) : ::Nil
        writer = ::Protobuf::Writer.new(io)
        {% for f in fields %}
          {% if f[:label] == :repeated %}
            {% if f[:packed] %}
              writer.write_packed_{{f[:kind].id}}({{f[:number]}}, @{{f[:name]}})
            {% elsif f[:kind] == :group %}
              @{{f[:name]}}.each { |value| writer.write_group_field({{f[:number]}}, value) }
            {% else %}
              @{{f[:name]}}.each { |value| writer.write_{{f[:kind].id}}_field({{f[:number]}}, value) }
            {% end %}
          {% elsif f[:label] == :map %}
            @{{f[:name]}}.each do |key, value|
              writer.write_length_delimited({{f[:number]}}) do |entry|
                entry.write_{{f[:key_kind].id}}_field(1, key)
                entry.write_{{f[:value_kind].id}}_field(2, value)
              end
            end
          {% elsif f[:nilable] %}
            unless (value = @{{f[:name]}}).nil?
              {% if f[:kind] == :group %}
                writer.write_group_field({{f[:number]}}, value)
              {% else %}
                writer.write_{{f[:kind].id}}_field({{f[:number]}}, value)
              {% end %}
            end
          {% else %}
            unless ::Protobuf.default?(@{{f[:name]}})
              writer.write_{{f[:kind].id}}_field({{f[:number]}}, @{{f[:name]}})
            end
          {% end %}
        {% end %}
        if extensions = @_protobuf_extensions
          extensions.keys.sort!.each { |number| extensions[number].write(writer, {{message_set}}) }
        end
        if unknown = @_protobuf_unknown
          io.write(unknown.to_slice)
        end
      end

      # Returns the message serialized in protobuf binary format.
      def to_protobuf : ::Bytes
        io = ::IO::Memory.new
        to_protobuf(io)
        io.to_slice
      end

      # --- Decoding ---

      # Parses a message from protobuf binary data.
      def self.from_protobuf(bytes : ::Bytes) : self
        message = new
        message.merge_from_protobuf(::Protobuf::Reader.new(bytes))
        message
      end

      # Parses a message from protobuf binary data. With
      # `check_required: true`, raises `Protobuf::RequiredFieldsError` if
      # required fields (proto2) are missing.
      def self.from_protobuf(bytes : ::Bytes, *, check_required : ::Bool) : self
        message = from_protobuf(bytes)
        message.check_required_fields! if check_required
        message
      end

      # Parses a message from the remaining contents of *io*.
      def self.from_protobuf(io : ::IO) : self
        from_protobuf(io.getb_to_end)
      end

      # Merges fields parsed from *reader* into this message, following the
      # protobuf merge semantics (singular fields are replaced, repeated
      # fields appended, and embedded messages merged recursively).
      def merge_from_protobuf(reader : ::Protobuf::Reader) : ::Nil
        __protobuf_merge(reader, 0)
      end

      # Merges fields until the end of *reader* or, if *end_group* is not
      # zero, until the end group tag of field *end_group*.
      # :nodoc:
      def __protobuf_merge(reader : ::Protobuf::Reader, end_group : ::Int32) : ::Nil
        until reader.eof?
          start = reader.pos
          number, wire_type = reader.read_tag
          if wire_type.end_group?
            raise ::Protobuf::DecodeError.new("Mismatched end group") unless number == end_group && end_group != 0
            return
          end
          next if __protobuf_decode_field(reader, number, wire_type, start)
          {% if message_set %}
            if number == 1 && wire_type.start_group?
              __protobuf_decode_message_set_item(reader, start)
              next
            end
          {% end %}
          if ::Protobuf::Registry.extensions?({{full_name}}) && (extension = ::Protobuf::Registry.extension({{full_name}}, number))
            next if extension.decode_into(self.as(::Protobuf::Message), reader, wire_type, start)
          end
          reader.skip_field(wire_type, number)
          __protobuf_add_unknown(reader.bytes[start, reader.pos - start])
        end
        raise ::Protobuf::DecodeError.new("Unterminated group") unless end_group == 0
      end

      {% if message_set %}
        # Decodes a MessageSet item (group 1 with type_id = 2 and message = 3).
        private def __protobuf_decode_message_set_item(reader : ::Protobuf::Reader, start : ::Int32) : ::Nil
          reader.enter_group
          type_id = nil
          payload = nil
          loop do
            raise ::Protobuf::DecodeError.new("Unterminated MessageSet item") if reader.eof?
            item_number, item_wire_type = reader.read_tag
            if item_wire_type.end_group?
              raise ::Protobuf::DecodeError.new("Mismatched end group") unless item_number == 1
              break
            end
            if item_number == 2 && item_wire_type.varint?
              type_id = reader.read_varint
            elsif item_number == 3 && item_wire_type.length_delimited?
              payload = reader.read_length_delimited
            else
              reader.skip_field(item_wire_type, item_number)
            end
          end
          reader.leave_group
          extension = nil
          if (id = type_id) && payload && id <= ::Protobuf::MAX_FIELD_NUMBER
            extension = ::Protobuf::Registry.extension({{full_name}}, id.to_i32)
          end
          if extension && payload && extension.kind == :message
            # Re-frame the payload as a length-delimited field for the extension.
            framed = ::IO::Memory.new
            framed_writer = ::Protobuf::Writer.new(framed)
            framed_writer.write_length_prefixed(payload)
            sub = ::Protobuf::Reader.new(framed.to_slice, reader.depth)
            extension.decode_into(self.as(::Protobuf::Message), sub, ::Protobuf::WireType::LengthDelimited, 0)
          else
            __protobuf_add_unknown(reader.bytes[start, reader.pos - start])
          end
        end
      {% end %}

      # Merges the fields set in *other* into this message.
      def merge_from(other : self) : ::Nil
        merge_from_protobuf(::Protobuf::Reader.new(other.to_protobuf))
      end

      private def __protobuf_decode_field(reader : ::Protobuf::Reader, number : ::Int32, wire_type : ::Protobuf::WireType, start : ::Int32) : ::Bool
        {% if !fields.empty? %}
        case number
        {% for f in fields %}
        when {{f[:number]}}
          {% if f[:label] == :map %}
            return false unless wire_type.length_delimited?
            entry = reader.read_sub_reader
            key = nil
            value = nil
            until entry.eof?
              entry_number, entry_wire_type = entry.read_tag
              if entry_number == 1 && entry_wire_type.value == {{wire_types[f[:key_kind]]}}
                key = ::Protobuf::Message.__protobuf_read_value({{f[:key_kind]}}, ::{{f[:key_type]}}, entry, {{f[:utf8]}})
              elsif entry_number == 2 && entry_wire_type.value == {{wire_types[f[:value_kind]]}}
                {% if f[:value_kind] == :message %}
                  (value ||= ::{{f[:value_type]}}.new).merge_from_protobuf(entry.read_sub_reader)
                {% else %}
                  value = ::Protobuf::Message.__protobuf_read_value({{f[:value_kind]}}, ::{{f[:value_type]}}, entry, {{f[:utf8]}})
                {% end %}
              else
                entry.skip_field(entry_wire_type, entry_number)
              end
            end
            key = ::Protobuf::Message.__protobuf_default({{f[:key_kind]}}, ::{{f[:key_type]}}) if key.nil?
            {% if f[:value_closed] %}
              value = ::Protobuf::Message.__protobuf_presence_default(:enum, ::{{f[:value_type]}}) if value.nil?
              unless ::{{f[:value_type]}}.valid?(value)
                __protobuf_add_unknown(reader.bytes[start, reader.pos - start])
                return true
              end
            {% else %}
              value = ::Protobuf::Message.__protobuf_default({{f[:value_kind]}}, ::{{f[:value_type]}}) if value.nil?
            {% end %}
            @{{f[:name]}}[key] = value
          {% elsif f[:label] == :repeated %}
            {% if packable.includes?(f[:kind]) %}
              if wire_type.length_delimited?
                reader.read_packed do |packed|
                  {% if f[:closed] %}
                    raw = packed.read_enum
                    element = ::{{f[:type]}}.new(raw)
                    if ::{{f[:type]}}.valid?(element)
                      @{{f[:name]}} << element
                    else
                      # Like C++: the value as an int32, sign extended.
                      __protobuf_add_unknown_varint({{f[:number]}}, raw.to_i64.to_u64!)
                    end
                  {% else %}
                    @{{f[:name]}} << ::Protobuf::Message.__protobuf_read_value({{f[:kind]}}, ::{{f[:type]}}, packed, {{f[:utf8]}})
                  {% end %}
                end
                return true
              end
            {% end %}
            return false unless wire_type.value == {{wire_types[f[:kind]]}}
            {% if f[:closed] %}
              element = ::Protobuf::Message.__protobuf_read_value(:enum, ::{{f[:type]}}, reader, true)
              if ::{{f[:type]}}.valid?(element)
                @{{f[:name]}} << element
              else
                __protobuf_add_unknown(reader.bytes[start, reader.pos - start])
              end
            {% else %}
              @{{f[:name]}} << ::Protobuf::Message.__protobuf_read_value({{f[:kind]}}, ::{{f[:type]}}, reader, {{f[:utf8]}}, {{f[:number]}})
            {% end %}
          {% elsif f[:kind] == :message %}
            return false unless wire_type.length_delimited?
            if existing = @{{f[:name]}}
              existing.merge_from_protobuf(reader.read_sub_reader)
            else
              self.{{f[:name]}} = ::Protobuf::Message.__protobuf_read_value(:message, ::{{f[:type]}}, reader, true)
            end
          {% elsif f[:kind] == :group %}
            return false unless wire_type.start_group?
            if existing = @{{f[:name]}}
              reader.enter_group
              existing.__protobuf_merge(reader, {{f[:number]}})
              reader.leave_group
            else
              self.{{f[:name]}} = ::Protobuf::Message.__protobuf_read_value(:group, ::{{f[:type]}}, reader, true, {{f[:number]}})
            end
          {% else %}
            return false unless wire_type.value == {{wire_types[f[:kind]]}}
            {% if f[:closed] %}
              value = ::Protobuf::Message.__protobuf_read_value(:enum, ::{{f[:type]}}, reader, true)
              if ::{{f[:type]}}.valid?(value)
                self.{{f[:name]}} = value
              else
                __protobuf_add_unknown(reader.bytes[start, reader.pos - start])
              end
            {% else %}
              self.{{f[:name]}} = ::Protobuf::Message.__protobuf_read_value({{f[:kind]}}, ::{{f[:type]}}, reader, {{f[:utf8]}})
            {% end %}
          {% end %}
        {% end %}
        else
          return false
        end
        true
        {% else %}
        false
        {% end %}
      end

      # --- Unknown fields and extensions ---

      # Returns the serialized unknown fields encountered while parsing.
      def unknown_fields : ::Bytes
        @_protobuf_unknown.try(&.to_slice) || ::Bytes.empty
      end

      # Discards unknown fields so they are not serialized again.
      def discard_unknown_fields : ::Nil
        @_protobuf_unknown = nil
      end

      # :nodoc:
      def __protobuf_add_unknown(bytes : ::Bytes) : ::Nil
        (@_protobuf_unknown ||= ::IO::Memory.new).write(bytes)
      end

      # :nodoc:
      def __protobuf_add_unknown_varint(number : ::Int32, value : ::UInt64) : ::Nil
        writer = ::Protobuf::Writer.new(@_protobuf_unknown ||= ::IO::Memory.new)
        writer.write_tag(number, ::Protobuf::WireType::Varint)
        writer.write_varint(value)
      end

      # Removes the unknown fields with field number *number* (or, for
      # MessageSet messages, the items with that type id) and returns them.
      # :nodoc:
      def __protobuf_take_unknown(number : ::Int32) : ::Bytes?
        unknown = @_protobuf_unknown || return nil
        data = unknown.to_slice
        reader = ::Protobuf::Reader.new(data)
        taken = ::IO::Memory.new
        rest = ::IO::Memory.new
        until reader.eof?
          start = reader.pos
          field_number, wire_type = reader.read_tag
          match = field_number == number
          {% if message_set %}
            if field_number == 1 && wire_type.start_group?
              item = ::Protobuf::Reader.new(data[reader.pos, data.size - reader.pos])
              until item.eof?
                item_number, item_wire_type = item.read_tag
                break if item_wire_type.end_group?
                if item_number == 2 && item_wire_type.varint?
                  match = item.read_varint == number
                  break
                end
                item.skip_field(item_wire_type, item_number)
              end
            end
          {% end %}
          reader.skip_field(wire_type, field_number)
          (match ? taken : rest).write(data[start, reader.pos - start])
        end
        return nil if taken.empty?
        @_protobuf_unknown = rest.empty? ? nil : rest
        taken.to_slice
      end

      # :nodoc:
      def __protobuf_extension_entry(number : ::Int32) : ::Protobuf::ExtensionValue?
        @_protobuf_extensions.try(&.[number]?)
      end

      # :nodoc:
      def __protobuf_set_extension_entry(entry : ::Protobuf::ExtensionValue) : ::Nil
        (@_protobuf_extensions ||= {} of ::Int32 => ::Protobuf::ExtensionValue)[entry.field.number] = entry
      end

      # :nodoc:
      def __protobuf_delete_extension_entry(number : ::Int32) : ::Protobuf::ExtensionValue?
        extensions = @_protobuf_extensions || return nil
        entry = extensions.delete(number)
        @_protobuf_extensions = nil if extensions.empty?
        entry
      end

      # :nodoc:
      def __protobuf_extension_entries : ::Array(::Protobuf::ExtensionValue)
        extensions = @_protobuf_extensions || return [] of ::Protobuf::ExtensionValue
        extensions.keys.sort!.map { |number| extensions[number] }
      end

      # :nodoc:
      def __protobuf_message_set? : ::Bool
        {{message_set}}
      end

      # --- Required fields ---

      # :nodoc:
      def __protobuf_missing_required(prefix : ::String, into : ::Array(::String)) : ::Nil
        {% for f in fields %}
          {% if f[:required] %}
            into << "#{prefix}{{f[:proto_name].id}}" if @{{f[:name]}}.nil?
          {% end %}
          {% if f[:label] == :map %}
            {% if f[:value_kind] == :message %}
              @{{f[:name]}}.each do |key, value|
                value.__protobuf_missing_required("#{prefix}{{f[:proto_name].id}}[#{key}].", into)
              end
            {% end %}
          {% elsif f[:message] %}
            {% if f[:label] == :repeated %}
              @{{f[:name]}}.each_with_index do |value, index|
                value.__protobuf_missing_required("#{prefix}{{f[:proto_name].id}}[#{index}].", into)
              end
            {% else %}
              @{{f[:name]}}.try &.__protobuf_missing_required("#{prefix}{{f[:proto_name].id}}.", into)
            {% end %}
          {% end %}
        {% end %}
        @_protobuf_extensions.try &.each_value(&.missing_required_fields(prefix, into))
      end

      # --- Copying and comparison ---

      # Returns a deep copy of the message.
      def clone : self
        copy = {{@type}}.new(
          {% for f in fields %}
            {{f[:name]}}: @{{f[:name]}}.clone,
          {% end %}
        )
        copy.__protobuf_copy_extras(@_protobuf_unknown, @_protobuf_extensions)
        copy
      end

      # :nodoc:
      protected def __protobuf_copy_extras(unknown : ::IO::Memory?, extensions : ::Hash(::Int32, ::Protobuf::ExtensionValue)?) : ::Nil
        if unknown
          @_protobuf_unknown = ::IO::Memory.new.tap(&.write(unknown.to_slice))
        end
        if extensions
          @_protobuf_extensions = extensions.transform_values { |entry| entry.clone_value.as(::Protobuf::ExtensionValue) }
        end
      end

      def ==(other : self) : ::Bool
        {% for f in fields %}
          return false unless @{{f[:name]}} == other.@{{f[:name]}}
        {% end %}
        return false unless ::Protobuf::Message.extensions_equal?(@_protobuf_extensions, other.@_protobuf_extensions)
        unknown_fields == other.unknown_fields
      end

      def hash(hasher)
        {% for f in fields %}
          hasher = @{{f[:name]}}.hash(hasher)
        {% end %}
        hasher
      end

      # --- JSON ---

      # Parses a message from JSON (proto3 JSON mapping).
      def self.from_json(input : ::String | ::IO, options : ::Protobuf::JSON::ParseOptions) : self
        ::Protobuf::JSON.parse_document(input, self, options)
      end

      # Parses a message from JSON (proto3 JSON mapping). With
      # `ignore_unknown_fields: true`, unknown fields and enum value names
      # are skipped instead of raising `Protobuf::JSON::ParseError`.
      def self.from_json(input : ::String | ::IO, *, ignore_unknown_fields : ::Bool = false) : self
        from_json(input, ::Protobuf::JSON::ParseOptions.new(ignore_unknown_fields: ignore_unknown_fields))
      end

      # Reads a message from a JSON pull parser using the default options
      # (allows `Array(Message).from_json` and friends).
      def self.new(pull : ::JSON::PullParser) : self
        ::Protobuf::JSON.parsing do
          ::Protobuf::JSON.read_message(pull, self, ::Protobuf::JSON::Context.new(::Protobuf::JSON::ParseOptions.new))
        end
      end

      # :nodoc:
      def self.__protobuf_json_read(pull : ::JSON::PullParser, context : ::Protobuf::JSON::Context) : self
        ::Protobuf::JSON.read_message(pull, self, context)
      end

      {% unless @type.has_method?(:protobuf_json_write) %}
        # :nodoc:
        def protobuf_json_write(json : ::JSON::Builder, options : ::Protobuf::JSON::PrintOptions) : ::Nil
          json.object { protobuf_json_write_fields(json, options) }
        end
      {% end %}

        # Writes the JSON members of the message's fields (without the
        # enclosing braces).
        # :nodoc:
        def protobuf_json_write_fields(json : ::JSON::Builder, options : ::Protobuf::JSON::PrintOptions) : ::Nil
            {% for f in fields %}
              {% if f[:label] == :repeated || f[:label] == :map %}
                if options.emit_defaults || !@{{f[:name]}}.empty?
              {% elsif f[:nilable] %}
                unless (value = @{{f[:name]}}).nil?
              {% else %}
                value = @{{f[:name]}}
                if options.emit_defaults || !::Protobuf.default?(value)
              {% end %}
                  json.field(options.preserve_proto_field_names ? {{f[:proto_name]}} : {{f[:json_name]}}) do
                    {% if f[:label] == :map %}
                      json.object do
                        @{{f[:name]}}.each do |key, element|
                          json.field(::Protobuf::JSON.map_key(key)) { ::Protobuf::JSON.write_value(json, element, options) }
                        end
                      end
                    {% elsif f[:label] == :repeated %}
                      json.array do
                        @{{f[:name]}}.each { |element| ::Protobuf::JSON.write_value(json, element, options) }
                      end
                    {% else %}
                      ::Protobuf::JSON.write_value(json, value, options)
                    {% end %}
                  end
                end
            {% end %}
            if extensions = @_protobuf_extensions
              extensions.keys.sort!.each do |number|
                entry = extensions[number]
                next if entry.empty?
                json.field("[#{entry.field.full_name}]") { entry.write_json(json, options) }
              end
            end
        end

      {% unless @type.has_method?(:protobuf_json_merge) %}
        # :nodoc:
        def protobuf_json_merge(pull : ::JSON::PullParser, context : ::Protobuf::JSON::Context) : ::Nil
          unless pull.kind.begin_object?
            ::Protobuf::JSON.error(pull, "Expected an object for {{full_name.id}}, found #{::Protobuf::JSON.describe(pull)}")
          end
          seen = ::StaticArray(::Bool, {{fields.size + 1}}).new(false)
          {% for o in oneofs %}
            oneof_{{o.id}}_set = false
          {% end %}
          extensions_seen = nil
          pull.read_object do |key|
            case key
            {% for f, i in fields %}
              when {{ ([f[:json_name], f[:proto_name]].uniq).splat }}
                ::Protobuf::JSON.error(pull, "Duplicate field #{key.inspect}") if seen[{{i}}]
                seen[{{i}}] = true
                {% if f[:label] == :repeated %}
                  if pull.kind.null?
                    pull.read_null
                  else
                    unless pull.kind.begin_array?
                      ::Protobuf::JSON.error(pull, "Expected an array for {{f[:proto_name].id}}, found #{::Protobuf::JSON.describe(pull)}")
                    end
                    list = [] of ::{{f[:type]}}
                    pull.read_array do
                      element = ::Protobuf::JSON.read_value(pull, ::{{f[:type]}}, context)
                      list << element unless element.nil?
                    end
                    @{{f[:name]}} = list
                  end
                {% elsif f[:label] == :map %}
                  if pull.kind.null?
                    pull.read_null
                  else
                    unless pull.kind.begin_object?
                      ::Protobuf::JSON.error(pull, "Expected an object for {{f[:proto_name].id}}, found #{::Protobuf::JSON.describe(pull)}")
                    end
                    hash = {} of ::{{f[:key_type]}} => ::{{f[:value_type]}}
                    pull.read_object do |map_key|
                      parsed_key = ::Protobuf::JSON.read_map_key(pull, map_key, ::{{f[:key_type]}})
                      ::Protobuf::JSON.error(pull, "Duplicate map key #{map_key.inspect}") if hash.has_key?(parsed_key)
                      {% unless f[:value_null] %}
                        if pull.kind.null?
                          ::Protobuf::JSON.error(pull, "Map values must not be null")
                        end
                      {% end %}
                      element = ::Protobuf::JSON.read_value(pull, ::{{f[:value_type]}}, context)
                      hash[parsed_key] = element unless element.nil?
                    end
                    @{{f[:name]}} = hash
                  end
                {% else %}
                  {% unless f[:accepts_null] %}
                    if pull.kind.null?
                      pull.read_null
                      next
                    end
                  {% end %}
                  value = ::Protobuf::JSON.read_value(pull, ::{{f[:type]}}, context)
                  unless value.nil?
                    {% if f[:oneof] %}
                      ::Protobuf::JSON.error(pull, "Multiple members of oneof {{f[:oneof].id}} are set") if oneof_{{f[:oneof].id}}_set
                      oneof_{{f[:oneof].id}}_set = true
                      self.{{f[:name]}} = value
                    {% else %}
                      @{{f[:name]}} = value
                    {% end %}
                  end
                {% end %}
            {% end %}
            else
              extension = nil
              if key.starts_with?('[') && key.ends_with?(']')
                extension = ::Protobuf::Registry.extension(key[1...-1])
                extension = nil unless extension && extension.extendee == {{full_name}}
              end
              if extension
                unless (extensions_seen ||= ::Set(::Int32).new).add?(extension.number)
                  ::Protobuf::JSON.error(pull, "Duplicate extension #{key}")
                end
                extension.read_json_into(self.as(::Protobuf::Message), pull, context)
              elsif context.ignore_unknown_fields?
                pull.skip
              else
                ::Protobuf::JSON.error(pull, "Unknown field #{key.inspect} in {{full_name.id}}")
              end
            end
          end
        end
      {% end %}
    end

    # :nodoc:
    def self.extensions_equal?(a : Hash(Int32, ExtensionValue)?, b : Hash(Int32, ExtensionValue)?) : Bool
      a_entries = a.try(&.reject { |_, entry| entry.empty? }) || {} of Int32 => ExtensionValue
      b_entries = b.try(&.reject { |_, entry| entry.empty? }) || {} of Int32 => ExtensionValue
      return false unless a_entries.size == b_entries.size
      a_entries.all? do |number, entry|
        (other = b_entries[number]?) && entry.same_value?(other)
      end
    end

    # --- Required fields ---

    # Returns the paths of required (proto2) fields that are not set, in
    # this message and in nested messages (e.g. `["a", "child.b",
    # "items[0].c"]`).
    def missing_required_fields : Array(String)
      into = [] of String
      __protobuf_missing_required("", into)
      into
    end

    # Returns `true` if all required fields are set, recursively.
    def required_fields_set? : Bool
      missing_required_fields.empty?
    end

    # Raises `Protobuf::RequiredFieldsError` if required fields are missing.
    def check_required_fields! : self
      missing = missing_required_fields
      raise RequiredFieldsError.new(missing, self.class.full_name) unless missing.empty?
      self
    end

    # --- Extensions ---

    # Returns the value of *extension*, or `nil` if it is not set.
    #
    # Extensions are parsed into typed values when their extension is
    # registered (generated extensions always are); otherwise they are kept
    # as unknown fields and parsed on the first call to this method.
    def get_extension(extension : Extension(M, T)) : T? forall M, T
      {% raise "#{M} extensions cannot be used with #{@type}" unless M == @type %}
      if entry = __protobuf_extension_entry(extension.number)
        return entry.value if entry.is_a?(ExtensionEntry(M, T))
        # Stored through another handle for the same number: re-decode.
        __protobuf_delete_extension_entry(extension.number)
        io = IO::Memory.new
        entry.write(Writer.new(io), false)
        __protobuf_load_extension(extension, io.to_slice)
      end
      if bytes = __protobuf_take_unknown(extension.number)
        __protobuf_load_extension(extension, bytes)
      end
      __protobuf_extension_entry(extension.number).as?(ExtensionEntry(M, T)).try(&.value)
    end

    # Sets the value of *extension*.
    def set_extension(extension : Extension(M, T), value : T) : T forall M, T
      {% raise "#{M} extensions cannot be used with #{@type}" unless M == @type %}
      __protobuf_take_unknown(extension.number)
      __protobuf_set_extension_entry(extension.entry(value))
      value
    end

    # Returns `true` if *extension* is set (for repeated extensions: has
    # elements).
    def has_extension?(extension : Extension(M, T)) : Bool forall M, T
      value = get_extension(extension)
      {% if T < ::Array %}
        !value.nil? && !value.empty?
      {% else %}
        !value.nil?
      {% end %}
    end

    # Clears *extension*.
    def clear_extension(extension : Extension(M, T)) : Nil forall M, T
      {% raise "#{M} extensions cannot be used with #{@type}" unless M == @type %}
      __protobuf_take_unknown(extension.number)
      __protobuf_delete_extension_entry(extension.number)
    end

    # The extensions set on this message (parsed or set through
    # `#set_extension`), sorted by field number.
    def extension_fields : Array(ExtensionField)
      __protobuf_extension_entries.reject(&.empty?).map(&.field)
    end

    private def __protobuf_load_extension(extension : ExtensionField, bytes : Bytes) : Nil
      reader = Reader.new(bytes)
      until reader.eof?
        start = reader.pos
        number, wire_type = reader.read_tag
        if __protobuf_message_set? && number == 1 && wire_type.start_group?
          # MessageSet item: decode it as a regular extension payload.
          payload = nil
          loop do
            raise DecodeError.new("Unterminated MessageSet item") if reader.eof?
            item_number, item_wire_type = reader.read_tag
            break if item_wire_type.end_group?
            if item_number == 3 && item_wire_type.length_delimited?
              payload = reader.read_length_delimited
            else
              reader.skip_field(item_wire_type, item_number)
            end
          end
          if payload
            framed = IO::Memory.new
            Writer.new(framed).write_length_prefixed(payload)
            extension.decode_into(self.as(::Protobuf::Message), Reader.new(framed.to_slice), WireType::LengthDelimited, 0)
          end
          next
        end
        next if number == extension.number && extension.decode_into(self.as(::Protobuf::Message), reader, wire_type, start)
        reader.skip_field(wire_type, number)
        __protobuf_add_unknown(bytes[start, reader.pos - start])
      end
    end

    # --- JSON ---

    # Serializes the message as JSON (proto3 JSON mapping) with the default
    # options, for use with the standard library (`JSON.build`,
    # `Array#to_json`, ...).
    def to_json(json : ::JSON::Builder) : Nil
      protobuf_json_write(json, JSON::PrintOptions.new)
    end

    # Serializes the message as JSON with *options*.
    def to_json(json : ::JSON::Builder, options : JSON::PrintOptions) : Nil
      protobuf_json_write(json, options)
    end

    # Serializes the message as JSON with *options*, optionally indented.
    def to_json(options : JSON::PrintOptions, indent : String? = nil) : String
      JSON.generate(self, options, indent)
    end

    # Writes the message as JSON to *io*.
    def to_json(io : IO, options : JSON::PrintOptions = JSON::PrintOptions.new, indent : String? = nil) : Nil
      JSON.generate(io, self, options, indent)
    end

    # Serializes the message as JSON (proto3 JSON mapping).
    #
    # * *emit_defaults*: also print fields without presence that hold their
    #   default value (`always_print_fields_with_no_presence`).
    # * *preserve_proto_field_names*: use proto field names instead of
    #   lowerCamelCase JSON names.
    # * *enums_as_ints*: print enum values as numbers.
    # * *indent*: pretty-print with this indentation.
    def to_json(*, emit_defaults : Bool = false, preserve_proto_field_names : Bool = false,
                enums_as_ints : Bool = false, indent : String? = nil) : String
      options = JSON::PrintOptions.new(emit_defaults: emit_defaults,
        preserve_proto_field_names: preserve_proto_field_names, enums_as_ints: enums_as_ints)
      JSON.generate(self, options, indent)
    end

    # Merges fields parsed from JSON into this message.
    def merge_from_json(input : String | IO, options : JSON::ParseOptions = JSON::ParseOptions.new) : Nil
      JSON.parsing do
        pull = ::JSON::PullParser.new(JSON.validated(input))
        protobuf_json_merge(pull, JSON::Context.new(options))
        JSON.error(pull, "Unexpected content after the JSON value") unless pull.kind.eof?
      end
    end
  end

  alias MessageClass = Message::ClassMethods
end
