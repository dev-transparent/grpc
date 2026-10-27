require "../../protobuf"
require "./tokenizer"
require "./options"

module Protobuf::Compiler
  # Parses `.proto` source text (proto2, proto3 and editions) into a
  # `Google::Protobuf::FileDescriptorProto`, mirroring what protoc hands to
  # plugins.
  #
  # Type references are left as written (unresolved, with no `type` set for
  # message and enum fields); `Importer` resolves them once all imports are
  # loaded. Leading comments are recorded in `source_code_info` for the
  # declarations code generators document (messages, fields, oneofs, enums,
  # enum values, services and methods).
  class Parser
    alias D = Google::Protobuf
    alias FieldType = D::FieldDescriptorProto::Type
    alias Label = D::FieldDescriptorProto::Label
    alias FS = Google::Protobuf::FeatureSet

    SCALAR_TYPES = {
      "double" => FieldType::TYPE_DOUBLE, "float" => FieldType::TYPE_FLOAT,
      "int64" => FieldType::TYPE_INT64, "uint64" => FieldType::TYPE_UINT64,
      "int32" => FieldType::TYPE_INT32, "fixed64" => FieldType::TYPE_FIXED64,
      "fixed32" => FieldType::TYPE_FIXED32, "bool" => FieldType::TYPE_BOOL,
      "string" => FieldType::TYPE_STRING, "bytes" => FieldType::TYPE_BYTES,
      "uint32" => FieldType::TYPE_UINT32, "sfixed32" => FieldType::TYPE_SFIXED32,
      "sfixed64" => FieldType::TYPE_SFIXED64, "sint32" => FieldType::TYPE_SINT32,
      "sint64" => FieldType::TYPE_SINT64,
    }

    # Edition UNSTABLE uses fixed-width encodings for the plain integer
    # type names, and new names for the varint encodings.
    UNSTABLE_SCALAR_TYPES = {
      "double" => FieldType::TYPE_DOUBLE, "float" => FieldType::TYPE_FLOAT,
      "uint64" => FieldType::TYPE_FIXED64, "bool" => FieldType::TYPE_BOOL,
      "string" => FieldType::TYPE_STRING, "bytes" => FieldType::TYPE_BYTES,
      "uint32" => FieldType::TYPE_FIXED32, "int32" => FieldType::TYPE_SFIXED32,
      "int64" => FieldType::TYPE_SFIXED64, "varint32" => FieldType::TYPE_INT32,
      "varint64" => FieldType::TYPE_INT64, "uvarint32" => FieldType::TYPE_UINT32,
      "uvarint64" => FieldType::TYPE_UINT64, "zigzag32" => FieldType::TYPE_SINT32,
      "zigzag64" => FieldType::TYPE_SINT64,
    }

    # Type names replaced in edition UNSTABLE.
    UNSTABLE_REPLACED_TYPES = {
      "fixed32" => "uint32", "fixed64" => "uint64", "sfixed32" => "int32",
      "sfixed64" => "int64", "sint32" => "zigzag32", "sint64" => "zigzag64",
    }

    MAP_KEY_TYPES = Set{
      FieldType::TYPE_INT64, FieldType::TYPE_UINT64, FieldType::TYPE_INT32, FieldType::TYPE_FIXED64,
      FieldType::TYPE_FIXED32, FieldType::TYPE_BOOL, FieldType::TYPE_STRING, FieldType::TYPE_UINT32,
      FieldType::TYPE_SFIXED32, FieldType::TYPE_SFIXED64, FieldType::TYPE_SINT32, FieldType::TYPE_SINT64,
    }

    MAX_FIELD_NUMBER = 536_870_911

    enum Syntax
      Proto2
      Proto3
      Editions
    end

    getter filename : String
    getter syntax : Syntax = Syntax::Proto2

    @tokens : Array(Token)
    @index = 0
    @locations = [] of D::SourceCodeInfo::Location
    # Position of every declaration, used by `Importer` for errors.
    getter positions = {} of Array(Int32) => {Int32, Int32}
    # Position (and aggregate value tokens) of every option, keyed by the
    # `object_id` of its `UninterpretedOption`; used to interpret custom
    # options in `Importer`.
    getter option_sources = {} of UInt64 => OptionInterpreter::OptionSource

    def initialize(source : String, @filename : String)
      @tokens = Tokenizer.tokenize(source, @filename)
    end

    # Parses *source*, using *filename* as the file's name (its import path).
    def self.parse(source : String, filename : String) : D::FileDescriptorProto
      new(source, filename).parse
    end

    # The parsed file (available after `#parse`).
    getter! file : D::FileDescriptorProto

    def parse : D::FileDescriptorProto
      file = @file = D::FileDescriptorProto.new(name: @filename)

      if at_identifier?("syntax")
        parse_syntax(file)
      elsif at_identifier?("edition")
        parse_edition(file)
      end

      until current.kind.eof?
        parse_top_level(file)
      end

      file.source_code_info = D::SourceCodeInfo.new(location: @locations)
      # Standard options are interpreted right away; custom options
      # (extensions) need the imported files and are interpreted by
      # `Importer`.
      OptionInterpreter.interpret_file(file, BuiltinLookup.new, @filename, @option_sources, custom: false)
      fix_extension_ranges(file.message_type)
      file.message_type.each_with_index { |message, i| validate_ranges(message, [4, i]) }
      file.enum_type.each_with_index { |enum_type, i| validate_enum_ranges(enum_type, [5, i]) }
      file
    end

    # --- Top level ---

    private def parse_syntax(file : D::FileDescriptorProto) : Nil
      expect_identifier("syntax")
      expect_symbol("=")
      token = current
      value = expect_string
      expect_symbol(";")
      case value
      when "proto2"
        @syntax = Syntax::Proto2
      when "proto3"
        @syntax = Syntax::Proto3
        file.syntax = "proto3"
      else
        error(token, "Unrecognized syntax identifier \"#{value}\".  This parser only recognizes \"proto2\" and \"proto3\".")
      end
    end

    private def parse_edition(file : D::FileDescriptorProto) : Nil
      expect_identifier("edition")
      expect_symbol("=")
      token = current
      value = expect_string
      expect_symbol(";")
      edition = case value
                when "2023"     then D::Edition::EDITION_2023
                when "2024"     then D::Edition::EDITION_2024
                when "2026"     then D::Edition::EDITION_2026
                when "UNSTABLE" then D::Edition::EDITION_UNSTABLE
                else                 error(token, "Unknown edition \"#{value}\".")
                end
      @syntax = Syntax::Editions
      file.syntax = "editions"
      file.edition = edition
    end

    private def parse_top_level(file : D::FileDescriptorProto) : Nil
      token = current
      if try_symbol(";")
        return
      end
      error(token, "Expected top-level statement (e.g. \"message\").") unless token.kind.identifier?

      visibility = parse_visibility
      token = current
      if visibility && !(at_identifier?("message") || at_identifier?("enum"))
        error(token, "Expected \"message\" or \"enum\" after visibility modifier.")
      end

      case token.text
      when "message"
        index = file.message_type.size
        path = [4, index]
        message = parse_message(path, file.package)
        message.visibility = visibility if visibility
        file.message_type << message
      when "enum"
        index = file.enum_type.size
        enum_type = parse_enum([5, index])
        enum_type.visibility = visibility if visibility
        file.enum_type << enum_type
      when "service"
        index = file.service.size
        file.service << parse_service([6, index])
      when "extend"
        parse_extend(file.extension, file.message_type, [7], [4], file.package)
      when "import"
        parse_import(file)
      when "package"
        parse_package(file)
      when "option"
        options = file.options ||= D::FileOptions.new
        parse_option_statement(options)
      when "syntax", "edition"
        error(token, "#{token.text.capitalize} statements must be the first statement in the file.")
      else
        error(token, "Expected top-level statement (e.g. \"message\").")
      end
    end

    private def parse_import(file : D::FileDescriptorProto) : Nil
      start = current
      expect_identifier("import")
      kind = nil
      if at_identifier?("public") || at_identifier?("weak") || at_identifier?("option")
        kind = advance.text
      end
      if kind == "option"
        @positions[[15, file.option_dependency.size]] = {start.line, start.column}
      else
        @positions[[3, file.dependency.size]] = {start.line, start.column}
      end
      path = expect_string
      expect_symbol(";")
      case kind
      when "public" then file.public_dependency << file.dependency.size
      when "weak"   then file.weak_dependency << file.dependency.size
      end
      if kind == "option"
        file.option_dependency << path
      else
        file.dependency << path
      end
    end

    private def parse_package(file : D::FileDescriptorProto) : Nil
      token = expect_identifier("package")
      error(token, "Multiple package definitions.") if file.package
      name = parse_dotted_name
      expect_symbol(";")
      file.package = name
    end

    # --- Messages ---

    private def parse_message(path : Array(Int32), scope : String?) : D::DescriptorProto
      nested_message(current) { parse_message_definition(path, scope) }
    end

    private def parse_message_definition(path : Array(Int32), scope : String?) : D::DescriptorProto
      record_location(path, current)
      expect_identifier("message")
      name = expect_identifier
      message = D::DescriptorProto.new(name: name.text)
      full_name = scope.nil? || scope.empty? ? name.text : "#{scope}.#{name.text}"
      parse_message_block(message, path, full_name)
      message
    end

    # protoc's limit on nested message declarations
    # (`MaxMessageDeclarationNestingDepth`).
    MAX_MESSAGE_NESTING = 32

    @message_depth = 0

    # Tracks the nesting of message (and group) declarations, reporting
    # protoc's error at *token* when it is too deep.
    private def nested_message(token : Token, &)
      @message_depth += 1
      if @message_depth >= MAX_MESSAGE_NESTING
        error(token, "Reached maximum recursion limit for nested messages.")
      end
      yield
    ensure
      @message_depth -= 1
    end

    private def parse_message_block(message : D::DescriptorProto, path : Array(Int32), full_name : String) : Nil
      expect_symbol("{")
      until try_symbol("}")
        error(current, "Reached end of input in message definition (missing '}').") if current.kind.eof?
        parse_message_statement(message, path, full_name)
      end
      add_synthetic_oneofs(message)
      check_message(message, path)
    end

    private def parse_message_statement(message : D::DescriptorProto, path : Array(Int32), full_name : String) : Nil
      token = current
      return if try_symbol(";")

      if token.kind.identifier?
        if (token.text == "export" || token.text == "local") && peek_token(1).kind.identifier? &&
           peek_token(1).text.in?("message", "enum")
          visibility = parse_visibility
          if at_identifier?("message")
            nested = parse_message(path + [3, message.nested_type.size], full_name)
            nested.visibility = visibility
            message.nested_type << nested
          else
            enum_type = parse_enum(path + [4, message.enum_type.size])
            enum_type.visibility = visibility
            message.enum_type << enum_type
          end
          return
        end
        case token.text
        when "message"
          message.nested_type << parse_message(path + [3, message.nested_type.size], full_name)
          return
        when "enum"
          message.enum_type << parse_enum(path + [4, message.enum_type.size])
          return
        when "extensions"
          parse_extensions(message, path)
          return
        when "reserved"
          parse_reserved(message, path)
          return
        when "extend"
          parse_extend(message.extension, message.nested_type, path + [6], path + [3], full_name)
          return
        when "option"
          options = message.options ||= D::MessageOptions.new
          parse_option_statement(options)
          return
        when "oneof"
          parse_oneof(message, path, full_name)
          return
        end
      end

      field_path = path + [2, message.field.size]
      message.field << parse_field(field_path, message.nested_type, path + [3], full_name, nil)
    end

    # Parses a field (including map and group fields). Synthesized map entry
    # and group messages are appended to *nested_types*.
    private def parse_field(path : Array(Int32), nested_types : Array(D::DescriptorProto), nested_path : Array(Int32),
                            scope : String, oneof_index : Int32?, extendee : String? = nil) : D::FieldDescriptorProto
      start = current
      record_location(path, start)
      field = D::FieldDescriptorProto.new
      field.oneof_index = oneof_index if oneof_index
      field.extendee = extendee if extendee

      label = parse_label(oneof_index)
      field.label = label || Label::LABEL_OPTIONAL

      if at_identifier?("map") && peek_token(1).symbol?("<")
        parse_map_field(field, path, nested_types, nested_path, scope, label, start)
        return field
      end

      if at_identifier?("group") && peek_token(1).kind.identifier?
        parse_group_field(field, path, nested_types, nested_path, scope, label, start)
        return field
      end

      if label.nil? && oneof_index.nil? && @syntax.proto2? && extendee.nil?
        error(start, "Expected \"required\", \"optional\", or \"repeated\".")
      end

      type_token = current
      type_name = parse_type_name
      if scalar = scalar_type(type_name, type_token)
        field.type = scalar
      else
        field.type_name = type_name
      end

      name = expect_identifier
      field.name = name.text
      expect_symbol("=")
      field.number = parse_field_number
      parse_field_options(field) if current.symbol?("[")
      expect_symbol(";")
      check_field(field, start, type_token)
      field
    end

    private def parse_label(oneof_index : Int32?) : Label?
      token = current
      return nil unless token.kind.identifier?
      label = case token.text
              when "optional" then Label::LABEL_OPTIONAL
              when "required" then Label::LABEL_REQUIRED
              when "repeated" then Label::LABEL_REPEATED
              else                 return nil
              end
      advance
      error(token, "Fields in oneofs must not have labels (required / optional / repeated).") if oneof_index
      if @syntax.proto3? && label.label_required?
        error(token, "Required fields are not allowed in proto3.")
      end
      if @syntax.editions? && !label.label_repeated?
        error(token, "Label \"#{token.text}\" is not supported in editions. Use features.field_presence instead.")
      end
      label
    end

    private def parse_map_field(field : D::FieldDescriptorProto, path, nested_types, nested_path, scope : String,
                                label : Label?, start : Token) : Nil
      error(start, "Map fields are not allowed to have labels.") if label
      error(start, "Map fields are not allowed in oneofs.") if field.oneof_index
      expect_identifier("map")
      expect_symbol("<")
      key_token = current
      key_type = parse_type_name
      expect_symbol(",")
      value_token = current
      value_type = parse_type_name
      expect_symbol(">")
      name = expect_identifier
      expect_symbol("=")
      number = parse_field_number

      key_scalar = scalar_type(key_type, key_token)
      unless key_scalar && MAP_KEY_TYPES.includes?(key_scalar)
        error(key_token, "Key in map fields cannot be float/double, bytes or message types.")
      end

      entry_name = Parser.map_entry_name(name.text)
      entry = D::DescriptorProto.new(name: entry_name, options: D::MessageOptions.new(map_entry: true))
      key = D::FieldDescriptorProto.new(name: "key", number: 1, label: Label::LABEL_OPTIONAL, type: key_scalar)
      value = D::FieldDescriptorProto.new(name: "value", number: 2, label: Label::LABEL_OPTIONAL)
      if scalar = scalar_type(value_type, value_token)
        value.type = scalar
      else
        value.type_name = value_type
      end
      key.json_name = "key"
      value.json_name = "value"
      entry.field << key
      entry.field << value
      nested_types << entry

      field.name = name.text
      field.number = number
      field.label = Label::LABEL_REPEATED
      field.type = FieldType::TYPE_MESSAGE
      field.type_name = entry_name
      parse_field_options(field) if current.symbol?("[")
      expect_symbol(";")
      check_field(field, start, value_token)
    end

    private def parse_group_field(field : D::FieldDescriptorProto, path, nested_types, nested_path, scope : String,
                                  label : Label?, start : Token) : Nil
      unless @syntax.proto2?
        error(start, "Group syntax is no longer supported in #{@syntax.proto3? ? "proto3" : "editions"}.")
      end
      if label.nil? && field.oneof_index.nil?
        error(start, "Expected \"required\", \"optional\", or \"repeated\".")
      end
      expect_identifier("group")
      name = expect_identifier
      unless name.text[0].ascii_uppercase?
        error(name, "Group names must start with a capital letter.")
      end
      expect_symbol("=")
      number = parse_field_number

      field.name = name.text.downcase
      field.number = number
      field.type = FieldType::TYPE_GROUP
      field.type_name = name.text
      parse_field_options(field) if current.symbol?("[")
      field.json_name ||= Parser.json_name(field.name || "")

      group_path = nested_path + [nested_types.size]
      # protoc attaches the group statement's comments to the group's
      # message type, not to the field.
      @locations.reverse_each do |location|
        if location.path == path
          location.leading_comments = nil
          break
        end
      end
      record_location(group_path, start)
      group = D::DescriptorProto.new(name: name.text)
      nested_types << group
      nested_message(start) { parse_message_block(group, group_path, "#{scope}.#{name.text}") }
    end

    private def parse_oneof(message : D::DescriptorProto, path : Array(Int32), full_name : String) : Nil
      index = message.oneof_decl.size
      oneof_path = path + [8, index]
      record_location(oneof_path, current)
      expect_identifier("oneof")
      name = expect_identifier
      oneof = D::OneofDescriptorProto.new(name: name.text)
      message.oneof_decl << oneof
      expect_symbol("{")
      count = 0
      until try_symbol("}")
        error(current, "Reached end of input in oneof definition (missing '}').") if current.kind.eof?
        next if try_symbol(";")
        if at_identifier?("option")
          options = oneof.options ||= D::OneofOptions.new
          parse_option_statement(options)
          next
        end
        field_path = path + [2, message.field.size]
        message.field << parse_field(field_path, message.nested_type, path + [3], full_name, index)
        count += 1
      end
      error(name, "Oneof must have at least one field.") if count == 0
    end

    # proto3 `optional` fields get a synthetic oneof named `_<field>`,
    # appended after the real oneofs (as protoc does).
    private def add_synthetic_oneofs(message : D::DescriptorProto) : Nil
      names = Set(String).new
      message.field.each { |field| names << (field.name || "") }
      message.oneof_decl.each { |oneof| names << (oneof.name || "") }
      message.field.each do |field|
        next unless field.proto3_optional
        name = field.name || ""
        name = "_#{name}" unless name.starts_with?('_')
        while names.includes?(name)
          name = "X#{name}"
        end
        names << name
        field.oneof_index = message.oneof_decl.size
        message.oneof_decl << D::OneofDescriptorProto.new(name: name)
      end
    end

    private def parse_extend(extensions : Array(D::FieldDescriptorProto), nested_types : Array(D::DescriptorProto),
                             path : Array(Int32), nested_path : Array(Int32), scope : String?) : Nil
      expect_identifier("extend")
      extendee = parse_type_name
      expect_symbol("{")
      until try_symbol("}")
        error(current, "Reached end of input in extend definition (missing '}').") if current.kind.eof?
        next if try_symbol(";")
        field_path = path + [extensions.size]
        extensions << parse_field(field_path, nested_types, nested_path, scope || "", nil, extendee)
      end
    end

    # --- Enums ---

    private def parse_enum(path : Array(Int32)) : D::EnumDescriptorProto
      record_location(path, current)
      expect_identifier("enum")
      name = expect_identifier
      enum_type = D::EnumDescriptorProto.new(name: name.text)
      expect_symbol("{")
      until try_symbol("}")
        error(current, "Reached end of input in enum definition (missing '}').") if current.kind.eof?
        next if try_symbol(";")
        if at_identifier?("option")
          options = enum_type.options ||= D::EnumOptions.new
          parse_option_statement(options)
          next
        end
        if at_identifier?("reserved")
          parse_enum_reserved(enum_type, path)
          next
        end
        value_path = path + [2, enum_type.value.size]
        record_location(value_path, current)
        value_name = expect_identifier
        expect_symbol("=")
        negative = try_symbol("-")
        number_token = current
        number = parse_integer_value
        number = -number if negative
        unless Int32::MIN <= number <= Int32::MAX
          error(number_token, "Integer out of range.")
        end
        value = D::EnumValueDescriptorProto.new(name: value_name.text, number: number.to_i32)
        if current.symbol?("[")
          options = value.options ||= D::EnumValueOptions.new
          parse_bracketed_options(options)
        end
        expect_symbol(";")
        enum_type.value << value
      end
      error(name, "Enums must contain at least one value.") if enum_type.value.empty?
      if @syntax.proto3? && enum_type.value.first.number != 0
        error(name, "The first enum value must be zero for open enums.")
      end
      enum_type
    end

    private def parse_enum_reserved(enum_type : D::EnumDescriptorProto, path : Array(Int32)) : Nil
      expect_identifier("reserved")
      if current.kind.string?
        error(current, "Reserved names must be identifiers in editions, not string literals.") if @syntax.editions?
        loop do
          enum_type.reserved_name << expect_string
          break unless try_symbol(",")
        end
      elsif current.kind.identifier? && !at_identifier?("max")
        error(current, "Reserved names must be string literals. (Only editions supports identifiers.)") unless @syntax.editions?
        loop do
          enum_type.reserved_name << expect_identifier.text
          break unless try_symbol(",")
        end
      else
        loop do
          @positions[path + [4, enum_type.reserved_range.size]] = {current.line, current.column}
          first = parse_enum_number
          last = first
          if at_identifier?("to")
            advance
            if at_identifier?("max")
              advance
              last = Int32::MAX
            else
              last = parse_enum_number
            end
          end
          enum_type.reserved_range << D::EnumDescriptorProto::EnumReservedRange.new(start: first, end_: last)
          break unless try_symbol(",")
        end
      end
      expect_symbol(";")
    end

    private def parse_enum_number : Int32
      negative = try_symbol("-")
      token = current
      value = parse_integer_value
      value = -value if negative
      error(token, "Integer out of range.") unless Int32::MIN <= value <= Int32::MAX
      value.to_i32
    end

    # --- Services ---

    private def parse_service(path : Array(Int32)) : D::ServiceDescriptorProto
      record_location(path, current)
      expect_identifier("service")
      name = expect_identifier
      service = D::ServiceDescriptorProto.new(name: name.text)
      expect_symbol("{")
      until try_symbol("}")
        error(current, "Reached end of input in service definition (missing '}').") if current.kind.eof?
        next if try_symbol(";")
        if at_identifier?("option")
          parse_option_statement(service.options ||= D::ServiceOptions.new)
          next
        end
        method_path = path + [2, service.method.size]
        record_location(method_path, current)
        expect_identifier("rpc")
        method_name = expect_identifier
        method = D::MethodDescriptorProto.new(name: method_name.text)
        expect_symbol("(")
        if at_identifier?("stream") && !peek_token(1).symbol?(")")
          advance
          method.client_streaming = true
        end
        method.input_type = parse_type_name
        expect_symbol(")")
        expect_identifier("returns")
        expect_symbol("(")
        if at_identifier?("stream") && !peek_token(1).symbol?(")")
          advance
          method.server_streaming = true
        end
        method.output_type = parse_type_name
        expect_symbol(")")
        if try_symbol("{")
          # protoc gives methods with an option block (even an empty one)
          # an options message.
          method.options ||= D::MethodOptions.new
          until try_symbol("}")
            error(current, "Reached end of input in method options (missing '}').") if current.kind.eof?
            next if try_symbol(";")
            if at_identifier?("option")
              parse_option_statement(method.options ||= D::MethodOptions.new)
            else
              error(current, "Expected \"option\" or \"}\".")
            end
          end
          try_symbol(";")
        else
          expect_symbol(";")
        end
        service.method << method
      end
      service
    end

    # --- Options ---

    # Parses `option name = value;` into an uninterpreted option of
    # *options* (interpreted at the end of parsing, or by `Importer` for
    # custom options).
    private def parse_option_statement(options) : Nil
      expect_identifier("option")
      parse_option_assignment(options)
      expect_symbol(";")
    end

    # Parses `[name = value, ...]` into uninterpreted options of *options*.
    private def parse_bracketed_options(options) : Nil
      expect_symbol("[")
      loop do
        parse_option_assignment(options)
        break unless try_symbol(",")
      end
      expect_symbol("]")
    end

    private def parse_option_assignment(options) : D::UninterpretedOption
      start = current
      option = D::UninterpretedOption.new(name: parse_option_name)
      check_option_name(options, option, start)
      expect_symbol("=")
      aggregate = parse_option_value(option)
      @option_sources[option.object_id] = OptionInterpreter::OptionSource.new(start.line, start.column, aggregate)
      options.uninterpreted_option << option
      option
    end

    private def check_option_name(options, option : D::UninterpretedOption, token : Token) : Nil
      first = option.name.first
      return if first.is_extension == true
      case first.name_part
      when "map_entry"
        if options.is_a?(D::MessageOptions)
          error(token, "map_entry should not be set explicitly. Use map<KeyType, ValueType> instead.")
        end
      when "packed"
        if options.is_a?(D::FieldOptions) && @syntax.editions?
          error(token, "Field option 'packed' is not allowed in editions.")
        end
      when "features"
        error(token, "Features are only valid under editions.") unless @syntax.editions?
      end
    end

    private def parse_option_name : Array(D::UninterpretedOption::NamePart)
      parts = [] of D::UninterpretedOption::NamePart
      loop do
        if try_symbol("(")
          name = String.build do |io|
            io << '.' if try_symbol(".")
            io << parse_dotted_name
          end
          expect_symbol(")")
          parts << D::UninterpretedOption::NamePart.new(name_part: name, is_extension: true)
        else
          parts << D::UninterpretedOption::NamePart.new(name_part: expect_identifier.text, is_extension: false)
        end
        break unless try_symbol(".")
      end
      parts
    end

    # Parses an option value into *option* (like protoc's parser). Returns
    # the tokens of an aggregate value (without the braces).
    private def parse_option_value(option : D::UninterpretedOption) : Array(Token)?
      token = current
      if token.symbol?("{")
        tokens = parse_aggregate_tokens
        option.aggregate_value = tokens.map(&.text).join(" ")
        return tokens
      end
      negative = false
      if token.symbol?("-")
        advance
        negative = true
      elsif token.symbol?("+")
        error(token, "Expected option value.")
      end
      token = current
      case token.kind
      when .identifier?
        advance
        if negative
          case token.text
          when "inf" then option.double_value = -Float64::INFINITY
          when "nan" then option.double_value = Float64::NAN
          else            error(token, "Identifier after '-' symbol must be inf or nan.")
          end
        else
          option.identifier_value = token.text
        end
      when .integer?
        advance
        value = parse_integer_text(token)
        if negative
          error(token, "Integer out of range.") if value > Int64::MAX.to_u64 + 1
          option.negative_int_value = value == Int64::MAX.to_u64 + 1 ? Int64::MIN : -value.to_i64
        else
          option.positive_int_value = value
        end
      when .float?
        advance
        value = token.text.to_f64? || error(token, "Invalid float literal.")
        option.double_value = negative ? -value : value
      when .string?
        error(token, "Invalid '-' symbol before string.") if negative
        io = IO::Memory.new
        while current.kind.string?
          io.write(advance.string_value.not_nil!.to_slice)
        end
        option.string_value = io.to_slice
      else
        error(token, "Expected option value.")
      end
      nil
    end

    # Returns the tokens between the braces of an aggregate value.
    private def parse_aggregate_tokens : Array(Token)
      expect_symbol("{")
      tokens = [] of Token
      depth = 1
      loop do
        token = advance
        error(token, "Unexpected end of input in aggregate value.") if token.kind.eof?
        depth += 1 if token.symbol?("{")
        depth -= 1 if token.symbol?("}")
        break if depth == 0
        tokens << token
      end
      tokens
    end

    # The value of a default or option as written (strings decoded,
    # numbers with their sign).
    private def parse_default_value : String
      token = current
      if token.symbol?("-")
        advance
        number = current
        unless number.kind.integer? || number.kind.float? || at_identifier?("inf") || at_identifier?("nan")
          error(number, "Expected number.")
        end
        advance
        return "-" + number.text
      end
      case token.kind
      when .string?
        String.build do |io|
          while current.kind.string?
            io << advance.string_value
          end
        end
      when .identifier?, .integer?, .float?
        advance.text
      else
        error(token, "Expected default value.")
      end
    end

    private def parse_field_options(field : D::FieldDescriptorProto) : Nil
      expect_symbol("[")
      loop do
        token = current
        if at_identifier?("default") && peek_token(1).symbol?("=")
          advance
          expect_symbol("=")
          error(token, "Explicit default values are not allowed in proto3.") if @syntax.proto3?
          error(token, "Already set option \"default\".") if field.default_value
          value_token = current
          field.default_value = parse_default_value
          @default_tokens[field.object_id] = value_token
        elsif at_identifier?("json_name") && peek_token(1).symbol?("=")
          advance
          expect_symbol("=")
          error(token, "Already set option \"json_name\".") if field.json_name
          error(current, "Expected string for JSON name.") unless current.kind.string?
          field.json_name = parse_default_value
        else
          options = field.options ||= D::FieldOptions.new
          parse_option_assignment(options)
        end
        break unless try_symbol(",")
      end
      expect_symbol("]")
    end

    # Tokens of default values, for errors reported by `Importer`.
    getter default_tokens = {} of UInt64 => Token

    # --- Ranges ---

    # protoc's sentinel for `max` in extension ranges, replaced once the
    # message options are known.
    MAX_RANGE_SENTINEL = -1

    private def parse_extensions(message : D::DescriptorProto, path : Array(Int32)) : Nil
      start = expect_identifier("extensions")
      ranges = [] of D::DescriptorProto::ExtensionRange
      loop do
        @positions[path + [5, message.extension_range.size + ranges.size]] = {current.line, current.column}
        first = parse_range_number
        last = exclusive_end(first)
        if at_identifier?("to")
          advance
          if at_identifier?("max")
            advance
            last = MAX_RANGE_SENTINEL
          else
            last = exclusive_end(parse_range_number)
          end
        end
        ranges << D::DescriptorProto::ExtensionRange.new(start: first, end_: last)
        break unless try_symbol(",")
      end
      if current.symbol?("[")
        options = D::ExtensionRangeOptions.new
        parse_bracketed_options(options)
        ranges.each_with_index do |range, i|
          if i == 0
            range.options = options
          else
            # Each range gets its own copy of the options.
            copy = D::ExtensionRangeOptions.new
            options.uninterpreted_option.each do |option|
              cloned = option.clone
              @option_sources[cloned.object_id] = @option_sources[option.object_id]
              copy.uninterpreted_option << cloned
            end
            range.options = copy
          end
        end
      end
      expect_symbol(";")
      message.extension_range.concat(ranges)
    end

    private def parse_range_number : Int32
      token = current
      value = parse_integer_value
      error(token, "Integer out of range.") if value > Int32::MAX
      value.to_i32
    end

    # The exclusive end of a range ending at *last*.
    private def exclusive_end(last : Int32) : Int32
      error(current, "Field number out of bounds.") if last == Int32::MAX
      last + 1
    end

    private def parse_reserved(message : D::DescriptorProto, path : Array(Int32)) : Nil
      expect_identifier("reserved")
      if current.kind.string?
        error(current, "Reserved names must be identifiers in editions, not string literals.") if @syntax.editions?
        loop do
          message.reserved_name << expect_string
          break unless try_symbol(",")
        end
      elsif current.kind.identifier? && !at_identifier?("max")
        error(current, "Reserved names must be string literals. (Only editions supports identifiers.)") unless @syntax.editions?
        loop do
          message.reserved_name << expect_identifier.text
          break unless try_symbol(",")
        end
      else
        loop do
          @positions[path + [9, message.reserved_range.size]] = {current.line, current.column}
          first = parse_range_number
          last = exclusive_end(first)
          if at_identifier?("to")
            advance
            if at_identifier?("max")
              advance
              last = MAX_FIELD_NUMBER + 1
            else
              last = exclusive_end(parse_range_number)
            end
          end
          message.reserved_range << D::DescriptorProto::ReservedRange.new(start: first, end_: last)
          break unless try_symbol(",")
        end
      end
      expect_symbol(";")
    end

    # --- Validation ---

    # Checks reserved and extension ranges like protoc's DescriptorBuilder.
    private def validate_ranges(message : D::DescriptorProto, path : Array(Int32)) : Nil
      max = message.options.try(&.message_set_wire_format) ? Int32::MAX : MAX_FIELD_NUMBER + 1
      reserved = message.reserved_range.map { |r| {r.start || 0, r.end_ || 0} }
      extensions = message.extension_range.map { |r| {r.start || 0, r.end_ || 0} }
      reserved.each_with_index do |(first, last), i|
        at = @positions[path + [9, i]]?
        error_at(at, "Reserved numbers must be positive integers.") if first <= 0 || last > MAX_FIELD_NUMBER + 1
        error_at(at, "Reserved range end number must be greater than start number.") if last <= first
        reserved[0...i].each do |(a, b)|
          if first < b && a < last
            error_at(at, "Reserved range #{first} to #{last - 1} overlaps with already-defined range #{a} to #{b - 1}.")
          end
        end
      end
      extensions.each_with_index do |(first, last), i|
        at = @positions[path + [5, i]]?
        error_at(at, "Extension numbers must be positive integers.") if first <= 0
        error_at(at, "Extension numbers cannot be greater than #{max - 1}.") if last > max
        error_at(at, "Extension range end number must be greater than start number.") if last <= first
        extensions[0...i].each do |(a, b)|
          if first < b && a < last
            error_at(at, "Extension range #{first} to #{last - 1} overlaps with already-defined range #{a} to #{b - 1}.")
          end
        end
        reserved.each do |(a, b)|
          if first < b && a < last
            error_at(at, "Extension range #{first} to #{last - 1} overlaps with reserved range #{a} to #{b - 1}.")
          end
        end
      end
      message.field.each_with_index do |field, i|
        number = field.number || 0
        at = @positions[path + [2, i]]?
        if reserved.any? { |(a, b)| a <= number < b }
          error_at(at, "Field \"#{field.name}\" uses reserved number #{number}.")
        end
        if range = extensions.find { |(a, b)| a <= number < b }
          error_at(at, "Extension range #{range[0]} to #{range[1] - 1} includes field \"#{field.name}\" (#{number}).")
        end
        if message.reserved_name.includes?(field.name)
          error_at(at, "Field name \"#{field.name}\" is reserved.")
        end
      end
      message.nested_type.each_with_index { |nested, i| validate_ranges(nested, path + [3, i]) }
      message.enum_type.each_with_index { |enum_type, i| validate_enum_ranges(enum_type, path + [4, i]) }
    end

    private def validate_enum_ranges(enum_type : D::EnumDescriptorProto, path : Array(Int32)) : Nil
      enum_type.reserved_range.each_with_index do |range, i|
        if (range.end_ || 0) < (range.start || 0)
          error_at(@positions[path + [4, i]]?, "Reserved range end number must be greater than start number.")
        end
      end
      enum_type.value.each_with_index do |value, i|
        number = value.number || 0
        at = @positions[path + [2, i]]?
        if enum_type.reserved_range.any? { |r| (r.start || 0) <= number <= (r.end_ || 0) }
          error_at(at, "Enum value \"#{value.name}\" uses reserved number #{number}.")
        end
        if enum_type.reserved_name.includes?(value.name)
          error_at(at, "Enum value \"#{value.name}\" is reserved.")
        end
      end
    end

    private def check_field(field : D::FieldDescriptorProto, start : Token, type_token : Token) : Nil
      if field.label == Label::LABEL_OPTIONAL && @syntax.proto3? && start.text == "optional" && field.oneof_index.nil?
        field.proto3_optional = true
      end
      field.json_name ||= Parser.json_name(field.name || "")
    end

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

    private def check_message(message : D::DescriptorProto, path : Array(Int32)) : Nil
      seen_numbers = {} of Int32 => String
      seen_names = Set(String).new
      message.field.each_with_index do |field, i|
        position = @positions[path + [2, i]]?
        name = field.name || ""
        number = field.number || 0
        if previous = seen_numbers[number]?
          error_at(position, "Field number #{number} has already been used in \"#{message.name}\" by field \"#{previous}\".")
        end
        if seen_names.includes?(name)
          error_at(position, "\"#{name}\" is already defined in \"#{message.name}\".")
        end
        seen_numbers[number] = name
        seen_names << name
      end
    end

    # --- Token helpers ---

    private def parse_field_number : Int32
      token = current
      value = parse_integer_value
      unless 1 <= value <= MAX_FIELD_NUMBER
        error(token, "Field numbers must be positive integers between 1 and #{MAX_FIELD_NUMBER}.")
      end
      if 19_000 <= value <= 19_999
        error(token, "Field numbers 19000 through 19999 are reserved for the protocol buffer library implementation.")
      end
      value.to_i32
    end

    private def parse_integer_value : Int64
      token = current
      error(token, "Expected integer.") unless token.kind.integer?
      advance
      value = parse_integer_text(token)
      error(token, "Integer out of range.") if value > Int64::MAX.to_u64
      value.to_i64
    end

    # Parses the text of an integer token (decimal, hex or octal).
    private def parse_integer_text(token : Token) : UInt64
      text = token.text
      value = if text.starts_with?("0x") || text.starts_with?("0X")
                text[2..].to_u64?(16)
              elsif text.size > 1 && text.starts_with?('0')
                text.to_u64?(8)
              else
                text.to_u64?
              end
      value || error(token, "Integer out of range.")
    end

    # Parses an optional `export` / `local` visibility modifier (editions
    # 2024 and later).
    private def parse_visibility : D::SymbolVisibility?
      return nil unless (at_identifier?("export") || at_identifier?("local")) && peek_token(1).kind.identifier? &&
                        peek_token(1).text.in?("message", "enum")
      token = advance
      if @syntax.editions? && edition_at_least_2024?
        token.text == "export" ? D::SymbolVisibility::VISIBILITY_EXPORT : D::SymbolVisibility::VISIBILITY_LOCAL
      else
        error(token, "#{token.text} visibility modifiers are only supported in edition 2024 and later.")
      end
    end

    private def edition_at_least_2024? : Bool
      (@file.try(&.edition).try(&.value) || 0) >= D::Edition::EDITION_2024.value
    end

    # Replaces `extensions ... to max` sentinels once message options are
    # known (MessageSets may use the whole int32 range).
    private def fix_extension_ranges(messages : Array(D::DescriptorProto)) : Nil
      messages.each do |message|
        max = message.options.try(&.message_set_wire_format) ? Int32::MAX : MAX_FIELD_NUMBER + 1
        message.extension_range.each do |range|
          range.end_ = max if range.end_ == MAX_RANGE_SENTINEL
        end
        fix_extension_ranges(message.nested_type)
      end
    end

    # A (possibly dotted, possibly fully qualified) type name or scalar.
    private def parse_type_name : String
      String.build do |io|
        io << '.' if try_symbol(".")
        io << expect_identifier.text
        while current.symbol?(".")
          advance
          io << '.' << expect_identifier.text
        end
      end
    end

    private def parse_dotted_name : String
      String.build do |io|
        io << expect_identifier.text
        while try_symbol(".")
          io << '.' << expect_identifier.text
        end
      end
    end

    private def record_location(path : Array(Int32), token : Token) : Nil
      @positions[path] = {token.line, token.column}
      location = D::SourceCodeInfo::Location.new(path: path, span: [token.line - 1, token.column - 1])
      location.leading_comments = token.leading_comment
      @locations << location
    end

    private def current : Token
      @tokens[@index]
    end

    private def peek_token(offset : Int32) : Token
      @tokens[Math.min(@index + offset, @tokens.size - 1)]
    end

    private def advance : Token
      token = current
      @index += 1 unless token.kind.eof?
      token
    end

    private def at_identifier?(text : String) : Bool
      current.kind.identifier? && current.text == text
    end

    private def try_symbol(symbol : String) : Bool
      if current.symbol?(symbol)
        advance
        true
      else
        false
      end
    end

    private def expect_symbol(symbol : String) : Token
      token = current
      error(token, "Expected \"#{symbol}\", found #{token}.") unless token.symbol?(symbol)
      advance
    end

    private def expect_identifier(text : String? = nil) : Token
      token = current
      if text
        error(token, "Expected \"#{text}\", found #{token}.") unless token.kind.identifier? && token.text == text
      else
        error(token, "Expected identifier, found #{token}.") unless token.kind.identifier?
      end
      advance
    end

    private def expect_string : String
      token = current
      error(token, "Expected string, found #{token}.") unless token.kind.string?
      String.build do |io|
        while current.kind.string?
          io << advance.string_value
        end
      end
    end

    private def error(token : Token, message : String) : NoReturn
      raise ParseError.new(@filename, token.line, token.column, message)
    end

    private def error_at(position : {Int32, Int32}?, message : String) : NoReturn
      line, column = position || {0, 0}
      raise ParseError.new(@filename, line, column, message)
    end

    # The scalar type named *name*, or `nil` for message and enum types.
    private def scalar_type(name : String, token : Token) : FieldType?
      if @syntax.editions? && @file.try(&.edition) == D::Edition::EDITION_UNSTABLE
        if replacement = UNSTABLE_REPLACED_TYPES[name]?
          error(token, "Type '#{name}' is obsolete in unstable editions, use '#{replacement}' instead.")
        end
        UNSTABLE_SCALAR_TYPES[name]?
      else
        SCALAR_TYPES[name]?
      end
    end

    # The name of the synthesized map entry message for a map field (protoc's
    # `MapEntryName`): the field name in CamelCase followed by `Entry`.
    def self.map_entry_name(field_name : String) : String
      String.build do |io|
        capitalize_next = true
        field_name.each_char do |char|
          if char == '_'
            capitalize_next = true
          elsif capitalize_next
            io << char.upcase
            capitalize_next = false
          else
            io << char
          end
        end
        io << "Entry"
      end
    end
  end
end
