# frozen_string_literal: true

# I11 narration-split (lane afnp) — real-HTTP proof of the phase mouth.
#
# Same in-process Async::HTTP::Server + Protocol::Rack::Adapter pattern as
# ingest_falcon_test.rb: a genuine one-shot body over a real socket, a real
# bearer, then the record read back over the same socket asserting the modeled
# phase_kind/phase_at columns landed.

require_relative "../test_helper"
require "async"
require "async/http/server"
require "async/http/client"
require "async/http/endpoint"
require "protocol/rack/adapter"
require "protocol/http/body/buffered"

class IngestPhaseFalconTest < Minitest::Test
  PHASE_PAYLOAD = {
    iteration: { ordinal: 11, name: "narration-split", branch: "main" },
    phase: { kind: "spec-launched", note: "kicked off" }
  }.freeze

  def setup
    conn = Space::Server::App["db.gateway"].connection
    Faker::Internet.unique.clear
    Faker::Number.unique.clear
    [:artifacts, :iterations, :conversations, :spaces, :users].each { |t| conn[t].delete }
    @user = Factory[:user]
    # Machine auth is bearer-only: mint a real bearer for the harness user.
    @bearer, = Space::Server::App["repos.api_tokens_repo"].create(user_id: @user.id, name: "integration")
  end

  def test_phase_ping_over_real_socket_lands_in_the_record
    port     = 49900 + rand(700)
    endpoint = Async::HTTP::Endpoint.parse("http://localhost:#{port}")

    Sync do |task|
      server_task = task.async do
        Async::HTTP::Server.new(Protocol::Rack::Adapter.new(Space::Server::App), endpoint).run
      rescue => _e
        nil
      end

      begin
        # Bounded readiness: yield to the reactor so the server can bind its socket.
        task.sleep(0.3)
        client = Async::HTTP::Client.new(endpoint)

        task.with_timeout(15) do
          headers = Protocol::HTTP::Headers.new([
            ["content-type",  "application/json"],
            ["authorization", "Bearer #{@bearer}"],
            ["x-space-slug",  "phase-falcon"]
          ])
          body = Protocol::HTTP::Body::Buffered.wrap(JSON.generate(PHASE_PAYLOAD))
          response = client.post("/iterations/ingest/phase", headers, body)
          raw      = response.read || ""
          response.finish

          assert_equal 200, response.status
          data = JSON.parse(raw)
          assert_equal "spec-launched", data["iteration"]["phase_kind"]
          assert Time.iso8601(data["iteration"]["phase_at"]),
            "the response carries the server-stamped phase_at"
          assert_equal true, data["phase_applied"]

          # Read the record back over the same socket (bearer read path).
          space_id = Space::Server::App["repos.spaces_repo"].list_visible_to(@user).first.id
          record_headers = Protocol::HTTP::Headers.new([["authorization", "Bearer #{@bearer}"]])
          record_response = client.get("/spaces/#{space_id}/iterations/11", record_headers)
          record_raw      = record_response.read || ""
          record_response.finish

          assert_equal 200, record_response.status
          record = JSON.parse(record_raw)["iteration"]
          assert_equal "spec-launched", record["phase_kind"], "phase_kind landed in the modeled store"
          assert Time.iso8601(record["phase_at"]), "phase_at landed in the modeled store"
        end
      ensure
        client&.close rescue nil
        server_task.stop
      end
    end
  end
end
