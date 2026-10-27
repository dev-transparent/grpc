require "./client_helper"

private def parse(json : String) : GRPC::ServiceConfig
  GRPC::ServiceConfig.parse(json)
end

private def invalid(json : String, message : Regex) : Nil
  expect_raises(GRPC::ServiceConfig::Error, message) { parse(json) }
end

private def method_config(body : String) : String
  %({"methodConfig": [{"name": [{"service": "s"}], #{body}}]})
end

private RETRY = %("maxAttempts": 3, "initialBackoff": "0.1s", "maxBackoff": "1s", "backoffMultiplier": 2, "retryableStatusCodes": ["UNAVAILABLE"])

describe GRPC::ServiceConfig do
  it "parses method configs" do
    config = parse(<<-JSON)
      {
        "methodConfig": [
          {"name": [{"service": "pkg.Svc", "method": "Get"}], "timeout": "1.5s", "waitForReady": true,
           "maxRequestMessageBytes": 1024, "maxResponseMessageBytes": "2048",
           "retryPolicy": {"maxAttempts": 10, "initialBackoff": "0.1s", "maxBackoff": "2s",
                           "backoffMultiplier": 1.5, "retryableStatusCodes": ["UNAVAILABLE", 4, "aborted"]}},
          {"name": [{"service": "pkg.Svc"}], "hedgingPolicy": {"maxAttempts": 3, "hedgingDelay": "0.05s",
                                                              "nonFatalStatusCodes": ["INTERNAL"]}},
          {"name": [{}], "timeout": "10s"}
        ],
        "retryThrottling": {"maxTokens": 10, "tokenRatio": 0.1234}
      }
      JSON

    get = config.method_config("/pkg.Svc/Get").not_nil!
    get.timeout.should eq 1.5.seconds
    get.wait_for_ready.should be_true
    get.max_request_message_bytes.should eq 1024
    get.max_response_message_bytes.should eq 2048
    retry = get.retry_policy.not_nil!
    retry.max_attempts.should eq 5 # capped
    retry.initial_backoff.should eq 100.milliseconds
    retry.max_backoff.should eq 2.seconds
    retry.backoff_multiplier.should eq 1.5
    retry.retryable_status_codes.should eq Set{GRPC::StatusCode::Unavailable, GRPC::StatusCode::DeadlineExceeded, GRPC::StatusCode::Aborted}

    hedging = config.method_config("/pkg.Svc/Other").not_nil!.hedging_policy.not_nil!
    {hedging.max_attempts, hedging.hedging_delay, hedging.non_fatal_status_codes}
      .should eq({3, 50.milliseconds, Set{GRPC::StatusCode::Internal}})

    config.method_config("/other.Svc/X").not_nil!.timeout.should eq 10.seconds
    throttling = config.retry_throttling.not_nil!
    {throttling.max_tokens, throttling.token_ratio}.should eq({10, 0.123})
  end

  it "computes retry backoff with jitter" do
    policy = parse(method_config(%("retryPolicy": {#{RETRY}}))).method_config("/s/m").not_nil!.retry_policy.not_nil!
    100.times do
      policy.backoff(1).should be_close(100.milliseconds, 20.milliseconds + 1.microsecond)
      policy.backoff(2).should be_close(200.milliseconds, 40.milliseconds + 1.microsecond)
      policy.backoff(10).should be_close(1.second, 200.milliseconds + 1.microsecond)
    end
  end

  it "parses durations" do
    GRPC::ServiceConfig.parse_duration("1s").should eq 1.second
    GRPC::ServiceConfig.parse_duration("0.000000001s").should eq 1.nanosecond
    GRPC::ServiceConfig.parse_duration("2.5s").should eq 2.5.seconds
    {"1", "1.s", "-1s", "1.0000000001s", "s", "1m"}.each do |bad|
      GRPC::ServiceConfig.parse_duration(bad).should be_nil
    end
  end

  it "selects load balancing policies" do
    parse(%({"loadBalancingConfig": [{"unknown_policy": {}}, {"round_robin": {}}]})).load_balancing_policy.should eq "round_robin"
    parse(%({"loadBalancingPolicy": "ROUND_ROBIN"})).load_balancing_policy.should eq "round_robin"
    parse("{}").load_balancing_policy.should be_nil
  end

  it "rejects invalid configs" do
    invalid("[]", /JSON object/)
    invalid("{", /Invalid service config JSON/)
    invalid(%({"methodConfig": {}}), /methodConfig must be an array/)
    invalid(%({"methodConfig": [{"name": [{"method": "m"}]}]}), /requires a service/)
    invalid(%({"methodConfig": [{"name": [{"service": "s"}]}, {"name": [{"service": "s"}]}]}), /Duplicate/)
    invalid(method_config(%("timeout": "1")), /invalid duration/)
    invalid(method_config(%("timeout": 1)), /duration string/)
    invalid(method_config(%("waitForReady": "yes")), /boolean/)
    invalid(method_config(%("maxRequestMessageBytes": -1)), /non-negative/)
    invalid(method_config(%("retryPolicy": {#{RETRY.sub("3", "1")}})), /greater than 1/)
    invalid(method_config(%("retryPolicy": {#{RETRY.sub(%("maxAttempts": 3, ), "")}})), /maxAttempts is required/)
    invalid(method_config(%("retryPolicy": {#{RETRY.sub("0.1s", "0s")}})), /initialBackoff must be > 0/)
    invalid(method_config(%("retryPolicy": {#{RETRY.sub("\"backoffMultiplier\": 2", "\"backoffMultiplier\": 0")}})), /backoffMultiplier/)
    invalid(method_config(%("retryPolicy": {#{RETRY.sub(%(["UNAVAILABLE"]), "[]")}})), /must not be empty/)
    invalid(method_config(%("retryPolicy": {#{RETRY.sub("UNAVAILABLE", "NOPE")}})), /invalid status code/)
    invalid(method_config(%("retryPolicy": {#{RETRY}}, "hedgingPolicy": {"maxAttempts": 2})), /mutually exclusive/)
    invalid(method_config(%("hedgingPolicy": {"maxAttempts": 2, "hedgingDelay": "x"})), /invalid duration/)
    invalid(%({"retryThrottling": {"maxTokens": 0, "tokenRatio": 1}}), /maxTokens/)
    invalid(%({"retryThrottling": {"maxTokens": 1001, "tokenRatio": 1}}), /maxTokens/)
    invalid(%({"retryThrottling": {"maxTokens": 10, "tokenRatio": 0.0001}}), /tokenRatio/)
    invalid(%({"loadBalancingConfig": [{"nope": {}}]}), /No supported policy/)
    invalid(%({"loadBalancingConfig": [{"round_robin": {}, "pick_first": {}}]}), /exactly one policy/)
    invalid(%({"loadBalancingPolicy": "nope"}), /Unsupported loadBalancingPolicy/)
  end

  it "raises for an invalid config given to a channel" do
    expect_raises(GRPC::ServiceConfig::Error) { GRPC::Channel.new("localhost:1", service_config: %({"methodConfig": 1})) }
  end

  describe "applied to calls" do
    it "applies the timeout and keeps the shorter deadline" do
      server = ClientSpec::TestServer.new
      config = %({"methodConfig": [{"name": [{"service": "grpc_spec.TestService", "method": "Unary"}], "timeout": "2s"}]})
      channel = GRPC::Channel.new(server.address, service_config: config)
      client = ClientSpec::Client.new(channel)
      begin
        GRPCSpec.within do
          client.unary(ClientSpec::EchoRequest.new).timeout_ms.should be_close(2000, 300)
          client.unary(ClientSpec::EchoRequest.new, deadline: 30.seconds).timeout_ms.should be_close(2000, 300)
          client.unary(ClientSpec::EchoRequest.new, deadline: 1.second).timeout_ms.should be_close(1000, 300)
          # Other methods are not affected.
          client.server_stream(ClientSpec::EchoRequest.new(count: 1)).first.timeout_ms.should eq -1
          GRPCSpec.expect_status(GRPC::StatusCode::DeadlineExceeded) do
            GRPC::Channel.new(server.address, service_config: config.sub("2s", "0.1s")).tap do |short|
              ClientSpec::Client.new(short).unary(ClientSpec::EchoRequest.new(sleep_ms: 2000))
            end
          end
        end
      ensure
        channel.shutdown
        server.close
      end
    end

    it "applies waitForReady unless the call overrides it" do
      port = ClientSpec.free_port
      config = %({"methodConfig": [{"name": [{"service": "grpc_spec.TestService"}], "waitForReady": true}]})
      channel = GRPC::Channel.new("127.0.0.1:#{port}", service_config: config, backoff: ClientSpec::FAST_BACKOFF)
      client = ClientSpec::Client.new(channel)
      server = nil
      GRPCSpec.within do
        queued = GRPCSpec.async { client.unary(ClientSpec::EchoRequest.new(message: "waited")).message }
        ClientSpec.wait_until { channel.state.transient_failure? }
        GRPCSpec.expect_status(GRPC::StatusCode::Unavailable) do
          client.with_options(wait_for_ready: false).unary(ClientSpec::EchoRequest.new)
        end
        server = ClientSpec::TestServer.new(port: port)
        GRPCSpec.await(queued).should eq "waited"
      end
      channel.shutdown
      server.try &.close
    end

    it "enforces message size limits" do
      server = ClientSpec::TestServer.new
      config = %({"methodConfig": [{"name": [{"service": "grpc_spec.TestService"}],
                  "maxRequestMessageBytes": 1000, "maxResponseMessageBytes": 2000}]})
      channel = GRPC::Channel.new(server.address, service_config: config)
      client = ClientSpec::Client.new(channel)
      begin
        GRPCSpec.within do
          client.unary(ClientSpec::EchoRequest.new(payload: Bytes.new(900), response_size: 1900))
          error = GRPCSpec.expect_status(GRPC::StatusCode::ResourceExhausted) do
            client.unary(ClientSpec::EchoRequest.new(payload: Bytes.new(1200)))
          end
          error.status.message.should contain "Sent message larger than max"
          GRPCSpec.expect_status(GRPC::StatusCode::ResourceExhausted) do
            client.unary(ClientSpec::EchoRequest.new(response_size: 3000))
          end
          # The client's own (smaller) limit wins.
          GRPCSpec.expect_status(GRPC::StatusCode::ResourceExhausted) do
            client.with_options(max_receive_message_size: 500).unary(ClientSpec::EchoRequest.new(response_size: 1000))
          end
        end
      ensure
        channel.shutdown
        server.close
      end
    end

    it "uses the resolver's config, falling back to the default and keeping the last valid one" do
      resolver = GRPC::ManualResolver.new("spec-config")
      server = ClientSpec::TestServer.new
      default = %({"methodConfig": [{"name": [{}], "timeout": "5s"}]})
      channel = GRPC::Channel.new("spec-config:///svc", resolver: resolver, service_config: default)
      client = ClientSpec::Client.new(channel)
      begin
        GRPCSpec.within do
          resolver.update([server.address])
          client.unary(ClientSpec::EchoRequest.new).timeout_ms.should be_close(5000, 500)

          resolver.update([server.address], service_config: %({"methodConfig": [{"name": [{}], "timeout": "3s"}]}))
          ClientSpec.wait_until { (client.unary(ClientSpec::EchoRequest.new).timeout_ms - 3000).abs < 500 }

          # Invalid configs are ignored once a valid one was received.
          resolver.update([server.address], service_config: %({"methodConfig": 7}))
          sleep 50.milliseconds
          client.unary(ClientSpec::EchoRequest.new).timeout_ms.should be_close(3000, 500)
          channel.service_config.not_nil!.method_config("/a/b").not_nil!.timeout.should eq 3.seconds
        end
      ensure
        channel.shutdown
        server.close
      end
    end

    it "ignores resolver configs with disable_service_config_lookup" do
      resolver = GRPC::ManualResolver.new("spec-noconfig")
      server = ClientSpec::TestServer.new
      resolver.update([server.address], service_config: %({"methodConfig": [{"name": [{}], "timeout": "3s"}]}))
      channel = GRPC::Channel.new("spec-noconfig:///svc", resolver: resolver, disable_service_config_lookup: true)
      begin
        GRPCSpec.within { ClientSpec::Client.new(channel).unary(ClientSpec::EchoRequest.new).timeout_ms.should eq -1 }
      ensure
        channel.shutdown
        server.close
      end
    end

    it "fails calls when the first config from the resolver is invalid" do
      resolver = GRPC::ManualResolver.new("spec-badconfig")
      server = ClientSpec::TestServer.new
      resolver.update([server.address], service_config: %({"loadBalancingConfig": [{"nope": {}}]}))
      channel = GRPC::Channel.new("spec-badconfig:///svc", resolver: resolver)
      begin
        GRPCSpec.within do
          error = GRPCSpec.expect_status(GRPC::StatusCode::Unavailable) { ClientSpec::Client.new(channel).unary(ClientSpec::EchoRequest.new) }
          error.status.message.should contain "Invalid service config"
          resolver.update([server.address])
          ClientSpec.wait_until { ClientSpec::Client.new(channel).unary(ClientSpec::EchoRequest.new(message: "ok")).message == "ok" rescue false }
        end
      ensure
        channel.shutdown
        server.close
      end
    end
  end
end
