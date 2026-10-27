require "../../protobuf"
require "./tokenizer"

module Protobuf::Compiler
  # Looks up descriptors by fully qualified name (without a leading dot)
  # while interpreting options.
  abstract class TypeLookup
    alias D = Google::Protobuf

    # The message *name* and the file defining it.
    abstract def message(name : String) : {D::DescriptorProto, D::FileDescriptorProto}?

    # The enum *name*.
    abstract def enum(name : String) : D::EnumDescriptorProto?

    # Resolves the extension *name* as written in an option (relative to
    # *scope*), returning its full name, descriptor and defining file.
    abstract def extension(name : String, scope : String) : {String, D::FieldDescriptorProto, D::FileDescriptorProto}?

    # The extension of *extendee* (a full name) with field number *number*.
    abstract def extension_by_number(extendee : String, number : Int32) : {D::FieldDescriptorProto, D::FileDescriptorProto}?
  end

  # Resolves the types of `descriptor.proto` (the standard options) from
  # the descriptors compiled into the program.
  class BuiltinLookup < TypeLookup
    def message(name : String) : {D::DescriptorProto, D::FileDescriptorProto}?
      descriptor = Protobuf::Registry.message_descriptor(name) || return nil
      file = Protobuf::Registry.file_containing_symbol(name) || return nil
      {descriptor, file}
    end

    def enum(name : String) : D::EnumDescriptorProto?
      Protobuf::Registry.enum_descriptor(name)
    end

    def extension(name : String, scope : String) : {String, D::FieldDescriptorProto, D::FileDescriptorProto}?
      nil
    end

    def extension_by_number(extendee : String, number : Int32) : {D::FieldDescriptorProto, D::FileDescriptorProto}?
      nil
    end
  end

  # Interprets `uninterpreted_option`s into options messages, like protoc's
  # `OptionInterpreter`: each option is encoded as a protobuf field (wrapped
  # in its enclosing messages for `a.b.c` names) and merged into the options
  # message. Options with a source retention are dropped (protoc strips
  # them from the descriptors given to plugins). Custom options (extensions)
  # that the options message does not know end up in its unknown fields,
  # in declaration order, as with protoc.
  class OptionInterpreter
    alias D = Google::Protobuf
    alias FieldType = D::FieldDescriptorProto::Type
    alias Label = D::FieldDescriptorProto::Label

    # Position and aggregate tokens of an uninterpreted option, recorded by
    # the parser.
    record OptionSource, line : Int32, column : Int32, aggregate : Array(Token)?

    def initialize(@lookup : TypeLookup, @filename : String, @sources : Hash(UInt64, OptionSource))
    end

    # Interprets the options of every declaration of *file*. With
    # `custom: false`, only standard options are interpreted.
    def self.interpret_file(file : D::FileDescriptorProto, lookup : TypeLookup, filename : String,
                            sources : Hash(UInt64, OptionSource), custom : Bool) : Nil
      new(lookup, filename, sources).interpret_file(file, custom)
    end

    def interpret_file(file : D::FileDescriptorProto, custom : Bool) : Nil
      package = file.package || ""
      file.options.try { |options| file.options = nil if interpret(options, "google.protobuf.FileOptions", package, custom) }
      file.message_type.each { |message| interpret_message(message, package.empty? ? (message.name || "") : "#{package}.#{message.name}", custom) }
      file.enum_type.each { |enum_type| interpret_enum(enum_type, package.empty? ? (enum_type.name || "") : "#{package}.#{enum_type.name}", custom) }
      file.extension.each { |field| interpret_field(field, package, custom) }
      file.service.each do |service|
        scope = package.empty? ? (service.name || "") : "#{package}.#{service.name}"
        service.options.try { |options| service.options = nil if interpret(options, "google.protobuf.ServiceOptions", scope, custom) }
        service.method.each do |method|
          method.options.try { |options| method.options = nil if interpret(options, "google.protobuf.MethodOptions", "#{scope}.#{method.name}", custom) }
        end
      end
    end

    private def interpret_message(message : D::DescriptorProto, scope : String, custom : Bool) : Nil
      message.options.try { |options| message.options = nil if interpret(options, "google.protobuf.MessageOptions", scope, custom) }
      message.field.each { |field| interpret_field(field, scope, custom) }
      message.extension.each { |field| interpret_field(field, scope, custom) }
      message.oneof_decl.each do |oneof|
        oneof.options.try { |options| oneof.options = nil if interpret(options, "google.protobuf.OneofOptions", "#{scope}.#{oneof.name}", custom) }
      end
      message.extension_range.each do |range|
        range.options.try { |options| range.options = nil if interpret(options, "google.protobuf.ExtensionRangeOptions", scope, custom) }
      end
      message.nested_type.each { |nested| interpret_message(nested, "#{scope}.#{nested.name}", custom) }
      message.enum_type.each { |enum_type| interpret_enum(enum_type, "#{scope}.#{enum_type.name}", custom) }
    end

    private def interpret_field(field : D::FieldDescriptorProto, scope : String, custom : Bool) : Nil
      field.options.try { |options| field.options = nil if interpret(options, "google.protobuf.FieldOptions", "#{scope.empty? ? "" : "#{scope}."}#{field.name}", custom) }
    end

    private def interpret_enum(enum_type : D::EnumDescriptorProto, scope : String, custom : Bool) : Nil
      enum_type.options.try { |options| enum_type.options = nil if interpret(options, "google.protobuf.EnumOptions", scope, custom) }
      enum_type.value.each do |value|
        value.options.try { |options| value.options = nil if interpret(options, "google.protobuf.EnumValueOptions", scope, custom) }
      end
    end

    # Interprets the uninterpreted options of *options* (an options message
    # of type *type_name*, e.g. `google.protobuf.FileOptions`) declared in
    # *scope*. With `custom: false` only options without extension parts are
    # interpreted; the others are kept.
    #
    # Returns `true` if options were dropped because of their source
    # retention and the options message is now empty, in which case protoc
    # omits it.
    def interpret(options, type_name : String, scope : String, custom : Bool = true) : Bool
      pending = options.uninterpreted_option
      return false if pending.empty?
      remaining = [] of D::UninterpretedOption
      dropped = false
      @set_paths.clear
      pending.each do |option|
        if !custom && option.name.any? { |part| part.is_extension == true }
          remaining << option
        else
          dropped = true unless apply(options, type_name, scope, option)
        end
      end
      options.uninterpreted_option = remaining
      # Like protoc, bring custom options (unknown fields of the options
      # message) into canonical form: parsed with their extensions known,
      # merged and serialized in field number order.
      unknown = options.unknown_fields
      unless unknown.empty?
        canonical = canonicalize(unknown, type_name)
        options.discard_unknown_fields
        options.__protobuf_add_unknown(canonical) unless canonical.empty?
      end
      dropped && remaining.empty? && options.to_protobuf.empty?
    end

    @set_paths = Set(String).new

    private record Record, number : Int32, wire_type : Protobuf::WireType, value : Bytes, raw : Bytes

    # Canonicalizes encoded fields of message *type_name*: known fields and
    # extensions in field number order (singular fields merged or last
    # wins, repeated scalars packed as declared), then unknown fields in
    # their original order.
    def canonicalize(bytes : Bytes, type_name : String) : Bytes
      message, file = @lookup.message(type_name) || return bytes
      records = [] of Record
      reader = Protobuf::Reader.new(bytes)
      until reader.eof?
        start = reader.pos
        number, wire_type = reader.read_tag
        value_start = reader.pos
        if wire_type.length_delimited?
          value = reader.read_length_delimited
        else
          reader.skip_field(wire_type, number)
          value = bytes[value_start, reader.pos - value_start]
          # Drop the end group tag from group payloads.
          if wire_type.start_group?
            end_tag = IO::Memory.new
            Protobuf::Writer.new(end_tag).write_tag(number, Protobuf::WireType::EndGroup)
            value = value[0, value.size - end_tag.size]
          end
        end
        records << Record.new(number, wire_type, value, bytes[start, reader.pos - start])
      end
      if message.options.try(&.message_set_wire_format)
        return canonicalize_message_set(records, type_name)
      end

      output = IO::Memory.new
      writer = Protobuf::Writer.new(output)
      unknown = IO::Memory.new
      groups = records.group_by(&.number)
      groups.keys.sort!.each do |number|
        list = groups[number]
        field, field_file = (message.field.find { |f| f.number == number }.try { |f| {f, file} }) ||
                            @lookup.extension_by_number(type_name, number) ||
                            {nil, file}
        unless field
          next
        end
        type = field.type.not_nil!
        repeated = field.label == Label::LABEL_REPEATED
        if type.type_message? || type.type_group?
          nested = (field.type_name || "").lchop('.')
          payloads = repeated ? list.map(&.value) : [list.reduce(IO::Memory.new) { |io, record| io.write(record.value); io }.to_slice]
          payloads.each do |payload|
            inner = canonicalize(payload, nested)
            if OptionInterpreter.delimited?(field, field_file)
              writer.write_tag(number, Protobuf::WireType::StartGroup)
              output.write(inner)
              writer.write_tag(number, Protobuf::WireType::EndGroup)
            else
              writer.write_tag(number, Protobuf::WireType::LengthDelimited)
              writer.write_length_prefixed(inner)
            end
          end
        elsif repeated && !(type.type_string? || type.type_bytes?)
          element_wire = OptionInterpreter.scalar_wire_type(type)
          values = [] of Bytes
          list.each do |record|
            if record.wire_type.length_delimited?
              packed = Protobuf::Reader.new(record.value)
              until packed.eof?
                start = packed.pos
                case element_wire
                when .varint?  then packed.read_varint
                when .fixed32? then packed.read_fixed32_raw
                else                packed.read_fixed64_raw
                end
                values << record.value[start, packed.pos - start]
              end
            else
              values << record.value
            end
          end
          if OptionInterpreter.packed?(field, field_file)
            unless values.empty?
              writer.write_tag(number, Protobuf::WireType::LengthDelimited)
              writer.write_varint(values.sum(&.size).to_u64)
              values.each { |value| output.write(value) }
            end
          else
            values.each do |value|
              writer.write_tag(number, element_wire)
              output.write(value)
            end
          end
        else
          selected = repeated ? list : [list.last]
          selected.each do |record|
            writer.write_tag(number, record.wire_type)
            if record.wire_type.length_delimited?
              writer.write_length_prefixed(record.value)
            else
              output.write(record.value)
            end
          end
        end
      end
      records.each do |record|
        known = message.field.any? { |f| f.number == record.number } || @lookup.extension_by_number(type_name, record.number)
        unknown.write(record.raw) unless known
      end
      output.write(unknown.to_slice)
      output.to_slice
    end

    # Canonicalizes MessageSet items: merged per type id and sorted.
    private def canonicalize_message_set(records : Array(Record), type_name : String) : Bytes
      items = {} of Int32 => IO::Memory
      unknown = IO::Memory.new
      records.each do |record|
        type_id = nil
        payload = nil
        if record.number == 1 && record.wire_type.start_group?
          item = Protobuf::Reader.new(record.value)
          until item.eof?
            number, wire_type = item.read_tag
            if number == 2 && wire_type.varint?
              type_id = item.read_varint.to_i32!
            elsif number == 3 && wire_type.length_delimited?
              payload = item.read_length_delimited
            else
              item.skip_field(wire_type, number)
            end
          end
        end
        if type_id && payload && @lookup.extension_by_number(type_name, type_id)
          (items[type_id] ||= IO::Memory.new).write(payload)
        else
          unknown.write(record.raw)
        end
      end
      output = IO::Memory.new
      items.keys.sort!.each do |type_id|
        field, _ = @lookup.extension_by_number(type_name, type_id).not_nil!
        inner = canonicalize(items[type_id].to_slice, (field.type_name || "").lchop('.'))
        io = IO::Memory.new
        Protobuf::Writer.new(io).write_bytes_field(type_id, inner)
        output.write(AggregateEncoder.message_set_item(type_id, io.to_slice))
      end
      output.write(unknown.to_slice)
      output.to_slice
    end

    # The wire type of a scalar field type.
    def self.scalar_wire_type(type : FieldType) : Protobuf::WireType
      case type
      when .type_double?, .type_fixed64?, .type_sfixed64? then Protobuf::WireType::Fixed64
      when .type_float?, .type_fixed32?, .type_sfixed32?  then Protobuf::WireType::Fixed32
      when .type_string?, .type_bytes?, .type_message?    then Protobuf::WireType::LengthDelimited
      when .type_group?                                   then Protobuf::WireType::StartGroup
      else                                                     Protobuf::WireType::Varint
      end
    end

    # Applies *option*; returns `false` if it was dropped (source retention).
    private def apply(options, type_name : String, scope : String, option : D::UninterpretedOption) : Bool
      message, file = @lookup.message(type_name) || error(option, "Options type #{type_name} is unknown.")
      path = [] of D::FieldDescriptorProto
      files = [] of D::FileDescriptorProto
      current_name = type_name
      option.name.each_with_index do |part, i|
        name = part.name_part || ""
        field_file = file
        field = if part.is_extension == true
                  full_name, extension, field_file = @lookup.extension(name, scope) ||
                                                     error(option, "Option \"(#{name})\" unknown. Ensure that your proto definition file imports the proto which defines the option.")
                  unless extension.extendee.try(&.lchop('.')) == current_name
                    error(option, "Option \"(#{full_name})\" is not a field or extension of message \"#{message.name}\".")
                  end
                  extension
                else
                  message.field.find { |f| f.name == name } ||
                    error(option, "Option \"#{display_name(option, i)}\" unknown. Ensure that your proto definition file imports the proto which defines the option.")
                end
        path << field
        files << field_file
        if i < option.name.size - 1
          type = field.type
          unless type && (type.type_message? || type.type_group?)
            error(option, "Option \"#{display_name(option, i)}\" is an atomic type, not a message.")
          end
          if field.label == Label::LABEL_REPEATED
            error(option, "Option field \"#{display_name(option, i)}\" is a repeated message. Repeated message options must be initialized using an aggregate value.")
          end
          current_name = (field.type_name || "").lchop('.')
          message, file = @lookup.message(current_name) || error(option, "Unknown type #{current_name}.")
        end
      end
      check_already_set(option, path)
      # Source-retention options are not part of the runtime descriptors;
      # protoc keeps the (empty) messages enclosing them.
      if source = path.index { |field| source_retention?(field) }
        return false if source == 0
        bytes = Bytes.empty
        (source - 1).downto(0) { |i| bytes = wrap(path[i], files[i], bytes) }
        options.merge_from_protobuf(Protobuf::Reader.new(bytes))
        return true
      end

      leaf = path.last
      bytes = encode_leaf(option, leaf, files.last, display_name(option, option.name.size - 1))
      (path.size - 2).downto(0) do |i|
        bytes = wrap(path[i], files[i], bytes)
      end
      options.merge_from_protobuf(Protobuf::Reader.new(bytes))
      true
    rescue ex : Protobuf::DecodeError
      error(option, "Invalid value for option \"#{display_name(option, option.name.size - 1)}\": #{ex.message}")
    end

    # protoc rejects setting a non-repeated option twice, or a message
    # option both as a whole and through its fields.
    private def check_already_set(option : D::UninterpretedOption, path : Array(D::FieldDescriptorProto)) : Nil
      key = path.map { |field| "#{field.extendee}:#{field.number}" }.join('/')
      return if path.last.label == Label::LABEL_REPEATED
      conflict = @set_paths.any? do |existing|
        existing == key || key.starts_with?("#{existing}/") || existing.starts_with?("#{key}/")
      end
      error(option, "Option \"#{display_name(option, option.name.size - 1)}\" was already set.") if conflict
      @set_paths << key
    end

    private def display_name(option : D::UninterpretedOption, upto : Int32) : String
      option.name[0..upto].map { |part| part.is_extension ? "(#{part.name_part})" : part.name_part }.join('.')
    end

    def self.source_retention?(field : D::FieldDescriptorProto) : Bool
      field.options.try(&.retention) == D::FieldOptions::OptionRetention::RETENTION_SOURCE
    end

    private def source_retention?(field) : Bool
      OptionInterpreter.source_retention?(field)
    end

    # Wraps the encoded fields *inner* in a field of message type.
    private def wrap(field : D::FieldDescriptorProto, file : D::FileDescriptorProto, inner : Bytes) : Bytes
      io = IO::Memory.new
      writer = Protobuf::Writer.new(io)
      number = field.number || 0
      if OptionInterpreter.delimited?(field, file)
        writer.write_tag(number, Protobuf::WireType::StartGroup)
        io.write(inner)
        writer.write_tag(number, Protobuf::WireType::EndGroup)
      else
        writer.write_tag(number, Protobuf::WireType::LengthDelimited)
        writer.write_length_prefixed(inner)
      end
      io.to_slice
    end

    # Encodes the option's value as a complete field.
    private def encode_leaf(option : D::UninterpretedOption, field : D::FieldDescriptorProto, file : D::FileDescriptorProto, name : String) : Bytes
      type = field.type || error(option, "Option \"#{name}\" has no type.")
      io = IO::Memory.new
      writer = Protobuf::Writer.new(io)
      number = field.number || 0
      if type.type_message? || type.type_group?
        aggregate = @sources[option.object_id]?.try(&.aggregate)
        unless aggregate
          error(option, "Option \"#{name}\" is a message. To set the entire message, use syntax like \"#{name} = { <proto text format> }\". To set fields within it, use syntax like \"#{name}.foo = value\".")
        end
        type_name = (field.type_name || "").lchop('.')
        message, message_file = @lookup.message(type_name) || error(option, "Unknown type #{type_name}.")
        encoder = AggregateEncoder.new(aggregate, @lookup, @filename)
        inner = encoder.encode(message, message_file)
        return wrap(field, file, inner)
      end
      value = scalar_value(option, field, name)
      AggregateEncoder.write_scalar(writer, field, value, false)
      io.to_slice
    end

    # Converts an uninterpreted value to the field's scalar type.
    private def scalar_value(option : D::UninterpretedOption, field : D::FieldDescriptorProto, name : String) : AggregateEncoder::Scalar
      type = field.type.not_nil!
      positive = option.positive_int_value
      negative = option.negative_int_value
      case type
      when .type_int32?, .type_sint32?, .type_sfixed32?
        value = integer(option, name, "int32")
        error(option, "Value out of range for int32 option \"#{name}\".") unless Int32::MIN <= value <= Int32::MAX
        value.to_i32
      when .type_int64?, .type_sint64?, .type_sfixed64?
        value = integer(option, name, "int64")
        error(option, "Value out of range for int64 option \"#{name}\".") unless Int64::MIN <= value <= Int64::MAX
        value.to_i64
      when .type_uint32?, .type_fixed32?
        error(option, "Value must be non-negative integer for uint32 option \"#{name}\".") unless positive
        error(option, "Value out of range for uint32 option \"#{name}\".") unless positive <= UInt32::MAX
        positive.to_u32
      when .type_uint64?, .type_fixed64?
        error(option, "Value must be non-negative integer for uint64 option \"#{name}\".") unless positive
        positive
      when .type_float?, .type_double?
        value = if double = option.double_value
                  double
                elsif positive
                  positive.to_f64
                elsif negative
                  negative.to_f64
                elsif (identifier = option.identifier_value) && identifier.in?("inf", "nan")
                  identifier == "inf" ? Float64::INFINITY : Float64::NAN
                else
                  error(option, "Value must be number for #{type.type_float? ? "float" : "double"} option \"#{name}\".")
                end
        type.type_float? ? value.to_f32 : value
      when .type_bool?
        case option.identifier_value
        when "true"  then true
        when "false" then false
        else              error(option, "Value must be \"true\" or \"false\" for boolean option \"#{name}\".")
        end
      when .type_enum?
        identifier = option.identifier_value ||
                     error(option, "Value must be identifier for enum-valued option \"#{name}\".")
        enum_name = (field.type_name || "").lchop('.')
        enum_type = @lookup.enum(enum_name) || error(option, "Unknown enum #{enum_name}.")
        value = enum_type.value.find { |v| v.name == identifier } ||
                error(option, "Enum type \"#{enum_name}\" has no value named \"#{identifier}\" for option \"#{name}\".")
        AggregateEncoder::EnumNumber.new(value.number || 0)
      when .type_string?, .type_bytes?
        bytes = option.string_value ||
                error(option, "Value must be quoted string for string option \"#{name}\".")
        type.type_string? ? String.new(bytes) : bytes
      else
        error(option, "Unsupported type for option \"#{name}\".")
      end
    end

    private def integer(option : D::UninterpretedOption, name : String, type : String) : Int128
      if positive = option.positive_int_value
        positive.to_i128
      elsif negative = option.negative_int_value
        negative.to_i128
      else
        error(option, "Value must be integer for #{type} option \"#{name}\".")
      end
    end

    private def error(option : D::UninterpretedOption, message : String) : NoReturn
      source = @sources[option.object_id]?
      raise ParseError.new(@filename, source.try(&.line) || 0, source.try(&.column) || 0, message)
    end

    # Returns `true` if *field* (declared in *file*) uses group encoding.
    def self.delimited?(field : D::FieldDescriptorProto, file : D::FileDescriptorProto) : Bool
      return true if field.type.try(&.type_group?)
      return false unless field.type.try(&.type_message?) && file.syntax == "editions"
      encoding = field.options.try(&.features).try(&.message_encoding) ||
                 file.options.try(&.features).try(&.message_encoding)
      encoding == D::FeatureSet::MessageEncoding::DELIMITED
    end

    # Returns `true` if the repeated scalar *field* (declared in *file*) is
    # packed.
    def self.packed?(field : D::FieldDescriptorProto, file : D::FileDescriptorProto) : Bool
      packed = field.options.try(&.packed)
      return packed unless packed.nil?
      case file.syntax
      when "proto3"
        true
      when "editions"
        encoding = field.options.try(&.features).try(&.repeated_field_encoding) ||
                   file.options.try(&.features).try(&.repeated_field_encoding)
        encoding != D::FeatureSet::RepeatedFieldEncoding::EXPANDED
      else
        false
      end
    end
  end

  # Encodes a text-format aggregate option value (`{ a: 1 b { c: "x" } }`)
  # as protobuf binary data, the way protoc does: fields are serialized in
  # field number order.
  class AggregateEncoder
    alias D = Google::Protobuf
    alias FieldType = D::FieldDescriptorProto::Type
    alias Label = D::FieldDescriptorProto::Label

    # The number of an enum value.
    record EnumNumber, value : Int32

    alias Scalar = Int32 | Int64 | UInt32 | UInt64 | Float32 | Float64 | Bool | String | Bytes | EnumNumber

    @index = 0

    def initialize(@tokens : Array(Token), @lookup : TypeLookup, @filename : String)
    end

    # Encodes the whole token list as a message of type *message*.
    def encode(message : D::DescriptorProto, file : D::FileDescriptorProto) : Bytes
      bytes = encode_message(message, file, nil)
      error(current, "Expected end of aggregate value, found #{current}.") unless at_end?
      bytes
    end

    private record Entry, number : Int32, bytes : Bytes

    # Maximum nesting of messages in an aggregate value.
    MAX_DEPTH = 100

    @depth = 0

    private def encode_message(message : D::DescriptorProto, file : D::FileDescriptorProto, close : String?) : Bytes
      @depth += 1
      error(current, "Message is too deeply nested.") if @depth > MAX_DEPTH
      encode_message_body(message, file, close)
    ensure
      @depth -= 1
    end

    private def encode_message_body(message : D::DescriptorProto, file : D::FileDescriptorProto, close : String?) : Bytes
      entries = [] of Entry
      singular = Set(Int32).new
      packed_values = {} of Int32 => {D::FieldDescriptorProto, Array(Scalar)}
      message_set = message.options.try(&.message_set_wire_format) == true
      loop do
        if close
          if current.symbol?(close)
            advance
            break
          end
          error(current, "Expected \"#{close}\", found end of aggregate value.") if at_end?
        else
          break if at_end?
        end
        name_token = current
        if name_token.symbol?("[") && any_url_ahead?
          error(name_token, "Any type URLs are only allowed in google.protobuf.Any values.") unless full_message_name(message, file) == "google.protobuf.Any"
          error(name_token, "Any value specified more than once.") unless singular.add?(1) && singular.add?(2)
          entries.concat(encode_any_expansion)
          advance if current.symbol?(";") || current.symbol?(",")
          next
        end
        field, field_file = parse_field_name(message, file)
        number = field.number || 0
        type = field.type || error(name_token, "Field #{field.name} has no type.")
        repeated = field.label == Label::LABEL_REPEATED
        is_message = type.type_message? || type.type_group?
        if current.symbol?(":")
          advance
        elsif !is_message
          error(current, "Expected \":\", found #{current}.")
        end
        if !repeated && !singular.add?(number)
          error(name_token, "Non-repeated field \"#{field.name}\" is specified multiple times.")
        end
        skip = OptionInterpreter.source_retention?(field)
        values = [] of Bytes
        if current.symbol?("[")
          error(current, "Field \"#{field.name}\" is not repeated.") unless repeated
          advance
          unless current.symbol?("]")
            loop do
              read_value(field, field_file, is_message, values, packed_values)
              break unless current.symbol?(",")
              advance
            end
          end
          expect("]")
        else
          read_value(field, field_file, is_message, values, packed_values)
        end
        if message_set && !message.field.any? { |f| f.number == number }
          # MessageSet extensions are encoded as items: group 1 with the
          # type id (2) and the message (3).
          values.map! { |bytes| AggregateEncoder.message_set_item(number, bytes) }
        end
        values.each { |bytes| entries << Entry.new(number, bytes) } unless skip
        packed_values.delete(number) if skip
        advance if current.symbol?(";") || current.symbol?(",")
      end
      packed_values.each do |number, (field, list)|
        next if list.empty?
        payload = IO::Memory.new
        packed_writer = Protobuf::Writer.new(payload)
        list.each { |value| AggregateEncoder.write_raw(packed_writer, field, value) }
        io = IO::Memory.new
        writer = Protobuf::Writer.new(io)
        writer.write_tag(number, Protobuf::WireType::LengthDelimited)
        writer.write_length_prefixed(payload.to_slice)
        entries << Entry.new(number, io.to_slice)
      end
      output = IO::Memory.new
      entries.each_with_index.to_a.sort_by! { |(entry, i)| {entry.number, i} }.each { |(entry, _)| output.write(entry.bytes) }
      output.to_slice
    end

    # Converts an encoded length-delimited field into a MessageSet item.
    def self.message_set_item(number : Int32, field : Bytes) : Bytes
      reader = Protobuf::Reader.new(field)
      reader.read_tag
      payload = reader.read_length_delimited
      io = IO::Memory.new
      writer = Protobuf::Writer.new(io)
      writer.write_tag(1, Protobuf::WireType::StartGroup)
      writer.write_tag(2, Protobuf::WireType::Varint)
      writer.write_varint(number.to_u64)
      writer.write_tag(3, Protobuf::WireType::LengthDelimited)
      writer.write_length_prefixed(payload)
      writer.write_tag(1, Protobuf::WireType::EndGroup)
      io.to_slice
    end

    # Returns `true` if the bracketed name at the current position is an
    # Any type URL (contains a '/').
    private def any_url_ahead? : Bool
      index = @index + 1
      while (token = @tokens[index]?) && !token.symbol?("]")
        return true if token.symbol?("/")
        index += 1
      end
      false
    end

    # Encodes `[type.googleapis.com/pkg.Type] { ... }` inside an Any value
    # as its type_url and value fields.
    private def encode_any_expansion : Array(Entry)
      expect("[")
      url = String.build do |io|
        until current.symbol?("]")
          error(current, "Unexpected end of Any type URL.") if at_end?
          io << advance.text
        end
      end
      expect("]")
      advance if current.symbol?(":")
      type_name = url.rpartition('/')[2]
      message, message_file = @lookup.message(type_name) || error(current, "Unknown type \"#{type_name}\" in Any type URL.")
      close = if current.symbol?("{")
                "}"
              elsif current.symbol?("<")
                ">"
              else
                error(current, "Expected \"{\" or \"<\", found #{current}.")
              end
      advance
      inner = encode_message(message, message_file, close)
      url_io = IO::Memory.new
      Protobuf::Writer.new(url_io).write_string_field(1, url)
      value_io = IO::Memory.new
      Protobuf::Writer.new(value_io).write_bytes_field(2, inner)
      [Entry.new(1, url_io.to_slice), Entry.new(2, value_io.to_slice)]
    end

    private def read_value(field : D::FieldDescriptorProto, file : D::FileDescriptorProto, is_message : Bool,
                           values : Array(Bytes), packed_values) : Nil
      number = field.number || 0
      if is_message
        close = if current.symbol?("{")
                  "}"
                elsif current.symbol?("<")
                  ">"
                else
                  error(current, "Expected \"{\" or \"<\", found #{current}.")
                end
        advance
        type_name = (field.type_name || "").lchop('.')
        message, message_file = @lookup.message(type_name) || error(current, "Unknown type #{type_name}.")
        inner = encode_message(message, message_file, close)
        io = IO::Memory.new
        writer = Protobuf::Writer.new(io)
        if OptionInterpreter.delimited?(field, file)
          writer.write_tag(number, Protobuf::WireType::StartGroup)
          io.write(inner)
          writer.write_tag(number, Protobuf::WireType::EndGroup)
        else
          writer.write_tag(number, Protobuf::WireType::LengthDelimited)
          writer.write_length_prefixed(inner)
        end
        values << io.to_slice
        return
      end
      value = read_scalar(field)
      type = field.type.not_nil!
      if field.label == Label::LABEL_REPEATED && !(type.type_string? || type.type_bytes?) && OptionInterpreter.packed?(field, file)
        (packed_values[number] ||= {field, [] of Scalar})[1] << value
      else
        io = IO::Memory.new
        AggregateEncoder.write_scalar(Protobuf::Writer.new(io), field, value, false)
        values << io.to_slice
      end
    end

    # Parses a field name: an identifier (field or group type name) or an
    # extension in brackets.
    private def parse_field_name(message : D::DescriptorProto, file : D::FileDescriptorProto) : {D::FieldDescriptorProto, D::FileDescriptorProto}
      token = current
      if token.symbol?("[")
        advance
        name = String.build do |io|
          io << expect_identifier.text
          while current.symbol?(".") || current.symbol?("/")
            separator = advance.text
            error(current, "Any type URLs are not supported in option values.") if separator == "/"
            io << '.' << expect_identifier.text
          end
        end
        expect("]")
        full_name, extension, defining = @lookup.extension(".#{name}", "") ||
                                         error(token, "Extension \"#{name}\" is not defined.")
        unless (extension.extendee || "").lchop('.') == full_message_name(message, file)
          error(token, "Extension \"#{full_name}\" is not an extension of \"#{message.name}\".")
        end
        return {extension, defining}
      end
      name_token = expect_identifier
      name = name_token.text
      field = message.field.find { |f| f.name == name } ||
              message.field.find { |f| f.type.try(&.type_group?) && (f.type_name || "").split('.').last == name } ||
              error(name_token, "Message type \"#{full_message_name(message, file)}\" has no field named \"#{name}\".")
      {field, file}
    end

    private def full_message_name(message : D::DescriptorProto, file : D::FileDescriptorProto) : String
      # Only used for comparisons with extendee names; nested messages are
      # found by searching the file.
      package = file.package || ""
      path = find_path(file.message_type, message) || [message.name || ""]
      ([package] + path).reject(&.empty?).join('.')
    end

    private def find_path(messages : Array(D::DescriptorProto), target : D::DescriptorProto) : Array(String)?
      messages.each do |message|
        return [message.name || ""] if message.same?(target)
        if nested = find_path(message.nested_type, target)
          return [message.name || ""] + nested
        end
      end
      nil
    end

    private def read_scalar(field : D::FieldDescriptorProto) : Scalar
      type = field.type.not_nil!
      token = current
      if type.type_string? || type.type_bytes?
        error(token, "Expected string, found #{token}.") unless token.kind.string?
        io = IO::Memory.new
        while current.kind.string?
          io.write(advance.string_value.not_nil!.to_slice)
        end
        return type.type_string? ? String.new(io.to_slice) : io.to_slice
      end
      negative = false
      if current.symbol?("-")
        advance
        negative = true
      end
      token = current
      case type
      when .type_bool?
        error(token, "Invalid value for boolean field \"#{field.name}\".") if negative
        case token.text
        when "true", "True", "t", "1"   then advance; true
        when "false", "False", "f", "0" then advance; false
        else                                 error(token, "Invalid value for boolean field \"#{field.name}\".")
        end
      when .type_enum?
        enum_name = (field.type_name || "").lchop('.')
        enum_type = @lookup.enum(enum_name) || error(token, "Unknown enum #{enum_name}.")
        if token.kind.identifier? && !negative
          advance
          value = enum_type.value.find { |v| v.name == token.text } ||
                  error(token, "Unknown enumeration value of \"#{token.text}\" for field \"#{field.name}\".")
          EnumNumber.new(value.number || 0)
        elsif token.kind.integer?
          advance
          number = AggregateEncoder.parse_integer(token.text) || error(token, "Integer out of range.")
          number = -number if negative
          error(token, "Integer out of range.") unless Int32::MIN <= number <= Int32::MAX
          EnumNumber.new(number.to_i32)
        else
          error(token, "Expected integer or identifier, found #{token}.")
        end
      when .type_float?, .type_double?
        value = if token.kind.integer?
                  (AggregateEncoder.parse_integer(token.text) || error(token, "Integer out of range.")).to_f64
                elsif token.kind.float?
                  token.text.rchop('f').rchop('F').to_f64? || error(token, "Invalid number #{token.text}.")
                elsif token.kind.identifier? && token.text.downcase.in?("inf", "infinity")
                  Float64::INFINITY
                elsif token.kind.identifier? && token.text.downcase == "nan"
                  Float64::NAN
                else
                  error(token, "Expected double, found #{token}.")
                end
        advance
        value = -value if negative
        type.type_float? ? value.to_f32 : value
      else
        error(token, "Expected integer, found #{token}.") unless token.kind.integer?
        advance
        number = AggregateEncoder.parse_integer(token.text) || error(token, "Integer out of range.")
        number = -number if negative
        case type
        when .type_int32?, .type_sint32?, .type_sfixed32?
          error(token, "Integer out of range.") unless Int32::MIN <= number <= Int32::MAX
          number.to_i32
        when .type_int64?, .type_sint64?, .type_sfixed64?
          error(token, "Integer out of range.") unless Int64::MIN <= number <= Int64::MAX
          number.to_i64
        when .type_uint32?, .type_fixed32?
          error(token, "Integer out of range.") unless 0 <= number <= UInt32::MAX
          number.to_u32
        else
          error(token, "Integer out of range.") unless 0 <= number <= UInt64::MAX
          number.to_u64
        end
      end
    end

    # Parses a decimal, hexadecimal or octal integer literal.
    def self.parse_integer(text : String) : Int128?
      value = if text.starts_with?("0x") || text.starts_with?("0X")
                text[2..].to_u64?(16)
              elsif text.size > 1 && text.starts_with?('0')
                text.to_u64?(8)
              else
                text.to_u64?
              end
      value.try(&.to_i128)
    end

    # Writes *value* as a complete field.
    def self.write_scalar(writer : Protobuf::Writer, field : D::FieldDescriptorProto, value : Scalar, packed : Bool) : Nil
      type = field.type.not_nil!
      wire_type = case type
                  when .type_double?, .type_fixed64?, .type_sfixed64? then Protobuf::WireType::Fixed64
                  when .type_float?, .type_fixed32?, .type_sfixed32?  then Protobuf::WireType::Fixed32
                  when .type_string?, .type_bytes?, .type_message?    then Protobuf::WireType::LengthDelimited
                  else                                                     Protobuf::WireType::Varint
                  end
      writer.write_tag(field.number || 0, wire_type)
      write_raw(writer, field, value)
    end

    # Writes *value* without a tag.
    def self.write_raw(writer : Protobuf::Writer, field : D::FieldDescriptorProto, value : Scalar) : Nil
      type = field.type.not_nil!
      case value
      when EnumNumber then writer.write_int32(value.value)
      when String     then writer.write_string(value)
      when Bytes      then writer.write_bytes(value)
      when Bool       then writer.write_bool(value)
      when Float32    then writer.write_float(value)
      when Float64    then writer.write_double(value)
      when Int32
        case type
        when .type_sint32?   then writer.write_sint32(value)
        when .type_sfixed32? then writer.write_sfixed32(value)
        else                      writer.write_int32(value)
        end
      when Int64
        case type
        when .type_sint64?   then writer.write_sint64(value)
        when .type_sfixed64? then writer.write_sfixed64(value)
        else                      writer.write_int64(value)
        end
      when UInt32
        type.type_fixed32? ? writer.write_fixed32(value) : writer.write_uint32(value)
      when UInt64
        type.type_fixed64? ? writer.write_fixed64(value) : writer.write_uint64(value)
      end
    end

    private def current : Token
      @tokens[@index]? || Token.new(Token::Kind::EOF, "", @tokens.last?.try(&.line) || 0, @tokens.last?.try(&.column) || 0)
    end

    private def at_end? : Bool
      @index >= @tokens.size
    end

    private def advance : Token
      token = current
      @index += 1
      token
    end

    private def expect(symbol : String) : Token
      error(current, "Expected \"#{symbol}\", found #{current}.") unless current.symbol?(symbol)
      advance
    end

    private def expect_identifier : Token
      error(current, "Expected identifier, found #{current}.") unless current.kind.identifier?
      advance
    end

    private def error(token : Token, message : String) : NoReturn
      raise ParseError.new(@filename, token.line, token.column, "Error while parsing option value: #{message}")
    end
  end
end
