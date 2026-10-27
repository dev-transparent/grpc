module Protobuf::Compiler
  # Raised for syntax and semantic errors in `.proto` files. The message is
  # formatted like protoc's: `file.proto:line:column: message`.
  class ParseError < Exception
    getter filename : String
    getter line : Int32
    getter column : Int32
    getter description : String

    def initialize(@filename : String, @line : Int32, @column : Int32, @description : String)
      super("#{@filename}:#{@line}:#{@column}: #{@description}")
    end
  end

  # A lexical token of the protobuf language.
  struct Token
    enum Kind
      Identifier
      Integer
      Float
      String
      Symbol
      EOF
    end

    getter kind : Kind
    # The token's source text (for strings, including the quotes).
    getter text : String
    # 1-based position of the token's first character.
    getter line : Int32
    getter column : Int32
    # The comment immediately preceding the token, attached using protoc's
    # rules (see `Tokenizer`).
    property leading_comment : String?
    # The decoded value of a string literal.
    getter string_value : String?

    def initialize(@kind : Kind, @text : String, @line : Int32, @column : Int32, @string_value : String? = nil)
    end

    def symbol?(char : String) : Bool
      kind.symbol? && text == char
    end

    def to_s(io : IO) : Nil
      kind.eof? ? io << "end of input" : io << '"' << text << '"'
    end
  end

  # Splits `.proto` source into tokens.
  #
  # Comments are attached to tokens as leading comments following protoc's
  # algorithm (`io::Tokenizer::NextWithComments`), so that generated code
  # carries the same documentation regardless of whether descriptors came
  # from protoc or from `Parser`:
  #
  # * a comment starting on the same line as the previous token is a
  #   trailing comment of that token;
  # * a comment block on the following lines that is separated from the next
  #   token by a blank line is detached (or trailing, if directly after the
  #   previous token);
  # * the comment block directly before a token (no blank line in between)
  #   is its leading comment, unless the token closes a scope.
  class Tokenizer
    @pos = 0
    @line = 1
    @column = 1

    def initialize(@source : String, @filename : String)
      @bytes = @source.to_slice
    end

    def self.tokenize(source : String, filename : String) : Array(Token)
      new(source, filename).tokenize
    end

    def tokenize : Array(Token)
      tokens = [] of Token
      skip_bom
      first = true
      loop do
        token = next_with_comments(first)
        first = false
        tokens << token
        break if token.kind.eof?
      end
      tokens
    end

    # --- Comment collection (mirrors protoc's CommentCollector) ---

    @buffer : String::Builder? = nil
    @buffer_is_line = false
    @can_attach_to_prev = true
    @comment_count = 0

    private def reset_collector(first : Bool) : Nil
      @buffer = nil
      @buffer_is_line = false
      @can_attach_to_prev = !first
      @comment_count = 0
    end

    private def flush : Nil
      if @buffer
        @comment_count += 1
        @can_attach_to_prev = false
        @buffer = nil
      end
    end

    private def line_comment_buffer : String::Builder
      flush if @buffer && !@buffer_is_line
      @buffer_is_line = true
      @buffer ||= String::Builder.new
    end

    private def block_comment_buffer : String::Builder
      flush if @buffer
      @buffer_is_line = false
      @buffer = String::Builder.new
    end

    private def next_with_comments(first : Bool) : Token
      reset_collector(first)
      prev_line = @line
      trailing_end_line = -1

      unless first
        skip_whitespace_no_newline
        case comment_start
        when :line
          trailing_end_line = @line
          consume_line_comment(line_comment_buffer)
          flush
        when :block
          consume_block_comment(block_comment_buffer)
          trailing_end_line = @line
          skip_whitespace_no_newline
          unless try_consume('\n')
            @buffer = nil
            return read_token(nil)
          end
          flush
        else
          return read_token(nil) unless try_consume('\n')
        end
      end

      loop do
        skip_whitespace_no_newline
        case comment_start
        when :line
          consume_line_comment(line_comment_buffer)
        when :block
          consume_block_comment(block_comment_buffer)
          skip_whitespace_no_newline
          try_consume('\n')
        else
          if try_consume('\n')
            flush
            @can_attach_to_prev = false
          else
            token = read_token(nil)
            if token.kind.eof? || token.symbol?("}") || token.symbol?("]") || token.symbol?(")")
              # A comment before the end of a scope is not attached to the
              # closing token.
              flush
            end
            if prev_line == token.line || trailing_end_line == token.line
              total = @comment_count + (@buffer ? 1 : 0)
              if total == 1
                @can_attach_to_prev = false
                flush
              end
            end
            token.leading_comment = @buffer.try(&.to_s)
            return token
          end
        end
      end
    end

    # Returns :line or :block (consuming the comment opener), or nil.
    private def comment_start : Symbol?
      return nil unless peek == '/'
      case peek(1)
      when '/'
        advance(2)
        :line
      when '*'
        advance(2)
        :block
      else
        nil
      end
    end

    # Records everything up to and including the newline.
    private def consume_line_comment(buffer : String::Builder) : Nil
      start = @pos
      until eof? || peek == '\n'
        advance
      end
      advance unless eof?
      buffer.write(@bytes[start, @pos - start])
    end

    # Records the comment body. After each newline, leading whitespace and a
    # single `*` are stripped, as protoc does.
    private def consume_block_comment(buffer : String::Builder) : Nil
      start_line = @line
      start_column = @column - 2
      record_start = @pos
      loop do
        if eof?
          raise ParseError.new(@filename, start_line, start_column, "End-of-file inside block comment.")
        end
        if peek == '\n'
          advance
          buffer.write(@bytes[record_start, @pos - record_start])
          skip_whitespace_no_newline
          if peek == '*'
            advance
            if peek == '/'
              advance
              return
            end
          end
          record_start = @pos
        elsif peek == '*' && peek(1) == '/'
          buffer.write(@bytes[record_start, @pos - record_start])
          advance(2)
          return
        else
          advance
        end
      end
    end

    # --- Tokens ---

    private def read_token(leading : String?) : Token
      line = @line
      column = @column
      return Token.new(Token::Kind::EOF, "", line, column) if eof?

      char = peek
      start = @pos
      if char.ascii_letter? || char == '_'
        while !eof? && (peek.ascii_alphanumeric? || peek == '_')
          advance
        end
        Token.new(Token::Kind::Identifier, text_from(start), line, column)
      elsif char.ascii_number? || (char == '.' && peek(1).ascii_number?)
        read_number(start, line, column)
      elsif char == '"' || char == '\''
        read_string(line, column)
      elsif char.ascii_whitespace?
        # Only reached for whitespace not handled by the comment scanner
        # (e.g. carriage returns); skip it.
        advance
        read_token(leading)
      elsif char.ord < 0x20 || char.ord >= 0x7f
        raise ParseError.new(@filename, line, column, "Invalid control characters encountered in text.")
      else
        advance
        Token.new(Token::Kind::Symbol, char.to_s, line, column)
      end
    end

    private def read_number(start : Int32, line : Int32, column : Int32) : Token
      float = false
      if peek == '0' && (peek(1) == 'x' || peek(1) == 'X')
        advance(2)
        hex_start = @pos
        while !eof? && peek.hex?
          advance
        end
        raise ParseError.new(@filename, line, column, "\"0x\" must be followed by hex digits.") if @pos == hex_start
      else
        while !eof? && peek.ascii_number?
          advance
        end
        if peek == '.'
          float = true
          advance
          while !eof? && peek.ascii_number?
            advance
          end
        end
        if peek == 'e' || peek == 'E'
          float = true
          advance
          advance if peek == '+' || peek == '-'
          exp_start = @pos
          while !eof? && peek.ascii_number?
            advance
          end
          raise ParseError.new(@filename, @line, @column, "\"e\" must be followed by exponent.") if @pos == exp_start
        end
        if peek == 'f' || peek == 'F'
          float = true
          advance
        end
      end
      if !eof? && (peek.ascii_letter? || peek == '_')
        raise ParseError.new(@filename, @line, @column, "Need space between number and identifier.")
      end
      Token.new(float ? Token::Kind::Float : Token::Kind::Integer, text_from(start), line, column)
    end

    private def read_string(line : Int32, column : Int32) : Token
      start = @pos
      quote = peek
      advance
      value = IO::Memory.new
      loop do
        raise ParseError.new(@filename, line, column, "Unexpected end of string.") if eof? || peek == '\n'
        char = peek
        if char == quote
          advance
          break
        elsif char == '\\'
          advance
          read_escape(value, line, column)
        else
          value.write_byte(@bytes[@pos])
          advance
        end
      end
      Token.new(Token::Kind::String, text_from(start), line, column, String.new(value.to_slice))
    end

    private def read_escape(value : IO, line : Int32, column : Int32) : Nil
      char = peek
      advance
      case char
      when 'a'  then value.write_byte(0x07)
      when 'b'  then value.write_byte(0x08)
      when 'f'  then value.write_byte(0x0c)
      when 'n'  then value.write_byte(0x0a)
      when 'r'  then value.write_byte(0x0d)
      when 't'  then value.write_byte(0x09)
      when 'v'  then value.write_byte(0x0b)
      when '\\' then value.write_byte('\\'.ord.to_u8)
      when '?'  then value.write_byte('?'.ord.to_u8)
      when '\'' then value.write_byte('\''.ord.to_u8)
      when '"'  then value.write_byte('"'.ord.to_u8)
      when 'x', 'X'
        digits = read_digits(2, &.hex?)
        raise ParseError.new(@filename, @line, @column, "Expected hex digits for escape sequence.") if digits.empty?
        value.write_byte(digits.to_u8(16))
      when 'u'
        write_codepoint(value, read_digits(4, &.hex?), 4)
      when 'U'
        write_codepoint(value, read_digits(8, &.hex?), 8)
      when '0'..'7'
        digits = char.to_s + read_digits(2) { |c| '0' <= c <= '7' }
        value.write_byte(digits.to_i(8).to_u8!)
      else
        raise ParseError.new(@filename, @line, @column - 1, "Invalid escape sequence in string literal.")
      end
    end

    private def write_codepoint(value : IO, digits : String, expected : Int32) : Nil
      if digits.size != expected
        raise ParseError.new(@filename, @line, @column, "Expected #{expected} hex digits for unicode escape.")
      end
      codepoint = digits.to_i(16)
      char = codepoint.chr rescue raise ParseError.new(@filename, @line, @column, "Invalid unicode code point.")
      value << char
    end

    private def read_digits(max : Int32, &) : String
      start = @pos
      while @pos - start < max && !eof? && yield(peek)
        advance
      end
      text_from(start)
    end

    # --- Character helpers ---

    private def skip_bom : Nil
      if @bytes.size >= 3 && @bytes[0] == 0xef && @bytes[1] == 0xbb && @bytes[2] == 0xbf
        @pos = 3
      end
    end

    private def skip_whitespace_no_newline : Nil
      while !eof? && (peek == ' ' || peek == '\t' || peek == '\r' || peek == '\v' || peek == '\f')
        advance
      end
    end

    private def try_consume(char : Char) : Bool
      if !eof? && peek == char
        advance
        true
      else
        false
      end
    end

    private def eof? : Bool
      @pos >= @bytes.size
    end

    private def peek(offset : Int32 = 0) : Char
      index = @pos + offset
      index < @bytes.size ? @bytes[index].unsafe_chr : '\0'
    end

    private def advance(count : Int32 = 1) : Nil
      count.times do
        break if eof?
        if @bytes[@pos] == '\n'.ord
          @line += 1
          @column = 1
        elsif @bytes[@pos] & 0xc0 != 0x80
          # Count characters, not UTF-8 continuation bytes.
          @column += 1
        end
        @pos += 1
      end
    end

    private def text_from(start : Int32) : String
      String.new(@bytes[start, @pos - start])
    end
  end
end
