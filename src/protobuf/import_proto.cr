module Protobuf
  # Holds a marker constant for every `.proto` file defined through
  # `import_proto`, so each file is only defined once.
  module ImportedFiles
  end

  # Generates message classes and enums from a `.proto` file at compile time.
  #
  # ```
  # Protobuf.import_proto "proto/person.proto"
  #
  # Person.new(name: "Ada").to_protobuf
  # ```
  #
  # *path* is relative to the file containing the call. Imports are resolved
  # against *include_paths* (also relative to the calling file), then the
  # directory of *path*, then the bundled well-known types
  # (`google/protobuf/*.proto`). Imported files are generated as well; a file
  # imported by several `import_proto` calls is only defined once.
  #
  # The generated code is exactly what `protoc-gen-crystal` produces for the
  # same file (minus the per-file `require`s). Pass `dump: true` to print it
  # at compile time. Call the macro at the top level.
  #
  # For services use `GRPC.import_proto`, which also generates service base
  # classes and client stubs.
  macro import_proto(path, *include_paths, dump = false)
    {% unless path.is_a?(StringLiteral) %}
      {% raise "Protobuf.import_proto expects a string literal path, not #{path}" %}
    {% end %}
    {% base = path.filename ? path.filename.split("/")[0..-2].join("/") : "." %}
    {% code = run("./compiler/import_runner", "--macro", "--base", base, "--no-grpc",
         "--includes", include_paths.map(&.id).join(","), path) %}
    {% if code.starts_with?("__PROTOBUF_IMPORT_ERROR__") %}
      {% path.raise code.gsub(/^__PROTOBUF_IMPORT_ERROR__/, "") %}
    {% end %}
    {% if dump %}
      {% puts code %}
    {% end %}
    {{code}}
  end
end
