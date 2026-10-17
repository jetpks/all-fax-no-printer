# frozen_string_literal: true

require "falcon/environment/rack"
require "async/service/managed/service"
require "async/service/managed/environment"

# Web service: serves the Rack app (config.ru) on plain HTTP.
#
# Falcon::Environment::Rack includes Application which overrides endpoint to a Unix IPC socket
# (designed for virtual-host reverse-proxy topology). We override endpoint to bind plain TCP HTTP
# so both the web service and the boot-smoke probe work without a separate proxy layer.
service "architect.web" do
  include Falcon::Environment::Rack

  # FALCON_BIND: container deploys override (podman's PublishPort forwards to
  # the container's eth0, not its localhost — the image sets 0.0.0.0). Dev/test
  # default unchanged.
  endpoint { Async::HTTP::Endpoint.parse(ENV.fetch("FALCON_BIND", "http://localhost:3000")) }
end
