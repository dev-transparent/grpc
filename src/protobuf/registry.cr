module Protobuf
  # Global registry of the `.proto` files, message classes and extensions
  # compiled into the program.
  #
  # Generated code (from `protoc-gen-crystal` or `import_proto`) registers
  # every file with its serialized `google.protobuf.FileDescriptorProto`
  # (without source info), its message classes and its extensions. The
  # bundled well-known types and `descriptor.proto` are always registered.
  #
  # ```
  # Protobuf::Registry.message_class("google.protobuf.Duration") # => Google::Protobuf::Duration
  # Protobuf::Registry.file_descriptor("google/protobuf/any.proto")
  # Protobuf::Registry.file_containing_symbol("helloworld.Greeter")
  # Protobuf::Registry.extensions_of("pkg.Options")
  # ```
  #
  # The registry provides what a gRPC server reflection service needs:
  # the list of services, files by name or by contained symbol or
  # extension (`#file_with_dependencies` adds the transitive imports), and
  # extension numbers by type.
  #
  # Symbols are fully qualified proto names without a leading dot: packages
  # are not symbols, but messages, enums, enum values (scoped like their
  # enum type, as in protobuf), fields, oneofs, extensions, services and
  # methods are.
  module Registry
    # A registered `.proto` file.
    class FileEntry
      getter name : String
      # The serialized `FileDescriptorProto`.
      getter serialized : Bytes
      getter messages : Array(MessageClass)
      getter extensions : Array(ExtensionField)
      @descriptor : Google::Protobuf::FileDescriptorProto?

      def initialize(@name : String, @serialized : Bytes, @messages : Array(MessageClass), @extensions : Array(ExtensionField))
      end

      # The decoded descriptor (decoded once, on first use).
      def descriptor : Google::Protobuf::FileDescriptorProto
        @descriptor ||= Google::Protobuf::FileDescriptorProto.from_protobuf(@serialized)
      end

      # The names of the files this file imports.
      def dependencies : Array(String)
        descriptor.dependency
      end
    end

    # What a symbol refers to.
    enum SymbolKind
      Message
      Enum
      EnumValue
      Field
      Oneof
      Extension
      Service
      Method
    end

    record SymbolInfo, kind : SymbolKind, file : String, descriptor : Google::Protobuf::DescriptorProto | Google::Protobuf::EnumDescriptorProto |
                                                                      Google::Protobuf::EnumValueDescriptorProto | Google::Protobuf::FieldDescriptorProto |
                                                                      Google::Protobuf::OneofDescriptorProto | Google::Protobuf::ServiceDescriptorProto |
                                                                      Google::Protobuf::MethodDescriptorProto

    @@files = {} of String => FileEntry
    @@messages = {} of String => MessageClass
    @@extensions = {} of String => Hash(Int32, ExtensionField)
    @@extensions_by_name = {} of String => ExtensionField
    @@symbols : Hash(String, SymbolInfo)? = nil
    @@mutex = Mutex.new(:reentrant)

    # Registers a file. Called by generated code.
    def self.register_file(name : String, descriptor : String | Bytes, messages : Array(MessageClass) = [] of MessageClass,
                           extensions : Array(ExtensionField) = [] of ExtensionField) : Nil
      bytes = descriptor.is_a?(String) ? descriptor.to_slice : descriptor
      @@mutex.synchronize do
        if existing = @@files[name]?
          return if existing.serialized == bytes
          raise Error.new("Conflicting registrations for #{name}: the file is compiled into the program twice with different contents")
        end
        @@files[name] = FileEntry.new(name, bytes, messages, extensions)
        messages.each { |klass| @@messages[klass.full_name] = klass }
        extensions.each { |extension| register_extension(extension) }
        @@symbols = nil
      end
    end

    # Registers an extension that is not part of a generated file (e.g.
    # declared by hand), so that it is parsed from binary and JSON data.
    def self.register_extension(extension : ExtensionField) : Nil
      @@mutex.synchronize do
        (@@extensions[extension.extendee] ||= {} of Int32 => ExtensionField)[extension.number] = extension
        @@extensions_by_name[extension.full_name] = extension
      end
    end

    # --- Files ---

    # The names of all registered files.
    def self.file_names : Array(String)
      @@mutex.synchronize { @@files.keys }
    end

    def self.file?(name : String) : FileEntry?
      @@mutex.synchronize { @@files[name]? }
    end

    # The descriptor of the file *name*, or `nil` if it is not registered.
    def self.file_descriptor(name : String) : Google::Protobuf::FileDescriptorProto?
      file?(name).try(&.descriptor)
    end

    # The serialized descriptor of the file *name*.
    def self.file_descriptor_bytes(name : String) : Bytes?
      file?(name).try(&.serialized)
    end

    # The names of the files imported by *name*.
    def self.dependencies(name : String) : Array(String)?
      file?(name).try(&.dependencies)
    end

    # The file *name* followed by its transitive dependencies (each file
    # once). Dependencies that are not registered are skipped.
    def self.file_with_dependencies(name : String) : Array(Google::Protobuf::FileDescriptorProto)
      result = [] of Google::Protobuf::FileDescriptorProto
      seen = Set(String).new
      queue = [name]
      until queue.empty?
        current = queue.shift
        next unless seen.add?(current)
        if entry = file?(current)
          result << entry.descriptor
          queue.concat(entry.dependencies)
        end
      end
      result
    end

    # --- Symbols ---

    # The symbol *name* (`pkg.Message`, `pkg.Service.Method`, ...), or `nil`.
    def self.symbol(name : String) : SymbolInfo?
      symbols[name.lchop('.')]?
    end

    # The name of the file defining the symbol *name*.
    def self.file_name_containing_symbol(name : String) : String?
      symbol(name).try(&.file)
    end

    # The descriptor of the file defining the symbol *name*.
    def self.file_containing_symbol(name : String) : Google::Protobuf::FileDescriptorProto?
      file_name_containing_symbol(name).try { |file| file_descriptor(file) }
    end

    # The descriptor of the message *name*.
    def self.message_descriptor(name : String) : Google::Protobuf::DescriptorProto?
      symbol(name).try(&.descriptor.as?(Google::Protobuf::DescriptorProto))
    end

    # The descriptor of the enum *name*.
    def self.enum_descriptor(name : String) : Google::Protobuf::EnumDescriptorProto?
      symbol(name).try(&.descriptor.as?(Google::Protobuf::EnumDescriptorProto))
    end

    # The descriptor of the service *name*.
    def self.service_descriptor(name : String) : Google::Protobuf::ServiceDescriptorProto?
      symbol(name).try(&.descriptor.as?(Google::Protobuf::ServiceDescriptorProto))
    end

    # The fully qualified names of all registered services.
    def self.services : Array(String)
      symbols.compact_map { |name, symbol| name if symbol.kind.service? }.sort!
    end

    private def self.symbols : Hash(String, SymbolInfo)
      @@mutex.synchronize do
        @@symbols ||= begin
          index = {} of String => SymbolInfo
          @@files.each_value { |entry| index_file(index, entry) }
          index
        end
      end
    end

    private def self.index_file(index : Hash(String, SymbolInfo), entry : FileEntry) : Nil
      file = entry.descriptor
      package = file.package || ""
      prefix = package.empty? ? "" : "#{package}."
      file.message_type.each { |message| index_message(index, entry.name, message, prefix) }
      file.enum_type.each { |enum_type| index_enum(index, entry.name, enum_type, prefix) }
      file.extension.each { |field| add(index, "#{prefix}#{field.name}", SymbolKind::Extension, entry.name, field) }
      file.service.each do |service|
        service_name = "#{prefix}#{service.name}"
        add(index, service_name, SymbolKind::Service, entry.name, service)
        service.method.each { |method| add(index, "#{service_name}.#{method.name}", SymbolKind::Method, entry.name, method) }
      end
    end

    private def self.index_message(index, file : String, message : Google::Protobuf::DescriptorProto, prefix : String) : Nil
      name = "#{prefix}#{message.name}"
      add(index, name, SymbolKind::Message, file, message)
      message.field.each { |field| add(index, "#{name}.#{field.name}", SymbolKind::Field, file, field) }
      message.oneof_decl.each { |oneof| add(index, "#{name}.#{oneof.name}", SymbolKind::Oneof, file, oneof) }
      message.extension.each { |field| add(index, "#{name}.#{field.name}", SymbolKind::Extension, file, field) }
      message.nested_type.each { |nested| index_message(index, file, nested, "#{name}.") }
      message.enum_type.each { |enum_type| index_enum(index, file, enum_type, "#{name}.") }
    end

    private def self.index_enum(index, file : String, enum_type : Google::Protobuf::EnumDescriptorProto, prefix : String) : Nil
      add(index, "#{prefix}#{enum_type.name}", SymbolKind::Enum, file, enum_type)
      # Enum values are scoped as siblings of their enum type.
      enum_type.value.each { |value| add(index, "#{prefix}#{value.name}", SymbolKind::EnumValue, file, value) }
    end

    private def self.add(index, name : String, kind : SymbolKind, file : String, descriptor) : Nil
      index[name] ||= SymbolInfo.new(kind, file, descriptor)
    end

    # --- Messages ---

    # The message class for the fully qualified message name *name*.
    # Raises `Protobuf::Error` if there is none.
    def self.message_class(name : String) : MessageClass
      message_class?(name) || raise Error.new("Unknown message type #{name}")
    end

    # The message class for *name*, or `nil`.
    def self.message_class?(name : String) : MessageClass?
      @@mutex.synchronize { @@messages[name.lchop('.')]? }
    end

    # The message class for an `Any` type URL
    # (`type.googleapis.com/pkg.Message`), or `nil`.
    def self.message_class_for_type_url(type_url : String) : MessageClass?
      slash = type_url.rindex('/')
      name = slash ? type_url[(slash + 1)..] : type_url
      return nil if name.empty?
      message_class?(name)
    end

    # The fully qualified names of all registered message classes.
    def self.message_names : Array(String)
      @@mutex.synchronize { @@messages.keys }
    end

    # --- Extensions ---

    # The extensions of the message *extendee* (a fully qualified name),
    # sorted by field number.
    def self.extensions_of(extendee : String) : Array(ExtensionField)
      @@mutex.synchronize do
        (@@extensions[extendee.lchop('.')]?.try(&.values) || [] of ExtensionField).sort_by!(&.number)
      end
    end

    # The field numbers of all extensions of *extendee*.
    def self.extension_numbers(extendee : String) : Array(Int32)
      extensions_of(extendee).map(&.number)
    end

    # The extension of *extendee* with field number *number*, or `nil`.
    def self.extension(extendee : String, number : Int32) : ExtensionField?
      @@mutex.synchronize { @@extensions[extendee]?.try(&.[number]?) }
    end

    # The extension with the fully qualified name *full_name*, or `nil`.
    def self.extension(full_name : String) : ExtensionField?
      @@mutex.synchronize { @@extensions_by_name[full_name.lchop('.')]? }
    end

    # :nodoc:
    def self.extensions?(extendee : String) : Bool
      @@mutex.synchronize { @@extensions.has_key?(extendee) }
    end

    # The descriptor of the file declaring the extension of *extendee* with
    # field number *number*.
    def self.file_containing_extension(extendee : String, number : Int32) : Google::Protobuf::FileDescriptorProto?
      extension = extension(extendee.lchop('.'), number) || return nil
      file_containing_symbol(extension.full_name)
    end
  end
end
