require "./parser"
require "./options"

module Protobuf::Compiler
  # Loads `.proto` files and their imports from include paths, parses them
  # with `Parser` and resolves type references, producing the same
  # descriptors protoc would send to a plugin.
  #
  # The well-known types (`google/protobuf/*.proto`) are bundled with the
  # shard and always importable.
  #
  # ```
  # importer = Protobuf::Compiler::Importer.new(["proto"])
  # request = importer.code_generator_request(["helloworld.proto"])
  # Protobuf::Compiler::Generator.new(request).generate_inline
  # ```
  class Importer
    alias D = Google::Protobuf
    alias FieldType = D::FieldDescriptorProto::Type

    # Directory containing the bundled well-known type sources.
    BUNDLED_INCLUDE_PATH = File.expand_path("../proto", __DIR__)

    enum SymbolKind
      Package
      Message
      Enum
      Extension
    end

    record Entry, kind : SymbolKind, file : String,
      descriptor : D::DescriptorProto | D::EnumDescriptorProto | D::FieldDescriptorProto | Nil = nil

    getter include_paths : Array(String)

    @files = {} of String => D::FileDescriptorProto
    @order = [] of String
    @loading = [] of String
    @positions = {} of String => Hash(Array(Int32), {Int32, Int32})
    @option_sources = {} of String => Hash(UInt64, OptionInterpreter::OptionSource)
    @default_tokens = {} of String => Hash(UInt64, Token)
    @symbols = {} of String => Entry

    # In-memory sources by import name, searched before the include paths.
    getter sources : Hash(String, String)

    # Creates an importer searching *include_paths* (and the bundled
    # well-known types unless *bundled* is false). *sources* maps import
    # names to in-memory `.proto` sources, which take precedence over files.
    def initialize(include_paths : Enumerable(String) = [] of String, bundled : Bool = true,
                   @sources : Hash(String, String) = {} of String => String)
      @include_paths = include_paths.map { |path| File.expand_path(path) }
      @include_paths << BUNDLED_INCLUDE_PATH if bundled
    end

    # Loads *name* (a path relative to an include path) and its imports.
    # Returns the parsed descriptor; types are resolved by `#link`.
    def load(name : String, from : {String, Array(Int32)}? = nil) : D::FileDescriptorProto
      import_error(from, "Import #{name.inspect} is not a valid path.") if name.includes?('\0') || name.empty?
      name = normalize(name)
      if file = @files[name]?
        return file
      end
      if @loading.includes?(name)
        cycle = (@loading[@loading.index(name).not_nil!..] + [name]).join(" -> ")
        import_error(from, "File recursively imports itself: #{cycle}")
      end

      path = find(name) || import_error(from, missing_message(name))
      source = @sources[name]? || File.read(path)
      @loading << name
      parser = begin
        Parser.new(source, name).tap(&.parse)
      rescue e : ParseError
        raise ParseError.new(path, e.line, e.column, e.description)
      end
      file = parser.file
      @positions[name] = parser.positions
      @option_sources[name] = parser.option_sources
      @default_tokens[name] = parser.default_tokens
      file.dependency.each_with_index do |dependency, index|
        load(dependency, {name, [3, index]})
      end
      file.option_dependency.each_with_index do |dependency, index|
        load(dependency, {name, [15, index]})
      end
      @loading.pop
      @files[name] = file
      @order << name
      file
    end

    # Returns the absolute path of the file named *name*, or `nil`.
    def find(name : String) : String?
      return name if @sources.has_key?(name)
      @include_paths.each do |include_path|
        path = File.join(include_path, name)
        return path if File.file?(path)
      end
      nil
    end

    # Converts a file system path to the name used for imports: its path
    # relative to the first include path that contains it.
    def name_for(path : String) : String?
      absolute = File.expand_path(path)
      @include_paths.each do |include_path|
        prefix = include_path.ends_with?('/') ? include_path : "#{include_path}/"
        return absolute.lchop(prefix) if absolute.starts_with?(prefix)
      end
      nil
    end

    # All loaded files, dependencies before the files importing them.
    def files : Array(D::FileDescriptorProto)
      @order.map { |name| @files[name] }
    end

    # Loads *names*, resolves all type references and returns a request for
    # the generator.
    def code_generator_request(names : Array(String), parameter : String? = nil) : D::Compiler::CodeGeneratorRequest
      names = names.map { |name| normalize(name) }
      names.each { |name| load(name) }
      link
      D::Compiler::CodeGeneratorRequest.new(file_to_generate: names, parameter: parameter, proto_file: files)
    end

    # Resolves type references in all loaded files.
    def link : Nil
      build_symbol_table
      @order.each { |name| link_file(@files[name]) }
      @order.each do |name|
        lookup = ImporterLookup.new(self, @files[name])
        OptionInterpreter.interpret_file(@files[name], lookup, display_path(name), @option_sources[name]? || {} of UInt64 => OptionInterpreter::OptionSource, custom: true)
      end
    end

    # Resolves types for option interpretation: the loaded files, then the
    # descriptors compiled into the program.
    # :nodoc:
    class ImporterLookup < TypeLookup
      @builtin = BuiltinLookup.new

      def initialize(@importer : Importer, @file : D::FileDescriptorProto)
      end

      def message(name : String) : {D::DescriptorProto, D::FileDescriptorProto}?
        if entry = @importer.symbol_entry(name)
          if (descriptor = entry.descriptor).is_a?(D::DescriptorProto)
            return {descriptor, @importer.loaded_file(entry.file)}
          end
          return nil
        end
        @builtin.message(name)
      end

      def enum(name : String) : D::EnumDescriptorProto?
        if entry = @importer.symbol_entry(name)
          return entry.descriptor.as?(D::EnumDescriptorProto)
        end
        @builtin.enum(name)
      end

      def extension(name : String, scope : String) : {String, D::FieldDescriptorProto, D::FileDescriptorProto}?
        full_name, entry = @importer.resolve_option_name(@file, name, scope) || return nil
        field = entry.descriptor.as?(D::FieldDescriptorProto) || return nil
        {full_name, field, @importer.loaded_file(entry.file)}
      end

      def extension_by_number(extendee : String, number : Int32) : {D::FieldDescriptorProto, D::FileDescriptorProto}?
        @importer.extension_by_number(extendee, number)
      end
    end

    @extensions_by_number : Hash({String, Int32}, Entry)? = nil

    # The extension of *extendee* with field number *number*.
    # :nodoc:
    def extension_by_number(extendee : String, number : Int32) : {D::FieldDescriptorProto, D::FileDescriptorProto}?
      index = @extensions_by_number ||= begin
        map = {} of {String, Int32} => Entry
        @symbols.each_value do |entry|
          if entry.kind.extension? && (field = entry.descriptor.as?(D::FieldDescriptorProto))
            map[{(field.extendee || "").lchop('.'), field.number || 0}] = entry
          end
        end
        map
      end
      entry = index[{extendee.lchop('.'), number}]? || return nil
      {entry.descriptor.as(D::FieldDescriptorProto), @files[entry.file]}
    end

    # :nodoc:
    def symbol_entry(name : String) : Entry?
      @symbols[name.lchop('.')]?
    end

    # :nodoc:
    def loaded_file(name : String) : D::FileDescriptorProto
      @files[name]
    end

    # Resolves an extension name used in an option of *file*, or `nil`.
    # :nodoc:
    def resolve_option_name(file : D::FileDescriptorProto, name : String, scope : String) : {String, Entry}?
      name_ = file.name || ""
      visible = visible_files(file)
      file.option_dependency.each { |dependency| visible << normalize(dependency) }
      full_name, entry = resolve(name_, visible, name, scope, [] of Int32)
      entry.kind.extension? ? {full_name, entry} : nil
    rescue ParseError
      nil
    end

    # --- Symbols ---

    private def build_symbol_table : Nil
      @symbols.clear
      @extensions_by_number = nil
      @order.each do |name|
        file = @files[name]
        package = file.package || ""
        unless package.empty?
          parts = package.split('.')
          parts.size.times do |i|
            full = parts[0..i].join('.')
            existing = @symbols[full]?
            if existing && !existing.kind.package?
              symbol_error(name, [2], "\"#{full}\" is already defined in file \"#{existing.file}\".")
            end
            @symbols[full] ||= Entry.new(SymbolKind::Package, name)
          end
        end
        prefix = package.empty? ? "" : "#{package}."
        file.message_type.each_with_index { |message, i| add_message(name, message, prefix, [4, i]) }
        file.enum_type.each_with_index { |enum_type, i| add_symbol(name, "#{prefix}#{enum_type.name}", SymbolKind::Enum, [5, i], enum_type) }
        file.extension.each_with_index { |field, i| add_symbol(name, "#{prefix}#{field.name}", SymbolKind::Extension, [7, i], field) }
      end
    end

    private def add_message(file : String, message : D::DescriptorProto, prefix : String, path : Array(Int32)) : Nil
      full = "#{prefix}#{message.name}"
      add_symbol(file, full, SymbolKind::Message, path, message)
      message.nested_type.each_with_index { |nested, i| add_message(file, nested, "#{full}.", path + [3, i]) }
      message.enum_type.each_with_index { |enum_type, i| add_symbol(file, "#{full}.#{enum_type.name}", SymbolKind::Enum, path + [4, i], enum_type) }
      message.extension.each_with_index { |field, i| add_symbol(file, "#{full}.#{field.name}", SymbolKind::Extension, path + [6, i], field) }
    end

    private def add_symbol(file : String, full_name : String, kind : SymbolKind, path : Array(Int32), descriptor = nil) : Nil
      if existing = @symbols[full_name]?
        where = existing.file == file ? "" : " in file \"#{existing.file}\""
        symbol_error(file, path, "\"#{full_name}\" is already defined#{where}.")
      end
      @symbols[full_name] = Entry.new(kind, file, descriptor)
    end

    # --- Linking ---

    private def link_file(file : D::FileDescriptorProto) : Nil
      name = file.name || ""
      visible = visible_files(file)
      package = file.package || ""
      file.message_type.each_with_index do |message, i|
        link_message(name, visible, message, package.empty? ? message.name || "" : "#{package}.#{message.name}", [4, i])
      end
      file.extension.each_with_index do |field, i|
        link_field(name, visible, field, package, [7, i])
      end
      file.service.each_with_index do |service, i|
        scope = package.empty? ? service.name || "" : "#{package}.#{service.name}"
        service.method.each_with_index do |method, j|
          path = [6, i, 2, j]
          method.input_type = resolve_message(name, visible, method.input_type || "", scope, path)
          method.output_type = resolve_message(name, visible, method.output_type || "", scope, path)
        end
      end
    end

    private def link_message(file : String, visible : Set(String), message : D::DescriptorProto, full_name : String, path : Array(Int32)) : Nil
      message.field.each_with_index { |field, i| link_field(file, visible, field, full_name, path + [2, i]) }
      message.extension.each_with_index { |field, i| link_field(file, visible, field, full_name, path + [6, i]) }
      message.nested_type.each_with_index do |nested, i|
        link_message(file, visible, nested, "#{full_name}.#{nested.name}", path + [3, i])
      end
    end

    private def link_field(file : String, visible : Set(String), field : D::FieldDescriptorProto, scope : String, path : Array(Int32)) : Nil
      if extendee = field.extendee
        field.extendee = resolve_message(file, visible, extendee, scope, path)
      end
      type_name = field.type_name
      unless type_name
        normalize_default(file, field, path, nil)
        return
      end

      full_name, symbol = resolve(file, visible, type_name, scope, path)
      case symbol.kind
      when .message?
        if field.type.nil?
          field.type = FieldType::TYPE_MESSAGE
        end
      when .enum?
        if field.type.try(&.type_group?)
          symbol_error(file, path, "\"#{type_name}\" is not a message type.")
        end
        field.type = FieldType::TYPE_ENUM
      else
        symbol_error(file, path, "\"#{type_name}\" is not a type.")
      end
      field.type_name = ".#{full_name}"
      normalize_default(file, field, path, symbol.descriptor.as?(D::EnumDescriptorProto))
    end

    # Validates a default value and converts it to the form protoc gives
    # plugins (`FieldDescriptor::DefaultValueAsString`).
    private def normalize_default(file : String, field : D::FieldDescriptorProto, path : Array(Int32), enum_type : D::EnumDescriptorProto?) : Nil
      value = field.default_value || return
      type = field.type || return
      fail = ->(message : String) { default_error(file, field, path, message) }
      if field.label == D::FieldDescriptorProto::Label::LABEL_REPEATED
        fail.call("Repeated fields can't have default values.")
      end
      field.default_value = case type
                            when .type_message?, .type_group?
                              fail.call("Messages can't have default values.")
                            when .type_string?
                              value
                            when .type_bytes?
                              Importer.c_escape(value.to_slice)
                            when .type_bool?
                              fail.call("Boolean default must be true or false.") unless value.in?("true", "false")
                              value
                            when .type_enum?
                              unless enum_type.try(&.value.any? { |v| v.name == value })
                                fail.call("Enum type \"#{enum_type.try(&.name)}\" has no value named \"#{value}\".")
                              end
                              value
                            when .type_float?, .type_double?
                              Importer.format_default_float(value, type.type_float?) || fail.call("Couldn't parse default value \"#{value}\".")
                            else
                              unsigned = type.type_uint32? || type.type_uint64? || type.type_fixed32? || type.type_fixed64?
                              number = Importer.parse_default_integer(value) || fail.call("Couldn't parse default value \"#{value}\".")
                              range = case type
                                      when .type_int32?, .type_sint32?, .type_sfixed32? then {Int32::MIN.to_i128, Int32::MAX.to_i128}
                                      when .type_uint32?, .type_fixed32?                then {0.to_i128, UInt32::MAX.to_i128}
                                      when .type_uint64?, .type_fixed64?                then {0.to_i128, UInt64::MAX.to_i128}
                                      else                                                   {Int64::MIN.to_i128, Int64::MAX.to_i128}
                                      end
                              if number < range[0] || number > range[1]
                                fail.call(unsigned && number < 0 ? "Unsigned field can't have negative default value." : "Integer out of range.")
                              end
                              number.to_s
                            end
    end

    private def default_error(file : String, field : D::FieldDescriptorProto, path : Array(Int32), message : String) : NoReturn
      if token = @default_tokens[file]?.try(&.[field.object_id]?)
        raise ParseError.new(display_path(file), token.line, token.column, message)
      end
      symbol_error(file, path, message)
    end

    # Parses an integer default value ("-0x1F", "017", "42").
    def self.parse_default_integer(text : String) : Int128?
      negative = text.starts_with?('-')
      digits = negative ? text[1..] : text
      return nil if digits.empty?
      value = if digits.starts_with?("0x") || digits.starts_with?("0X")
                digits[2..].to_u64?(16)
              elsif digits.size > 1 && digits.starts_with?('0')
                digits.to_u64?(8)
              else
                digits.to_u64?
              end
      value = value.try(&.to_i128) || return nil
      negative ? -value : value
    end

    # Formats a float default like protoc's `SimpleFtoa` / `SimpleDtoa`.
    def self.format_default_float(text : String, single : Bool) : String?
      value = case text
              when "inf", "infinity"   then Float64::INFINITY
              when "-inf", "-infinity" then -Float64::INFINITY
              when "nan", "-nan"       then Float64::NAN
              else
                if integer = parse_default_integer(text)
                  integer.to_f64
                else
                  text.to_f64? || return nil
                end
              end
      return "nan" if value.nan?
      return value > 0 ? "inf" : "-inf" if value.infinite?
      if single
        float = value.to_f32!
        return float > 0 ? "inf" : "-inf" if float.infinite?
        short = sprintf("%.6g", float)
        short.to_f32? == float ? short : sprintf("%.9g", float)
      else
        short = sprintf("%.15g", value)
        short.to_f64? == value ? short : sprintf("%.17g", value)
      end
    end

    # Escapes bytes like protoc's `CEscape` (used for bytes defaults).
    def self.c_escape(bytes : Bytes) : String
      String.build do |io|
        bytes.each do |byte|
          case byte
          when '\n'.ord then io << "\\n"
          when '\r'.ord then io << "\\r"
          when '\t'.ord then io << "\\t"
          when '"'.ord  then io << "\\\""
          when '\''.ord then io << "\\'"
          when '\\'.ord then io << "\\\\"
          else
            if byte < 0x20 || byte >= 0x7f
              io << '\\' << byte.to_s(8).rjust(3, '0')
            else
              io << byte.unsafe_chr
            end
          end
        end
      end
    end

    private def resolve_message(file : String, visible : Set(String), name : String, scope : String, path : Array(Int32)) : String
      full_name, symbol = resolve(file, visible, name, scope, path)
      symbol_error(file, path, "\"#{name}\" is not a message type.") unless symbol.kind.message?
      ".#{full_name}"
    end

    # Resolves *name* relative to *scope* using protobuf's scoping rules:
    # the innermost scope is searched first; for dotted names only the first
    # component is searched for, and the rest must be found inside it.
    private def resolve(file : String, visible : Set(String), name : String, scope : String, path : Array(Int32)) : {String, Entry}
      if name.starts_with?('.')
        full = name.lchop('.')
        if symbol = @symbols[full]?
          check_visible(file, visible, full, symbol, path)
          return {full, symbol}
        end
        symbol_error(file, path, "\"#{name}\" is not defined.")
      end

      first, _, rest = name.partition('.')
      scope_parts = scope.split('.', remove_empty: true)
      loop do
        prefix = scope_parts.join('.')
        candidate = prefix.empty? ? first : "#{prefix}.#{first}"
        if symbol = @symbols[candidate]?
          if rest.empty?
            if symbol.kind.package?
              # A package is not a type; keep looking outwards.
            else
              check_visible(file, visible, candidate, symbol, path)
              return {candidate, symbol}
            end
          elsif symbol.kind.package? || symbol.kind.message?
            full = "#{candidate}.#{rest}"
            if found = @symbols[full]?
              check_visible(file, visible, full, found, path) unless found.kind.package?
              return {full, found}
            end
            symbol_error(file, path, "\"#{name}\" is resolved to \"#{full}\", which is not defined. The innermost scope is searched first in name resolution. Consider using a leading '.'(i.e., \".#{name}\") to start from the outermost scope.")
          end
        end
        break if scope_parts.empty?
        scope_parts.pop
      end
      symbol_error(file, path, "\"#{name}\" is not defined.")
    end

    private def check_visible(file : String, visible : Set(String), full_name : String, symbol : Entry, path : Array(Int32)) : Nil
      return if symbol.kind.package? || visible.includes?(symbol.file)
      symbol_error(file, path, "\"#{full_name}\" seems to be defined in \"#{symbol.file}\", which is not imported by \"#{file}\".  To use it here, please add the necessary import.")
    end

    # The file itself, its direct dependencies and, transitively, the
    # public dependencies of those.
    private def visible_files(file : D::FileDescriptorProto) : Set(String)
      visible = Set{file.name || ""}
      queue = file.dependency.dup
      until queue.empty?
        name = normalize(queue.shift)
        next if visible.includes?(name)
        visible << name
        if dependency = @files[name]?
          dependency.public_dependency.each { |index| queue << dependency.dependency[index] }
        end
      end
      visible
    end

    # --- Errors ---

    private def missing_message(name : String) : String
      searched = @include_paths.reject { |path| path == BUNDLED_INCLUDE_PATH }
      "Import \"#{name}\" was not found (searched: #{searched.empty? ? "no include paths" : searched.join(", ")})."
    end

    private def import_error(from : {String, Array(Int32)}?, message : String) : NoReturn
      if from
        symbol_error(from[0], from[1], message)
      else
        raise ParseError.new("<input>", 0, 0, message)
      end
    end

    private def symbol_error(file : String, path : Array(Int32), message : String) : NoReturn
      line, column = position(file, path)
      raise ParseError.new(display_path(file), line, column, message)
    end

    # The position of the declaration at *path*, or of its closest recorded
    # ancestor.
    private def position(file : String, path : Array(Int32)) : {Int32, Int32}
      positions = @positions[file]? || return {0, 0}
      current = path
      until current.empty?
        if position = positions[current]?
          return position
        end
        current = current[0...-1]
      end
      {0, 0}
    end

    private def display_path(name : String) : String
      find(name) || name
    end

    private def normalize(name : String) : String
      Path.posix(name).normalize.to_s.lchop("./")
    end
  end
end
