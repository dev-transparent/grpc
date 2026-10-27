require "../grpc"
require "./health/grpc/health/v1/health_grpc.pb"

module GRPC
  # An implementation of the standard gRPC health checking protocol
  # (`grpc.health.v1.Health`).
  #
  # ```
  # require "grpc/health"
  #
  # health = GRPC::HealthService.new
  # server.handle(health)
  # health.set_status("helloworld.Greeter", :serving)
  # ```
  #
  # The overall server health is registered under the empty service name and
  # starts as `SERVING`.
  class HealthService < Grpc::Health::V1::Health::Service
    alias ServingStatus = Grpc::Health::V1::HealthCheckResponse::ServingStatus
    alias Response = Grpc::Health::V1::HealthCheckResponse

    @statuses = {"" => ServingStatus::SERVING}
    @watchers = {} of String => Array(::Channel(ServingStatus))
    @mutex = Mutex.new

    # Sets the status of *service* and notifies watchers.
    def set_status(service : String, status : ServingStatus) : Nil
      @mutex.synchronize { @statuses[service] = status }
      notify(service, status)
    end

    # Removes *service*; watchers see `SERVICE_UNKNOWN`.
    def clear_status(service : String) : Nil
      @mutex.synchronize { @statuses.delete(service) }
      notify(service, ServingStatus::SERVICE_UNKNOWN)
    end

    # Marks every service as `NOT_SERVING`, e.g. before shutting down.
    def shutdown : Nil
      @mutex.synchronize { @statuses.keys }.each { |service| set_status(service, :not_serving) }
    end

    def status(service : String) : ServingStatus?
      @mutex.synchronize { @statuses[service]? }
    end

    def check(request, context)
      status = self.status(request.service) || raise Error.new(:not_found, "Unknown service #{request.service.inspect}")
      Response.new(status: status)
    end

    def list(request, context)
      statuses = @mutex.synchronize { @statuses.dup }
      Grpc::Health::V1::HealthListResponse.new(statuses: statuses.transform_values { |status| Response.new(status: status) })
    end

    def watch(request, responses, context)
      service = request.service
      channel = ::Channel(ServingStatus).new(16)
      @mutex.synchronize { (@watchers[service] ||= [] of ::Channel(ServingStatus)) << channel }
      context.on_cancel { channel.close }
      begin
        last = status(service) || ServingStatus::SERVICE_UNKNOWN
        responses.send(Response.new(status: last))
        while current = channel.receive?
          next if current == last
          last = current
          responses.send(Response.new(status: current))
        end
      ensure
        @mutex.synchronize { @watchers[service]?.try &.delete(channel) }
      end
    end

    private def notify(service : String, status : ServingStatus) : Nil
      watchers = @mutex.synchronize { @watchers[service]?.try(&.dup) || [] of ::Channel(ServingStatus) }
      watchers.each do |channel|
        select
        when channel.send(status)
        else
          # The watcher is far behind; it will catch up on a later update.
        end
      end
    end
  end
end
