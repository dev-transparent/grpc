require "./spec_helper"
require "../src/grpc/health"

private alias Health = Grpc::Health::V1

describe GRPC::HealthService do
  it "reports, lists and streams service health" do
    health = GRPC::HealthService.new
    server = GRPC::Server.new
    server.handle(health)
    address = server.bind("127.0.0.1:0").as(Socket::IPAddress)
    server.start
    client = Health::Health::Client.new("127.0.0.1:#{address.port}")

    begin
      client.check(Health::HealthCheckRequest.new).status.should eq(Health::HealthCheckResponse::ServingStatus::SERVING)

      expect_raises(GRPC::Error, /NotFound/) { client.check(Health::HealthCheckRequest.new(service: "svc")) }

      health.set_status("svc", :not_serving)
      client.check(Health::HealthCheckRequest.new(service: "svc")).status.should eq(Health::HealthCheckResponse::ServingStatus::NOT_SERVING)
      client.list(Health::HealthListRequest.new).statuses.keys.sort.should eq(["", "svc"])

      watch = client.watch(Health::HealthCheckRequest.new(service: "svc"), deadline: 5.seconds)
      watch.receive?.try(&.status).should eq(Health::HealthCheckResponse::ServingStatus::NOT_SERVING)
      health.set_status("svc", :serving)
      watch.receive?.try(&.status).should eq(Health::HealthCheckResponse::ServingStatus::SERVING)
      health.clear_status("svc")
      watch.receive?.try(&.status).should eq(Health::HealthCheckResponse::ServingStatus::SERVICE_UNKNOWN)
      watch.cancel
    ensure
      client.close
      server.close
    end
  end
end
