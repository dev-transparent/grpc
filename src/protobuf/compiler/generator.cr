require "../../protobuf"

module Protobuf::Compiler
  # Generates Crystal source code from protobuf descriptors, as provided by
  # `protoc` to a plugin in a `CodeGeneratorRequest`.
  #
  # For every `foo/bar.proto` file to generate, the generator emits
  # `foo/bar.pb.cr` containing messages and enums, and, if the file defines
  # services, `foo/bar_grpc.pb.cr` containing gRPC service base classes and
  # client stubs.
  #
  # Supported plugin parameters (`--crystal_opt=key=value,...`):
  #
  # * `grpc=false`: do not generate service files.
  # * `require=<path>`: add `require "<path>"` at the top of every generated
  #   file (e.g. `require=grpc`).
  # * `experimental_editions=true`: also accept files using edition
  #   `UNSTABLE` (protoc's in-development edition).
  class Generator
    alias Descriptor = Google::Protobuf
    alias FS = Google::Protobuf::FeatureSet
    alias FieldType = Google::Protobuf::FieldDescriptorProto::Type
    alias FieldLabel = Google::Protobuf::FieldDescriptorProto::Label
    alias Request = Google::Protobuf::Compiler::CodeGeneratorRequest
    alias Response = Google::Protobuf::Compiler::CodeGeneratorResponse

    class Error < Exception
    end

    CRYSTAL_KEYWORDS = Set{
      "abstract", "alias", "annotation", "as", "asm", "begin", "break", "case", "class", "def", "do",
      "else", "elsif", "end", "ensure", "enum", "extend", "false", "for", "fun", "if", "in", "include",
      "instance_sizeof", "is_a?", "lib", "macro", "module", "next", "nil", "of", "offsetof", "out",
      "pointerof", "private", "protected", "require", "rescue", "responds_to?", "return", "select",
      "self", "sizeof", "struct", "super", "then", "true", "typeof", "uninitialized", "union",
      "unless", "until", "verbatim", "when", "while", "with", "yield",
    }

    # Method names that generated accessors must not override.
    RESERVED_METHODS = Set{
      "hash", "clone", "dup", "inspect", "to_s", "object_id", "itself", "tap", "try", "not_nil!",
      "to_protobuf", "from_protobuf", "merge_from", "merge_from_protobuf", "unknown_fields",
      "discard_unknown_fields", "initialize", "finalize", "crystal_type_id", "unsafe_as",
      "same?", "pretty_print", "display", "new", "allocate", "instance_vars", "responds_to",
      "to_json", "from_json", "to_pretty_json", "merge_from_json", "get_extension", "set_extension",
      "clear_extension", "extension_fields", "missing_required_fields", "protobuf_json_write",
      "protobuf_json_merge", "protobuf_json_write_fields",
    }

    # Method names of `GRPC::Client` and `GRPC::Service` that generated RPC
    # methods must not override.
    RESERVED_RPC_METHODS = Set{
      "channel", "metadata", "default_timeout", "compression", "max_receive_message_size",
      "intercept", "close", "start_call", "start_unary", "call_unary", "call_server_streaming",
      "call_client_streaming", "call_bidi_streaming", "service_name", "rpc_methods",
      "max_send_message_size", "wait_for_ready", "call_credentials", "with_options",
    }

    SCALAR_TYPES = {
      FieldType::TYPE_DOUBLE   => {"Float64", nil},
      FieldType::TYPE_FLOAT    => {"Float32", nil},
      FieldType::TYPE_INT64    => {"Int64", nil},
      FieldType::TYPE_UINT64   => {"UInt64", nil},
      FieldType::TYPE_INT32    => {"Int32", nil},
      FieldType::TYPE_FIXED64  => {"UInt64", "fixed64"},
      FieldType::TYPE_FIXED32  => {"UInt32", "fixed32"},
      FieldType::TYPE_BOOL     => {"Bool", nil},
      FieldType::TYPE_STRING   => {"String", nil},
      FieldType::TYPE_BYTES    => {"Bytes", nil},
      FieldType::TYPE_UINT32   => {"UInt32", nil},
      FieldType::TYPE_SFIXED32 => {"Int32", "sfixed32"},
      FieldType::TYPE_SFIXED64 => {"Int64", "sfixed64"},
      FieldType::TYPE_SINT32   => {"Int32", "sint32"},
      FieldType::TYPE_SINT64   => {"Int64", "sint64"},
    }

    # Information about a named type (message or enum) across all files.
    record TypeInfo,
      crystal_name : String,
      descriptor : Descriptor::DescriptorProto | Descriptor::EnumDescriptorProto,
      file : Descriptor::FileDescriptorProto

    # Resolved language features for a file, message or field.
    record Features,
      field_presence : Descriptor::FeatureSet::FieldPresence,
      repeated_field_encoding : Descriptor::FeatureSet::RepeatedFieldEncoding,
      utf8_validation : Descriptor::FeatureSet::Utf8Validation,
      message_encoding : Descriptor::FeatureSet::MessageEncoding,
      enum_type : Descriptor::FeatureSet::EnumType do
      def merge(set : Descriptor::FeatureSet?) : Features
        return self unless set
        Features.new(
          set.field_presence.try { |v| v.field_presence_unknown? ? nil : v } || field_presence,
          set.repeated_field_encoding.try { |v| v.repeated_field_encoding_unknown? ? nil : v } || repeated_field_encoding,
          set.utf8_validation.try { |v| v.utf8_validation_unknown? ? nil : v } || utf8_validation,
          set.message_encoding.try { |v| v.message_encoding_unknown? ? nil : v } || message_encoding,
          set.enum_type.try { |v| v.enum_type_unknown? ? nil : v } || enum_type,
        )
      end
    end

    getter request : Request
    @types = {} of String => TypeInfo
    @generate_grpc = true
    @extra_requires = [] of String
    @experimental_editions = false
    @files_by_name = {} of String => Descriptor::FileDescriptorProto

    def initialize(@request : Request)
      parse_parameters(@request.parameter || "")
      @request.proto_file.each do |file|
        @files_by_name[file.name || ""] = file
        register_types(file)
      end
    end

    # Runs the generator, returning a response containing the generated
    # files or an error.
    def self.call(request : Request) : Response
      new(request).generate
    rescue e : Error
      Response.new(error: e.message, supported_features: supported_features)
    end

    def self.supported_features : UInt64
      (Response::Feature::FEATURE_PROTO3_OPTIONAL.value | Response::Feature::FEATURE_SUPPORTS_EDITIONS.value).to_u64
    end

    def generate : Response
      files = [] of Response::File
      @request.file_to_generate.each do |name|
        file = @files_by_name[name]? || raise Error.new("File #{name} not found in request")
        files << Response::File.new(name: output_name(name, ".pb.cr"), content: generate_messages_file(file))
        if @generate_grpc && !file.service.empty?
          files << Response::File.new(name: output_name(name, "_grpc.pb.cr"), content: generate_services_file(file))
        end
      end
      Response.new(
        supported_features: Generator.supported_features,
        minimum_edition: Descriptor::Edition::EDITION_PROTO2.value,
        maximum_edition: (@experimental_editions ? Descriptor::Edition::EDITION_UNSTABLE : Descriptor::Edition::EDITION_2026).value,
        file: files,
      )
    end

    # Proto files whose generated code is bundled with the runtime (see
    # `src/protobuf/well_known_types.cr`); never emitted inline.
    BUNDLED_FILES = Set{
      "google/protobuf/descriptor.proto", "google/protobuf/compiler/plugin.proto",
      "google/protobuf/any.proto", "google/protobuf/api.proto", "google/protobuf/duration.proto",
      "google/protobuf/empty.proto", "google/protobuf/field_mask.proto",
      "google/protobuf/source_context.proto", "google/protobuf/struct.proto",
      "google/protobuf/timestamp.proto", "google/protobuf/type.proto", "google/protobuf/wrappers.proto",
      # Language feature definitions: their sources are bundled for imports
      # (`import option`), but no code is generated for them.
      "google/protobuf/cpp_features.proto", "google/protobuf/java_features.proto",
      "google/protobuf/go_features.proto", "google/protobuf/c_sharp_features.proto",
    }

    # Generates the code for the files to generate and all their (non
    # bundled) dependencies as a single Crystal source, as used by
    # `Protobuf.import_proto`. Each file is wrapped in a guard so that it is
    # only defined once, even when imported by several `import_proto` calls.
    #
    # The message and service definitions are exactly those `#generate`
    # produces; only the per-file wrapper (requires vs. guards) differs.
    def generate_inline : String
      output = Output.new
      ordered = [] of Descriptor::FileDescriptorProto
      visited = Set(String).new
      @request.file_to_generate.each { |name| collect_inline(name, ordered, visited) }

      ordered.each_with_index do |file, i|
        output.line if i > 0
        name = file.name || ""
        marker = Generator.inline_marker(name)
        output.line("# source: #{name}")
        output.line("{% unless ::Protobuf::ImportedFiles.has_constant?(#{marker.inspect}) %}")
        output.line("module ::Protobuf::ImportedFiles")
        output.line("  #{marker} = #{name.inspect}")
        output.line("end")
        output.line
        emit_messages(output, file)
        output.line
        emit_registration(output, file)
        if @generate_grpc && !file.service.empty?
          output.line
          emit_services(output, file)
        end
        output.line("{% end %}")
      end
      output.to_s
    end

    # The name of the constant marking *proto_name* as defined.
    def self.inline_marker(proto_name : String) : String
      # Escape every non-alphanumeric character so distinct paths never map
      # to the same constant.
      "F_" + proto_name.gsub(/[^A-Za-z0-9]/) { |match| "_#{match[0].ord.to_s(16)}_" }
    end

    private def collect_inline(name : String, ordered, visited) : Nil
      return if visited.includes?(name) || BUNDLED_FILES.includes?(name)
      visited << name
      file = @files_by_name[name]? || raise Error.new("File #{name} not found in request")
      file.dependency.each { |dependency| collect_inline(dependency, ordered, visited) }
      ordered << file
    end

    # --- Parameters ---

    private def parse_parameters(parameter : String) : Nil
      parameter.split(',', remove_empty: true).each do |pair|
        key, _, value = pair.partition('=')
        case key.strip
        when "grpc"                  then @generate_grpc = !(value.strip == "false")
        when "require"               then @extra_requires << value.strip
        when "experimental_editions" then @experimental_editions = value.strip == "true"
        else
          raise Error.new("Unknown parameter #{key.inspect}")
        end
      end
    end

    # --- Naming ---

    # Converts a proto package (`foo.bar_baz`) to a Crystal module path
    # (`Foo::BarBaz`).
    def self.module_name(package : String) : String
      package.split('.').map { |part| constant_name(part) }.join("::")
    end

    # Converts an identifier to a valid Crystal constant name.
    def self.constant_name(name : String) : String
      camel = name.split('_').map_with_index do |part, i|
        part.empty? ? (i == 0 ? "" : "_") : part[0].upcase + part[1..]
      end.join
      camel = "X" + camel unless camel[0]?.try(&.ascii_letter?)
      camel
    end

    # Converts an identifier to snake_case, as used for methods.
    def self.method_name(name : String) : String
      snake = name.gsub(/([a-z\d])([A-Z])/, "\\1_\\2").gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2").downcase
      snake = "_" + snake if snake[0]?.try(&.ascii_number?)
      snake
    end

    # Converts a field name to a Crystal accessor name that does not clash
    # with keywords or reserved methods.
    def self.field_name(name : String) : String
      snake = method_name(name)
      if CRYSTAL_KEYWORDS.includes?(snake) || RESERVED_METHODS.includes?(snake)
        snake + "_"
      else
        snake
      end
    end

    # Converts an RPC method name to a Crystal method name that does not clash
    # with methods of the service and client base classes.
    def self.rpc_method_name(name : String) : String
      snake = field_name(name)
      RESERVED_RPC_METHODS.includes?(snake) ? snake + "_" : snake
    end

    # Converts an enum value name to a valid Crystal enum member name.
    def self.enum_member_name(name : String) : String
      name[0].ascii_letter? ? name[0].upcase + name[1..] : "X" + name
    end

    private def output_name(proto_name : String, suffix : String) : String
      proto_name.rchop(".proto") + suffix
    end

    # --- Type registry ---

    private def register_types(file : Descriptor::FileDescriptorProto) : Nil
      package = file.package || ""
      proto_prefix = package.empty? ? "" : ".#{package}"
      crystal_prefix = package.empty? ? "" : "::#{Generator.module_name(package)}"
      file.message_type.each { |message| register_message(file, message, proto_prefix, crystal_prefix) }
      file.enum_type.each do |enum_type|
        name = enum_type.name || ""
        @types["#{proto_prefix}.#{name}"] = TypeInfo.new("#{crystal_prefix}::#{Generator.constant_name(name)}", enum_type, file)
      end
    end

    private def register_message(file, message : Descriptor::DescriptorProto, proto_prefix : String, crystal_prefix : String) : Nil
      name = message.name || ""
      proto_name = "#{proto_prefix}.#{name}"
      crystal_name = "#{crystal_prefix}::#{Generator.constant_name(name)}"
      @types[proto_name] = TypeInfo.new(crystal_name, message, file)
      message.nested_type.each { |nested| register_message(file, nested, proto_name, crystal_name) }
      message.enum_type.each do |enum_type|
        enum_name = enum_type.name || ""
        @types["#{proto_name}.#{enum_name}"] = TypeInfo.new("#{crystal_name}::#{Generator.constant_name(enum_name)}", enum_type, file)
      end
    end

    private def lookup(type_name : String) : TypeInfo
      @types[type_name]? || raise Error.new("Unknown type #{type_name}")
    end

    private def map_entry?(message : Descriptor::DescriptorProto) : Bool
      message.options.try(&.map_entry) == true
    end

    # --- Features ---

    private def edition(file : Descriptor::FileDescriptorProto) : Descriptor::Edition
      case file.syntax
      when "proto3"   then Descriptor::Edition::EDITION_PROTO3
      when "editions" then file.edition || Descriptor::Edition::EDITION_2023
      else                 Descriptor::Edition::EDITION_PROTO2
      end
    end

    private def file_features(file : Descriptor::FileDescriptorProto) : Features
      defaults = case edition(file)
                 when Descriptor::Edition::EDITION_PROTO2
                   Features.new(FS::FieldPresence::EXPLICIT, FS::RepeatedFieldEncoding::EXPANDED, FS::Utf8Validation::NONE, FS::MessageEncoding::LENGTH_PREFIXED, FS::EnumType::CLOSED)
                 when Descriptor::Edition::EDITION_PROTO3
                   Features.new(FS::FieldPresence::IMPLICIT, FS::RepeatedFieldEncoding::PACKED, FS::Utf8Validation::VERIFY, FS::MessageEncoding::LENGTH_PREFIXED, FS::EnumType::OPEN)
                 else
                   # Editions 2023 and later share these defaults.
                   Features.new(FS::FieldPresence::EXPLICIT, FS::RepeatedFieldEncoding::PACKED, FS::Utf8Validation::VERIFY, FS::MessageEncoding::LENGTH_PREFIXED, FS::EnumType::OPEN)
                 end
      defaults.merge(file.options.try(&.features))
    end

    # --- Output helpers ---

    private class Output
      getter io = IO::Memory.new
      @indent = 0
      @last_line = ""

      # Returns `true` if the last line written opened a block (or was blank).
      def after_block_start? : Bool
        @last_line.empty? || @last_line.ends_with?(" do") || @last_line.starts_with?("class ") ||
          @last_line.starts_with?("module ") || @last_line.starts_with?("include ")
      end

      def line(text : String = "") : Nil
        @last_line = text
        if text.empty?
          @io << '\n'
        else
          @indent.times { @io << "  " }
          @io << text << '\n'
        end
      end

      def push_indent : Nil
        @indent += 1
      end

      def pop_indent : Nil
        @indent -= 1
      end

      def indent(&) : Nil
        @indent += 1
        yield
      ensure
        @indent -= 1
      end

      def block(header : String, &) : Nil
        line(header)
        indent { yield }
        line("end")
      end

      def comment(text : String?) : Nil
        return unless text
        lines = text.chomp.lines.map(&.rstrip)
        while lines.first?.try(&.strip.empty?)
          lines.shift
        end
        while lines.last?.try(&.strip.empty?)
          lines.pop
        end
        lines.each { |l| line(l.empty? ? "#" : "##{l.starts_with?(' ') ? "" : " "}#{l}") }
      end

      def to_s : String
        @io.to_s
      end
    end

    private def comments(file : Descriptor::FileDescriptorProto) : Hash(Array(Int32), String)
      result = {} of Array(Int32) => String
      file.source_code_info.try &.location.each do |location|
        if comment = location.leading_comments
          result[location.path] = comment
        end
      end
      result
    end

    private def header(output : Output, file : Descriptor::FileDescriptorProto) : Nil
      output.line("# Code generated by protoc-gen-crystal. DO NOT EDIT.")
      output.line("# source: #{file.name}")
      unless @extra_requires.empty?
        output.line
        @extra_requires.each { |path| output.line("require #{path.inspect}") }
      end
    end

    # --- Messages file ---

    private def generate_messages_file(file : Descriptor::FileDescriptorProto) : String
      output = Output.new
      header(output, file)
      requires = file.dependency.reject(&.starts_with?("google/protobuf/"))
      output.line unless requires.empty?
      requires.each do |dependency|
        output.line("require #{relative_require(file.name || "", dependency, ".pb").inspect}")
      end
      output.line
      emit_messages(output, file)
      output.line
      emit_registration(output, file)
      output.to_s
    end

    # Emits the enums, messages and extensions of *file*, wrapped in its
    # package modules.
    private def emit_messages(output : Output, file : Descriptor::FileDescriptorProto) : Nil
      comments = comments(file)
      features = file_features(file)
      scope = package_scope(file)
      package = file.package || ""
      with_modules(output, file.package) do
        first = true
        file.enum_type.each_with_index do |enum_type, i|
          output.line unless first
          first = false
          emit_enum(output, enum_type, features, comments, [5, i], package)
        end
        file.message_type.each_with_index do |message, i|
          output.line unless first
          first = false
          emit_message(output, file, message, features, comments, [4, i], scope, package)
        end
        unless file.extension.empty?
          output.line unless first
          emit_extensions(output, file.extension, features, comments, [7], scope, package, scope)
        end
      end
    end

    # Emits the call registering *file* with `Protobuf::Registry`: its
    # descriptor (without source info), message classes and extensions.
    private def emit_registration(output : Output, file : Descriptor::FileDescriptorProto) : Nil
      messages = [] of String
      extensions = [] of String
      package = file.package || ""
      crystal_prefix = package.empty? ? "" : "::#{Generator.module_name(package)}"
      file.message_type.each { |message| collect_registered(message, crystal_prefix, messages, extensions) }
      extension_constants(file.extension, package_scope(file)).each { |constant| extensions << "#{crystal_prefix}::#{constant}" }

      output.line("::Protobuf::Registry.register_file(")
      output.indent do
        output.line("#{(file.name || "").inspect},")
        literal = Generator.bytes_literal(Generator.embedded_descriptor(file))
        literal.each_with_index do |part, i|
          output.line(i == literal.size - 1 ? "#{part}," : "#{part} \\")
        end
        if messages.empty?
          output.line("[] of ::Protobuf::MessageClass,")
        else
          output.line("[")
          output.indent { messages.each { |name| output.line("#{name},") } }
          output.line("] of ::Protobuf::MessageClass,")
        end
        if extensions.empty?
          output.line("[] of ::Protobuf::ExtensionField,")
        else
          output.line("[")
          output.indent { extensions.each { |name| output.line("#{name},") } }
          output.line("] of ::Protobuf::ExtensionField,")
        end
      end
      output.line(")")
    end

    private def collect_registered(message : Descriptor::DescriptorProto, prefix : String, messages : Array(String), extensions : Array(String)) : Nil
      return if map_entry?(message)
      name = "#{prefix}::#{Generator.constant_name(message.name || "")}"
      messages << name
      extension_constants(message.extension, nested_constants(message)).each { |constant| extensions << "#{name}::#{constant}" }
      message.nested_type.each { |nested| collect_registered(nested, name, messages, extensions) }
    end

    # The descriptor embedded in generated code: the file descriptor
    # without source code info, serialized.
    def self.embedded_descriptor(file : Descriptor::FileDescriptorProto) : Bytes
      copy = file.clone
      copy.source_code_info = nil
      copy.to_protobuf
    end

    # Formats *bytes* as Crystal string literals of bounded width (to be
    # joined with line continuations).
    def self.bytes_literal(bytes : Bytes, width : Int32 = 96) : Array(String)
      parts = [] of String
      current = IO::Memory.new
      size = 0
      bytes.each do |byte|
        piece = if 0x20 <= byte < 0x7f && byte != '"'.ord && byte != '\\'.ord && byte != '#'.ord
                  byte.chr.to_s
                else
                  "\\x#{byte.to_s(16).rjust(2, '0').upcase}"
                end
        if size + piece.size > width
          parts << "\"#{current}\""
          current = IO::Memory.new
          size = 0
        end
        current << piece
        size += piece.size
      end
      parts << "\"#{current}\"" if size > 0 || parts.empty?
      parts
    end

    # The constant names of *extensions*, avoiding the names in *taken*
    # (types defined in the same scope).
    private def extension_constants(extensions : Array(Descriptor::FieldDescriptorProto), taken : Set(String)) : Array(String)
      used = taken.dup
      extensions.map do |field|
        name = Generator.extension_constant_name(field.name || "")
        while used.includes?(name)
          name += "_EXTENSION"
        end
        used << name
        name
      end
    end

    # The constant names of the types nested in *message*.
    private def nested_constants(message : Descriptor::DescriptorProto) : Set(String)
      names = Set(String).new
      message.nested_type.each { |nested| names << Generator.constant_name(nested.name || "") }
      message.enum_type.each { |enum_type| names << Generator.constant_name(enum_type.name || "") }
      names
    end

    # The name of the constant holding an extension: its proto name in
    # upper case.
    def self.extension_constant_name(name : String) : String
      upper = name.upcase
      upper[0]?.try(&.ascii_letter?) ? upper : "X#{upper}"
    end

    # Returns the constant names visible at the top level of the modules of
    # *file*'s package: the package modules and the top-level types of every
    # file in the same package or an enclosing package.
    private def package_scope(file : Descriptor::FileDescriptorProto) : Set(String)
      package = file.package || ""
      scope = package.split('.', remove_empty: true).map { |part| Generator.constant_name(part) }.to_set
      @files_by_name.each_value do |other|
        other_package = other.package || ""
        next unless other_package == package || (!other_package.empty? && package.starts_with?("#{other_package}."))
        other.message_type.each { |message| scope << Generator.constant_name(message.name || "") }
        other.enum_type.each { |enum_type| scope << Generator.constant_name(enum_type.name || "") }
      end
      scope
    end

    private def with_modules(output : Output, package : String?, &) : Nil
      modules = (package || "").split('.', remove_empty: true).map { |part| Generator.constant_name(part) }
      modules.each do |name|
        output.line("module #{name}")
        output.push_indent
      end
      yield
      modules.size.times do
        output.pop_indent
        output.line("end")
      end
    end

    private def relative_require(from : String, to : String, suffix : String) : String
      from_dir = Path.posix(from).parent
      target = Path.posix(to.rchop(".proto") + suffix)
      relative = target.relative_to(from_dir).to_s
      relative.starts_with?("../") ? relative : "./#{relative}"
    end

    private def emit_enum(output : Output, enum_type : Descriptor::EnumDescriptorProto, parent_features : Features, comments, path : Array(Int32), scope_name : String) : Nil
      features = parent_features.merge(enum_type.options.try(&.features))
      name = enum_type.name || ""
      full_name = scope_name.empty? ? name : "#{scope_name}.#{name}"
      output.comment(comments[path]?)
      output.line("@[::Protobuf::TypeName(#{full_name.inspect})]")
      output.line("@[::Protobuf::ClosedEnum]") if features.enum_type.closed?
      renamed = enum_type.value.compact_map do |value|
        proto = value.name || ""
        member = Generator.enum_member_name(proto)
        "#{member.inspect} => #{proto.inspect}" unless member == proto
      end
      output.line("@[::Protobuf::EnumValueNames({#{renamed.join(", ")}})]") unless renamed.empty?
      output.block("enum #{Generator.constant_name(name)} : Int32") do
        enum_type.value.each_with_index do |value, i|
          output.comment(comments[path + [2, i]]?)
          output.line("#{Generator.enum_member_name(value.name || "")} = #{value.number || 0}")
        end
      end
    end

    private def emit_message(output : Output, file, message : Descriptor::DescriptorProto, parent_features : Features, comments, path : Array(Int32), parent_scope : Set(String), scope_name : String) : Nil
      features = parent_features.merge(message.options.try(&.features))
      scope = parent_scope.dup
      message.nested_type.each { |nested| scope << Generator.constant_name(nested.name || "") }
      message.enum_type.each { |enum_type| scope << Generator.constant_name(enum_type.name || "") }
      name = message.name || ""
      full_name = scope_name.empty? ? name : "#{scope_name}.#{name}"
      output.comment(comments[path]?)
      output.line("@[::Protobuf::TypeName(#{full_name.inspect})]")
      output.line("@[::Protobuf::MessageSet]") if message.options.try(&.message_set_wire_format)
      output.block("class #{Generator.constant_name(name)}") do
        output.line("include ::Protobuf::Message")

        message.enum_type.each_with_index do |enum_type, i|
          output.line
          emit_enum(output, enum_type, features, comments, path + [4, i], full_name)
        end
        message.nested_type.each_with_index do |nested, i|
          next if map_entry?(nested)
          output.line
          emit_message(output, file, nested, features, comments, path + [3, i], scope, full_name)
        end

        oneofs = Hash(Int32, Array({Descriptor::FieldDescriptorProto, Int32})).new
        regular = [] of {Descriptor::FieldDescriptorProto, Int32}
        message.field.each_with_index do |field, i|
          if (index = field.oneof_index) && !field.proto3_optional
            (oneofs[index] ||= [] of {Descriptor::FieldDescriptorProto, Int32}) << {field, i}
          else
            regular << {field, i}
          end
        end

        output.line unless regular.empty?
        regular.each do |(field, i)|
          emit_field(output, file, field, features, comments, path + [2, i], scope)
        end
        oneofs.each do |index, members|
          oneof = message.oneof_decl[index]? || raise Error.new("Invalid oneof index in #{message.name}")
          output.line
          output.comment(comments[path + [8, index]]?)
          output.block("oneof #{Generator.field_name(oneof.name || "")} do") do
            members.each do |(field, i)|
              emit_field(output, file, field, features, comments, path + [2, i], scope, in_oneof: true)
            end
          end
        end

        unless message.extension.empty?
          output.line
          emit_extensions(output, message.extension, features, comments, path + [6], scope, full_name, nested_constants(message))
        end
      end
    end

    # Returns `true` if *field* is a message field using group (delimited)
    # encoding.
    private def delimited?(field : Descriptor::FieldDescriptorProto, features : Features) : Bool
      type = field.type
      return true if type.try(&.type_group?)
      return false unless type.try(&.type_message?) && features.message_encoding.delimited?
      # Map fields always use length-prefixed entries.
      !(field.label == FieldLabel::LABEL_REPEATED && (info = @types[field.type_name || ""]?) &&
        (entry = info.descriptor.as?(Descriptor::DescriptorProto)) && map_entry?(entry))
    end

    private def emit_field(output : Output, file, field : Descriptor::FieldDescriptorProto, parent_features : Features, comments, path : Array(Int32), scope : Set(String), in_oneof = false) : Nil
      features = parent_features.merge(field.options.try(&.features))
      proto_name = field.name || ""
      name = Generator.field_name(proto_name)
      number = field.number || 0
      type = field.type || raise Error.new("Field #{field.name} has no type")
      repeated = field.label == FieldLabel::LABEL_REPEATED

      if comment = comments[path]?
        output.line unless output.after_block_start?
        output.comment(comment)
      end

      if repeated && type.type_message? && (info = lookup(field.type_name || "")) &&
         (entry = info.descriptor.as?(Descriptor::DescriptorProto)) && map_entry?(entry)
        emit_map_field(output, field, name, number, entry, features, scope)
        return
      end

      crystal_type, kind = field_type(field, scope)
      kind = "group" if delimited?(field, features)
      options = [] of String
      options << "type: :#{kind}" if kind
      utf8 = !features.utf8_validation.none?

      if repeated
        if packable?(type)
          packed = field.options.try(&.packed)
          packed = features.repeated_field_encoding.packed? if packed.nil?
          options << "packed: false" unless packed
        end
        options << "utf8: false" if type.type_string? && !utf8
        add_name_options(options, field, name)
        output.line("repeated #{name} : #{crystal_type}, #{number}#{format_options(options)}")
      else
        required = field.label == FieldLabel::LABEL_REQUIRED || features.field_presence.legacy_required?
        explicit = field.proto3_optional == true || required || !features.field_presence.implicit?
        message = type.type_message? || type.type_group?
        if required
          options << "required: true"
        elsif explicit && !message && !in_oneof
          options << "optional: true"
        end
        if (default = field.default_value) && !message
          options << "default: #{default_literal(field, default)}"
        end
        options << "utf8: false" if type.type_string? && !utf8
        add_name_options(options, field, name)
        output.line("field #{name} : #{crystal_type}, #{number}#{format_options(options)}")
      end
    end

    # Adds `proto_name:` / `json_name:` when they differ from what the
    # runtime derives from the Crystal field name.
    private def add_name_options(options : Array(String), field : Descriptor::FieldDescriptorProto, crystal_name : String) : Nil
      proto_name = field.name || ""
      options << "proto_name: #{proto_name.inspect}" unless proto_name == crystal_name
      if (json_name = field.json_name) && json_name != ::Protobuf::JSON.json_name(proto_name)
        options << "json_name: #{json_name.inspect}"
      end
    end

    # The Crystal literal for a proto2 default value (as given by protoc in
    # `default_value`).
    private def default_literal(field : Descriptor::FieldDescriptorProto, value : String) : String
      type = field.type || raise Error.new("Field #{field.name} has no type")
      case type
      when .type_string?
        value.inspect
      when .type_bytes?
        bytes = Generator.unescape_bytes(value)
        bytes.empty? ? "::Bytes.empty" : "::Bytes[#{bytes.join(", ")}]"
      when .type_bool?
        value == "true" ? "true" : "false"
      when .type_enum?
        info = lookup(field.type_name || "")
        "#{info.crystal_name}::#{Generator.enum_member_name(value)}"
      when .type_float?, .type_double?
        suffix = type.type_float? ? "32" : "64"
        case value
        when "inf"  then "::Float#{suffix}::INFINITY"
        when "-inf" then "-::Float#{suffix}::INFINITY"
        when "nan"  then "::Float#{suffix}::NAN"
        else
          number = value.to_f64? || raise Error.new("Invalid default value #{value.inspect} for #{field.name}")
          literal = type.type_float? ? number.to_f32!.to_s : number.to_s
          "#{literal}_f#{suffix}"
        end
      when .type_int64?, .type_sint64?, .type_sfixed64?
        "#{value.to_i64? || raise Error.new("Invalid default value #{value.inspect} for #{field.name}")}_i64"
      when .type_uint64?, .type_fixed64?
        "#{value.to_u64? || raise Error.new("Invalid default value #{value.inspect} for #{field.name}")}_u64"
      when .type_uint32?, .type_fixed32?
        "#{value.to_u32? || raise Error.new("Invalid default value #{value.inspect} for #{field.name}")}_u32"
      else
        (value.to_i32? || raise Error.new("Invalid default value #{value.inspect} for #{field.name}")).to_s
      end
    end

    # Decodes a C-escaped string, as protoc uses for bytes default values.
    def self.unescape_bytes(value : String) : Bytes
      io = IO::Memory.new
      bytes = value.to_slice
      i = 0
      while i < bytes.size
        byte = bytes[i]
        if byte == '\\'.ord && i + 1 < bytes.size
          i += 1
          char = bytes[i].unsafe_chr
          case char
          when 'n' then io.write_byte(10_u8)
          when 'r' then io.write_byte(13_u8)
          when 't' then io.write_byte(9_u8)
          when 'a' then io.write_byte(7_u8)
          when 'b' then io.write_byte(8_u8)
          when 'f' then io.write_byte(12_u8)
          when 'v' then io.write_byte(11_u8)
          when 'x', 'X'
            digits = 0
            code = 0
            while digits < 2 && i + 1 < bytes.size && bytes[i + 1].unsafe_chr.hex?
              i += 1
              code = code * 16 + bytes[i].unsafe_chr.to_i(16)
              digits += 1
            end
            io.write_byte(code.to_u8!)
          when '0'..'7'
            code = char.to_i
            digits = 1
            while digits < 3 && i + 1 < bytes.size && bytes[i + 1].unsafe_chr.in?('0'..'7')
              i += 1
              code = code * 8 + bytes[i].unsafe_chr.to_i
              digits += 1
            end
            io.write_byte(code.to_u8!)
          else
            io.write_byte(bytes[i])
          end
        else
          io.write_byte(byte)
        end
        i += 1
      end
      io.to_slice
    end

    # Emits a constant for each extension in *extensions*.
    private def emit_extensions(output : Output, extensions : Array(Descriptor::FieldDescriptorProto), parent_features : Features, comments, path : Array(Int32), scope : Set(String), scope_name : String, taken : Set(String)) : Nil
      constants = extension_constants(extensions, taken)
      extensions.each_with_index do |field, i|
        features = parent_features.merge(field.options.try(&.features))
        output.comment(comments[path + [i]]?)
        extendee = lookup(field.extendee || "").crystal_name
        crystal_type, kind = field_type(field, scope)
        type = field.type || raise Error.new("Extension #{field.name} has no type")
        kind = "group" if delimited?(field, features)
        repeated = field.label == FieldLabel::LABEL_REPEATED
        crystal_type = "::Array(#{crystal_type})" if repeated
        full_name = scope_name.empty? ? (field.name || "") : "#{scope_name}.#{field.name}"
        options = [] of String
        options << "type: :#{kind}" if kind
        if repeated && packable?(type)
          packed = field.options.try(&.packed)
          packed = features.repeated_field_encoding.packed? if packed.nil?
          options << "packed: true" if packed
        end
        options << "utf8: false" if type.type_string? && features.utf8_validation.none?
        output.line("#{constants[i]} = ::Protobuf::Extension(#{extendee}, #{crystal_type}).new(#{full_name.inspect}, #{field.number || 0}#{format_options(options)})")
      end
    end

    private def emit_map_field(output : Output, field : Descriptor::FieldDescriptorProto, name : String, number : Int32, entry : Descriptor::DescriptorProto, features : Features, scope : Set(String)) : Nil
      key = entry.field.find { |f| f.number == 1 } || raise Error.new("Map entry without key")
      value = entry.field.find { |f| f.number == 2 } || raise Error.new("Map entry without value")
      key_type, key_kind = field_type(key, scope)
      value_type, value_kind = field_type(value, scope)
      options = [] of String
      options << "key_type: :#{key_kind}" if key_kind
      options << "value_type: :#{value_kind}" if value_kind
      if features.utf8_validation.none? && (key.type.try(&.type_string?) || value.type.try(&.type_string?))
        options << "utf8: false"
      end
      add_name_options(options, field, name)
      output.line("map #{name} : Hash(#{key_type}, #{value_type}), #{number}#{format_options(options)}")
    end

    private def format_options(options : Array(String)) : String
      options.empty? ? "" : ", " + options.join(", ")
    end

    private def packable?(type : FieldType) : Bool
      !(type.type_string? || type.type_bytes? || type.type_message? || type.type_group?)
    end

    # Returns the Crystal type and, when it cannot be inferred from the type,
    # the protobuf kind of a field. Scalar types are fully qualified when a
    # generated type in *scope* has the same name (e.g. a nested `Bool` enum).
    private def field_type(field : Descriptor::FieldDescriptorProto, scope : Set(String)) : {String, String?}
      type = field.type || raise Error.new("Field #{field.name} has no type")
      if scalar = SCALAR_TYPES[type]?
        crystal_type, kind = scalar
        {scope.includes?(crystal_type) ? "::#{crystal_type}" : crystal_type, kind}
      else
        {lookup(field.type_name || "").crystal_name, nil}
      end
    end

    # --- Services file ---

    private def generate_services_file(file : Descriptor::FileDescriptorProto) : String
      output = Output.new
      header(output, file)
      output.line
      output.line("require #{relative_require(file.name || "", file.name || "", ".pb").inspect}")
      output.line
      emit_services(output, file)
      output.to_s
    end

    # Emits the service base classes and client stubs of *file*, wrapped in
    # its package modules.
    private def emit_services(output : Output, file : Descriptor::FileDescriptorProto) : Nil
      comments = comments(file)
      package = file.package || ""
      with_modules(output, file.package) do
        file.service.each_with_index do |service, i|
          output.line if i > 0
          emit_service(output, package, service, comments, [6, i])
        end
      end
    end

    private def emit_service(output : Output, package : String, service : Descriptor::ServiceDescriptorProto, comments, path : Array(Int32)) : Nil
      service_name = service.name || ""
      full_name = package.empty? ? service_name : "#{package}.#{service_name}"

      output.comment(comments[path]?)
      output.block("module #{Generator.constant_name(service_name)}") do
        output.line("SERVICE_NAME = #{full_name.inspect}")
        output.line

        output.line("# Base class for implementations of the #{full_name} service.")
        output.line("# Subclass it, implement the abstract methods and register an instance")
        output.line("# with `GRPC::Server#handle`.")
        output.block("abstract class Service") do
          output.line("include ::GRPC::Service")
          output.line
          output.block("def service_name : String") do
            output.line("SERVICE_NAME")
          end

          service.method.each_with_index do |method, i|
            output.line
            output.comment(comments[path + [2, i]]?)
            input = lookup(method.input_type || "").crystal_name
            out = lookup(method.output_type || "").crystal_name
            name = Generator.rpc_method_name(method.name || "")
            case {method.client_streaming == true, method.server_streaming == true}
            when {false, false}
              output.line("# Returns a `#{out}`.")
              output.line("abstract def #{name}(request : #{input}, context : ::GRPC::ServerContext)")
            when {false, true}
              output.line("abstract def #{name}(request : #{input}, responses : ::GRPC::ResponseStream(#{out}), context : ::GRPC::ServerContext)")
            when {true, false}
              output.line("# Returns a `#{out}`.")
              output.line("abstract def #{name}(requests : ::GRPC::RequestStream(#{input}), context : ::GRPC::ServerContext)")
            else
              output.line("abstract def #{name}(requests : ::GRPC::RequestStream(#{input}), responses : ::GRPC::ResponseStream(#{out}), context : ::GRPC::ServerContext)")
            end
          end

          output.line
          output.block("def rpc_methods : Array(::GRPC::RpcMethod)") do
            output.line("[")
            output.indent do
              service.method.each do |method|
                input = lookup(method.input_type || "").crystal_name
                out = lookup(method.output_type || "").crystal_name
                name = Generator.rpc_method_name(method.name || "")
                rpc = (method.name || "").inspect
                case {method.client_streaming == true, method.server_streaming == true}
                when {false, false}
                  output.line("::GRPC::RpcMethod.unary(#{rpc}, #{input}, #{out}) { |request, context| #{name}(request, context) },")
                when {false, true}
                  output.line("::GRPC::RpcMethod.server_streaming(#{rpc}, #{input}, #{out}) { |request, responses, context| #{name}(request, responses, context) },")
                when {true, false}
                  output.line("::GRPC::RpcMethod.client_streaming(#{rpc}, #{input}, #{out}) { |requests, context| #{name}(requests, context) },")
                else
                  output.line("::GRPC::RpcMethod.bidi_streaming(#{rpc}, #{input}, #{out}) { |requests, responses, context| #{name}(requests, responses, context) },")
                end
              end
            end
            output.line("] of ::GRPC::RpcMethod")
          end
        end

        output.line
        output.line("# Client stub for the #{full_name} service.")
        output.block("class Client < ::GRPC::Client") do
          service.method.each_with_index do |method, i|
            output.line if i > 0
            output.comment(comments[path + [2, i]]?)
            input = lookup(method.input_type || "").crystal_name
            out = lookup(method.output_type || "").crystal_name
            name = Generator.rpc_method_name(method.name || "")
            rpc_path = "/#{full_name}/#{method.name}".inspect
            options = "metadata : ::GRPC::Metadata | ::Hash(String, String) | ::Nil = nil, deadline : ::Time::Span | ::Time | ::Nil = nil, options : ::GRPC::CallOptions? = nil"
            case {method.client_streaming == true, method.server_streaming == true}
            when {false, false}
              output.block("def #{name}(request : #{input}, *, #{options}) : #{out}") do
                output.line("call_unary(#{rpc_path}, request, #{out}, metadata, deadline, options)")
              end
              output.line
              output.line("# Like `##{name}`, but returns the call to give access to response metadata.")
              output.block("def #{name}_call(request : #{input}, *, #{options}) : ::GRPC::UnaryCall(#{out})") do
                output.line("start_unary(#{rpc_path}, request, #{out}, metadata, deadline, options)")
              end
            when {false, true}
              output.block("def #{name}(request : #{input}, *, #{options}) : ::GRPC::ServerStreamingCall(#{out})") do
                output.line("call_server_streaming(#{rpc_path}, request, #{out}, metadata, deadline, options)")
              end
            when {true, false}
              output.block("def #{name}(*, #{options}) : ::GRPC::ClientStreamingCall(#{input}, #{out})") do
                output.line("call_client_streaming(#{rpc_path}, #{input}, #{out}, metadata, deadline, options)")
              end
              output.line
              output.line("# Sends the requests written to the call in the block and returns the response.")
              output.block("def #{name}(*, #{options}, & : ::GRPC::ClientStreamingCall(#{input}, #{out}) ->) : #{out}") do
                output.line("call = #{name}(metadata: metadata, deadline: deadline, options: options)")
                output.line("call.run { yield call }")
              end
            else
              output.block("def #{name}(*, #{options}) : ::GRPC::BidiStreamingCall(#{input}, #{out})") do
                output.line("call_bidi_streaming(#{rpc_path}, #{input}, #{out}, metadata, deadline, options)")
              end
            end
          end
        end
      end
    end
  end
end
