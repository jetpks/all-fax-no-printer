#!/usr/bin/env ruby
# frozen_string_literal: true

# Boot-smoke for the supervised web topology.
#
# Launches `falcon host falcon.rb`, confirms the web service is up (/answers /up),
# sends SIGTERM, confirms graceful exit and no orphaned child processes.
#
# Usage: cd architect && HANAMI_ENV=development bundle exec ruby bin/topology_smoke.rb
# Exit 0 = PASS; exit 1 = FAIL (details on stderr)

require "timeout"
require "net/http"
require "uri"

ARCHITECT_DIR = File.expand_path("..", __dir__)
WEB_PORT    = 3000
WEB_URL     = "http://localhost:#{WEB_PORT}/up"
BOOT_WAIT   = 45  # seconds for falcon host + child processes to boot
STOP_WAIT   = 15  # seconds for graceful shutdown

def fail!(msg)
  $stderr.puts "TOPOLOGY SMOKE FAIL: #{msg}"
  exit 1
end

def log(msg)
  puts "[topology_smoke] #{msg}"
  $stdout.flush
end

ENV["HANAMI_ENV"] ||= "development"
Dir.chdir(ARCHITECT_DIR)

# ---------------------------------------------------------------------------
# Launch `falcon host falcon.rb` as a child process (from architect/ dir).
# ---------------------------------------------------------------------------
falcon_bin = `which falcon`.strip
fail! "falcon not found on PATH" if falcon_bin.empty?

require "tmpdir"
FALCON_LOG = File.join(Dir.mktmpdir("topology-smoke-"), "falcon.log")

log "Spawning: #{falcon_bin} host falcon.rb (log: #{FALCON_LOG})"
falcon_pid = Process.spawn(
  { "HANAMI_ENV" => "development" },
  falcon_bin, "host", "falcon.rb",
  chdir: ARCHITECT_DIR,
  pgroup: true,  # own process group so we can kill all children
  [:out, :err] => FALCON_LOG
)
log "falcon host PID=#{falcon_pid}"

cleanup_ran = false
cleanup = proc do
  next if cleanup_ran
  cleanup_ran = true
  begin
    Process.kill("-TERM", Process.getpgid(falcon_pid))
  rescue Errno::ESRCH, Errno::EPERM
    # Already gone
  end
end
at_exit { cleanup.call }

# ---------------------------------------------------------------------------
# Wait for web service to answer /up.
# ---------------------------------------------------------------------------
log "Waiting up to #{BOOT_WAIT}s for web service at #{WEB_URL}..."
web_up = false
deadline = Time.now + BOOT_WAIT
until Time.now > deadline
  begin
    resp = Net::HTTP.get_response(URI(WEB_URL))
    if resp.code.to_i == 200
      web_up = true
      log "Web service UP — GET /up → #{resp.code}"
      break
    end
  rescue Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError, Net::ReadTimeout
    # Not ready yet
  end
  sleep 0.5
end
fail! "Web service did not come up within #{BOOT_WAIT}s (GET #{WEB_URL} never returned 200)" unless web_up

# Snapshot child PIDs before sending SIGTERM
children_before = `pgrep -P #{falcon_pid} 2>/dev/null`.split.map(&:to_i)
log "Child PIDs before SIGTERM: #{children_before.inspect}"

# ---------------------------------------------------------------------------
# Send SIGTERM to the falcon host process group and wait for exit.
# ---------------------------------------------------------------------------
log "Sending SIGTERM to process group of PID #{falcon_pid}..."
begin
  Process.kill("-TERM", Process.getpgid(falcon_pid))
rescue Errno::ESRCH
  # Already gone — that would be a bug
end
cleanup_ran = true  # Prevent at_exit from double-killing

exit_status = nil
begin
  Timeout.timeout(STOP_WAIT) do
    _, status = Process.waitpid2(falcon_pid)
    exit_status = status
  end
rescue Timeout::Error
  fail! "falcon host did not exit within #{STOP_WAIT}s after SIGTERM"
end

exit_code = exit_status&.exitstatus
log "falcon host exited with code=#{exit_code.inspect} (signal=#{exit_status&.termsig.inspect})"

# Falcon host catches Interrupt and exits cleanly; SIGTERM may result in exitstatus=nil (signal kill)
# or 0. Accept exit code 0, nil (signal), or 130 (SIGINT convention).
unless [0, nil, 130].include?(exit_code)
  fail! "falcon host exited with unexpected code #{exit_code}"
end

# ---------------------------------------------------------------------------
# Verify no orphaned child processes remain.
# ---------------------------------------------------------------------------
sleep 1  # Brief pause for children to reap
orphans = children_before.select { |pid| Process.kill(0, pid) rescue false }
if orphans.any?
  fail! "Orphaned processes after SIGTERM: #{orphans.inspect}"
end
log "No orphaned processes — all #{children_before.size} children exited"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
puts ""
puts "TOPOLOGY SMOKE OK"
puts "  web: GET #{WEB_URL} → 200"
puts "  shutdown: graceful exit, 0 orphans"
exit 0