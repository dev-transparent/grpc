# Compile-time runner behind `Protobuf.import_proto` / `GRPC.import_proto`.
# Parses a `.proto` file (and its imports) and prints the generated Crystal
# code, which the macro pastes into the program.
#
# It can also be run directly to see the code a macro call generates:
#
#   crystal run src/protobuf/compiler/import_runner.cr -- [--no-grpc] [-I DIR]... FILE.proto
#
# Relative paths are resolved against `--base DIR` (the directory of the
# file calling the macro), defaulting to the current directory.
require "./generator"
require "./importer"

module Protobuf::Compiler::ImportRunner
  # Printed before the error message when `--macro` is given, so the macro
  # can report the error at the `import_proto` call site.
  ERROR_MARKER = "__PROTOBUF_IMPORT_ERROR__"

  def self.run(args : Array(String)) : Int32
    macro_mode = false
    base = Dir.current
    grpc = true
    includes = [] of String
    files = [] of String

    index = 0
    while index < args.size
      arg = args[index]
      case arg
      when "--base"
        base = args[index += 1]? || return usage
      when "--no-grpc"
        grpc = false
      when "--grpc"
        grpc = true
      when "--macro"
        macro_mode = true
      when "-I"
        includes << (args[index += 1]? || return usage)
      when .starts_with?("-I")
        includes << arg.lchop("-I")
      when "--includes"
        # Comma separated include paths (used by the macros).
        value = args[index += 1]? || return usage
        includes.concat(value.split(',', remove_empty: true))
      else
        files << arg
      end
      index += 1
    end
    return usage if files.empty?

    include_paths = includes.map { |path| File.expand_path(path, base) }
    paths = files.map { |file| File.expand_path(file, base) }
    paths.each do |path|
      unless include_paths.any? { |include_path| path.starts_with?("#{include_path}/") }
        include_paths << File.dirname(path)
      end
    end

    importer = Importer.new(include_paths)
    names = paths.map do |path|
      raise ParseError.new(path, 0, 0, "File not found.") unless File.file?(path)
      importer.name_for(path).not_nil!
    end
    request = importer.code_generator_request(names, grpc ? nil : "grpc=false")
    STDOUT.print Generator.new(request).generate_inline
    0
  rescue e : ParseError | Generator::Error
    if macro_mode
      STDOUT.print "#{ERROR_MARKER}#{e.message}"
      0
    else
      STDERR.puts e.message
      1
    end
  end

  private def self.usage : Int32
    STDERR.puts "Usage: import_runner [--base DIR] [--no-grpc] [-I DIR]... FILE.proto..."
    2
  end
end

exit Protobuf::Compiler::ImportRunner.run(ARGV)
