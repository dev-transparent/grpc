module GRPC
  # A parsed channel target URI
  # (https://github.com/grpc/grpc/blob/master/doc/naming.md).
  #
  # Targets have the form `scheme://authority/endpoint` or `scheme:endpoint`.
  # Strings that are not URIs, or whose scheme has no registered resolver
  # (e.g. `"localhost:50051"`), are interpreted as `dns:///<target>`.
  struct Target
    URI_PATTERN = /\A([a-zA-Z][a-zA-Z0-9+.\-]*):(.*)\z/m

    # The URI scheme selecting the resolver (e.g. `"dns"`).
    getter scheme : String
    # The URI authority (empty if absent). For `dns` this names the DNS
    # server to use.
    getter authority : String
    # The resolver specific part: the URI path without its leading `/`, or
    # the opaque part of `scheme:endpoint` URIs.
    getter endpoint : String
    # The target string as given.
    getter original : String
    # Whether the target used the `scheme://authority/...` form.
    getter? hierarchical : Bool

    def initialize(@scheme : String, @authority : String, @endpoint : String, @original : String, @hierarchical : Bool)
    end

    # Parses *target*. *known_scheme* decides whether a scheme is
    # recognized; unknown schemes fall back to `dns:///target`.
    def self.parse(target : String, known_scheme : String -> Bool = ->(scheme : String) { Resolver.registered?(scheme) }) : Target
      if (match = URI_PATTERN.match(target)) && known_scheme.call(match[1].downcase)
        scheme = match[1].downcase
        rest = match[2]
        if rest.starts_with?("//")
          authority, _, path = rest[2..].partition('/')
          return new(scheme, authority, path, target, true)
        end
        return new(scheme, "", rest, target, false)
      end
      new("dns", "", target, target, false)
    end

    def to_s(io : IO) : Nil
      io << @original
    end
  end
end
