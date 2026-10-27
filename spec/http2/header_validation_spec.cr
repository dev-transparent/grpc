require "./support"

private alias HV = HTTP2::HeaderValidation

private def request(extra = [] of {String, String}, method = "GET", path = "/")
  [{":method", method}, {":scheme", "https"}, {":authority", "example.com"}, {":path", path}] + extra
end

private def malformed(message : Regex? = nil, &)
  error = expect_raises(HTTP2::StreamError) { yield }
  error.code.should eq(HTTP2::ErrorCode::PROTOCOL_ERROR)
  error.stream_id.should eq(7)
  error.message.not_nil!.should match(message) if message
  error
end

private def bad_request(fields, message : Regex? = nil)
  malformed(message) { HV.validate_request(7_u32, fields) }
end

private def bad_response(fields, message : Regex? = nil)
  malformed(message) { HV.validate_response(7_u32, fields) }
end

private def bad_trailers(fields, message : Regex? = nil)
  malformed(message) { HV.validate_trailers(7_u32, fields) }
end

describe HTTP2::HeaderValidation do
  describe ".validate_request" do
    it "accepts a valid request" do
      head = HV.validate_request(7_u32, request([{"accept", "*/*"}, {"te", "trailers"}]))
      head.method.should eq("GET")
      head.scheme.should eq("https")
      head.authority.should eq("example.com")
      head.path.should eq("/")
      head.protocol.should be_nil
      head.headers.should eq([{"accept", "*/*"}, {"te", "trailers"}])
      head.content_length.should be_nil
    end

    it "accepts a request without :authority" do
      head = HV.validate_request(7_u32, [{":method", "GET"}, {":scheme", "http"}, {":path", "*"}, {"host", "example.com"}])
      head.authority.should be_nil
    end

    it "accepts empty values and a host matching :authority" do
      HV.validate_request(7_u32, request([{"x-empty", ""}, {"host", "example.com"}]))
    end

    it "accepts a valid CONNECT request" do
      head = HV.validate_request(7_u32, [{":method", "CONNECT"}, {":authority", "example.com:443"}])
      head.method.should eq("CONNECT")
      head.path.should be_nil
      head.scheme.should be_nil
    end

    it "accepts an extended CONNECT request with :protocol" do
      fields = [{":method", "CONNECT"}, {":protocol", "websocket"}, {":scheme", "https"}, {":path", "/chat"}, {":authority", "example.com"}]
      HV.validate_request(7_u32, fields).protocol.should eq("websocket")
    end

    it "parses content-length" do
      HV.validate_request(7_u32, request([{"content-length", "42"}])).content_length.should eq(42)
      HV.validate_request(7_u32, request([{"content-length", "0"}])).content_length.should eq(0)
      HV.validate_request(7_u32, request([{"content-length", "5"}, {"content-length", "5"}])).content_length.should eq(5)
    end

    it "rejects a missing :method" do
      bad_request([{":scheme", "https"}, {":path", "/"}], /:method/)
    end

    it "rejects a missing :scheme" do
      bad_request([{":method", "GET"}, {":path", "/"}], /:scheme/)
    end

    it "rejects a missing :path" do
      bad_request([{":method", "GET"}, {":scheme", "https"}], /:path/)
    end

    it "rejects an empty :path" do
      bad_request(request(path: ""), /empty :path/)
    end

    it "rejects CONNECT with :scheme or :path" do
      bad_request([{":method", "CONNECT"}, {":authority", "a:1"}, {":path", "/"}], /CONNECT/)
      bad_request([{":method", "CONNECT"}, {":authority", "a:1"}, {":scheme", "https"}], /CONNECT/)
    end

    it "rejects CONNECT without :authority" do
      bad_request([{":method", "CONNECT"}], /:authority/)
    end

    it "rejects :protocol on a non-CONNECT request" do
      bad_request([{":method", "GET"}, {":protocol", "websocket"}, {":scheme", "https"}, {":path", "/"}], /:protocol/)
    end

    it "rejects extended CONNECT without :path" do
      bad_request([{":method", "CONNECT"}, {":protocol", "websocket"}, {":scheme", "https"}, {":authority", "a"}], /:path/)
    end

    it "rejects unknown pseudo-headers" do
      bad_request([{":foo", "bar"}] + request, /unknown pseudo-header/)
    end

    it "rejects response pseudo-headers in requests" do
      bad_request(request.insert(0, {":status", "200"}), /unknown pseudo-header :status/)
    end

    it "rejects duplicate pseudo-headers" do
      bad_request(request.insert(1, {":method", "POST"}), /duplicate/)
      bad_request(request.insert(1, {":path", "/x"}), /duplicate/)
    end

    it "rejects pseudo-headers after regular headers" do
      bad_request([{":method", "GET"}, {":scheme", "https"}, {"accept", "*/*"}, {":path", "/"}], /after regular header/)
    end

    it "rejects uppercase header names" do
      bad_request(request([{"Accept", "*/*"}]), /invalid header name/)
    end

    it "rejects an empty header name" do
      bad_request(request([{"", "x"}]), /empty header name/)
    end

    it "rejects header names with invalid characters" do
      ["a b", "a:b", "a\"b", "a\u{0}b", "a(b", "é"].each do |name|
        bad_request(request([{name, "x"}]), /invalid header name/)
      end
    end

    it "accepts token characters in header names" do
      HV.validate_request(7_u32, request([{"x-!#$%&'*+-.^_`|~09az", "x"}]))
    end

    it "rejects connection-specific headers" do
      %w(connection keep-alive proxy-connection transfer-encoding upgrade).each do |name|
        bad_request(request([{name, "x"}]), /connection-specific/)
      end
    end

    it "rejects te with a value other than trailers" do
      bad_request(request([{"te", "gzip"}]), /te header/)
      bad_request(request([{"te", "trailers, deflate"}]), /te header/)
    end

    it "rejects values with leading or trailing whitespace" do
      bad_request(request([{"x-a", " value"}]), /whitespace/)
      bad_request(request([{"x-a", "value "}]), /whitespace/)
      bad_request(request([{"x-a", "\tvalue"}]), /whitespace/)
      bad_request(request([{"x-a", "value\t"}]), /whitespace/)
    end

    it "accepts inner whitespace in values" do
      HV.validate_request(7_u32, request([{"x-a", "a b\tc"}]))
    end

    it "rejects values with NUL, CR or LF" do
      ["a\u{0}b", "a\rb", "a\nb", "a\r\nb"].each do |value|
        bad_request(request([{"x-a", value}]), /invalid characters/)
      end
    end

    it "rejects invalid pseudo-header values" do
      bad_request(request(path: "/a\nb"), /invalid characters/)
      bad_request(request(path: " /"), /whitespace/)
    end

    it "rejects a host header that does not match :authority" do
      bad_request(request([{"host", "other.com"}]), /host/)
    end

    it "rejects invalid content-length values" do
      ["", "abc", "-1", "1.5", " 1", "+1", "99999999999999999999999"].each do |value|
        bad_request(request([{"content-length", value}]))
      end
    end

    it "rejects conflicting content-length values" do
      bad_request(request([{"content-length", "1"}, {"content-length", "2"}]), /conflicting/)
    end
  end

  describe ".validate_response" do
    it "accepts a valid response" do
      head = HV.validate_response(7_u32, [{":status", "200"}, {"content-type", "text/plain"}, {"content-length", "12"}])
      head.status.should eq(200)
      head.headers.should eq([{"content-type", "text/plain"}, {"content-length", "12"}])
      head.content_length.should eq(12)
    end

    it "accepts informational statuses" do
      HV.validate_response(7_u32, [{":status", "103"}]).status.should eq(103)
    end

    it "rejects a missing :status" do
      bad_response([{"content-type", "text/plain"}], /missing :status/)
      bad_response([] of {String, String}, /missing :status/)
    end

    it "rejects invalid :status values" do
      ["", "20", "2000", "abc", "2x0", " 200"].each do |status|
        bad_response([{":status", status}])
      end
    end

    it "rejects request pseudo-headers in responses" do
      bad_response([{":status", "200"}, {":path", "/"}], /unknown pseudo-header/)
    end

    it "rejects duplicate :status" do
      bad_response([{":status", "200"}, {":status", "204"}], /duplicate/)
    end

    it "rejects :status after regular headers" do
      bad_response([{"server", "x"}, {":status", "200"}], /after regular header/)
    end

    it "rejects malformed regular headers" do
      bad_response([{":status", "200"}, {"Content-Type", "x"}], /invalid header name/)
      bad_response([{":status", "200"}, {"connection", "close"}], /connection-specific/)
      bad_response([{":status", "200"}, {"x", "a\nb"}], /invalid characters/)
    end

    it "rejects invalid content-length" do
      bad_response([{":status", "200"}, {"content-length", "x"}], /content-length/)
    end
  end

  describe ".validate_trailers" do
    it "accepts valid trailers" do
      fields = [{"grpc-status", "0"}, {"grpc-message", ""}]
      HV.validate_trailers(7_u32, fields).should eq(fields)
      HV.validate_trailers(7_u32, [] of {String, String}).should be_empty
    end

    it "rejects pseudo-headers" do
      bad_trailers([{":status", "200"}], /pseudo-header/)
      bad_trailers([{"x", "y"}, {":path", "/"}], /pseudo-header/)
    end

    it "rejects invalid names and values" do
      bad_trailers([{"X-Upper", "1"}], /invalid header name/)
      bad_trailers([{"x", " 1"}], /whitespace/)
      bad_trailers([{"x", "1\r"}], /invalid characters/)
    end

    it "rejects connection-specific headers" do
      bad_trailers([{"transfer-encoding", "chunked"}], /connection-specific/)
    end
  end
end
