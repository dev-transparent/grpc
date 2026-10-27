require "./grpc_helper"

describe GRPC::StatusCode do
  it "has the canonical numeric values" do
    GRPC::StatusCode::Ok.value.should eq 0
    GRPC::StatusCode::Cancelled.value.should eq 1
    GRPC::StatusCode::DeadlineExceeded.value.should eq 4
    GRPC::StatusCode::ResourceExhausted.value.should eq 8
    GRPC::StatusCode::Unimplemented.value.should eq 12
    GRPC::StatusCode::Internal.value.should eq 13
    GRPC::StatusCode::Unavailable.value.should eq 14
    GRPC::StatusCode::Unauthenticated.value.should eq 16
  end

  describe ".from_http_status" do
    it "maps HTTP statuses as specified by http-grpc-status-mapping" do
      {
        400 => GRPC::StatusCode::Internal,
        401 => GRPC::StatusCode::Unauthenticated,
        403 => GRPC::StatusCode::PermissionDenied,
        404 => GRPC::StatusCode::Unimplemented,
        429 => GRPC::StatusCode::Unavailable,
        502 => GRPC::StatusCode::Unavailable,
        503 => GRPC::StatusCode::Unavailable,
        504 => GRPC::StatusCode::Unavailable,
      }.each do |http, code|
        GRPC::StatusCode.from_http_status(http).should eq code
      end
    end

    it "maps other statuses to UNKNOWN" do
      [200, 302, 405, 415, 500, 0].each do |http|
        GRPC::StatusCode.from_http_status(http).should eq GRPC::StatusCode::Unknown
      end
    end
  end
end

describe GRPC::Status do
  it "formats with and without a message" do
    GRPC::Status.new(GRPC::StatusCode::NotFound, "nope").to_s.should eq "NotFound: nope"
    GRPC::Status.new(GRPC::StatusCode::NotFound).to_s.should eq "NotFound"
    GRPC::Status.ok.ok?.should be_true
    GRPC::Status.new(GRPC::StatusCode::Internal).ok?.should be_false
  end

  describe ".encode_message" do
    it "leaves printable ASCII untouched" do
      GRPC::Status.encode_message("Hello, world! ~{}").should eq "Hello, world! ~{}"
      GRPC::Status.encode_message("").should eq ""
    end

    it "percent-encodes '%', control characters and non-ASCII bytes" do
      GRPC::Status.encode_message("100%").should eq "100%25"
      GRPC::Status.encode_message("a\tb\nc\r").should eq "a%09b%0Ac%0D"
      GRPC::Status.encode_message("\u007F").should eq "%7F"
      GRPC::Status.encode_message("☺").should eq "%E2%98%BA"
      GRPC::Status.encode_message("😈").should eq "%F0%9F%98%88"
    end
  end

  describe ".decode_message" do
    it "decodes upper and lower case escapes" do
      GRPC::Status.decode_message("100%25").should eq "100%"
      GRPC::Status.decode_message("%e2%98%ba").should eq "☺"
      GRPC::Status.decode_message("%E2%98%BA").should eq "☺"
      GRPC::Status.decode_message("a%41").should eq "aA"
      GRPC::Status.decode_message("%41").should eq "A"
    end

    it "passes invalid escapes through unchanged" do
      GRPC::Status.decode_message("%").should eq "%"
      GRPC::Status.decode_message("%4").should eq "%4"
      GRPC::Status.decode_message("ab%").should eq "ab%"
      GRPC::Status.decode_message("%zz").should eq "%zz"
      GRPC::Status.decode_message("%4g%41").should eq "%4gA"
      GRPC::Status.decode_message("%%41").should eq "%A"
      GRPC::Status.decode_message("no escapes").should eq "no escapes"
    end

    it "does not fail on escapes that decode to invalid UTF-8" do
      decoded = GRPC::Status.decode_message("%FF%FEok")
      decoded.to_slice.should eq Bytes[0xff, 0xfe, 'o'.ord, 'k'.ord]
    end

    it "round trips arbitrary messages" do
      [
        "",
        "plain",
        "\t\ntest with whitespace\r\nand Unicode BMP ☺ and non-BMP 😈\t\n",
        "%%%25%",
        "日本語のメッセージ",
        String.new(Bytes.new(256) { |i| i.to_u8 }),
      ].each do |message|
        encoded = GRPC::Status.encode_message(message)
        encoded.each_byte { |byte| (0x20 <= byte <= 0x7e).should be_true }
        GRPC::Status.decode_message(encoded).to_slice.should eq message.to_slice
      end
    end
  end
end

describe GRPC::Error do
  it "exposes the status, code, details and trailing metadata" do
    trailers = GRPC::Metadata{"x-reason" => "test"}
    error = GRPC::Error.new(GRPC::StatusCode::NotFound, "missing", Bytes[1, 2], trailers)
    error.code.should eq GRPC::StatusCode::NotFound
    error.status.message.should eq "missing"
    error.details.should eq Bytes[1, 2]
    error.metadata["x-reason"].should eq "test"
    error.message.should eq "NotFound: missing"
  end

  it "accepts a symbol code and defaults to empty metadata" do
    error = GRPC::Error.new(:permission_denied)
    error.code.should eq GRPC::StatusCode::PermissionDenied
    error.message.should eq "PermissionDenied"
    error.metadata.empty?.should be_true
  end
end
