# frozen_string_literal: true

require "hanami/boot"

# Transport security wired at the rackup layer rather than config/app.rb because
# Hanami 2.3 config.middleware.use appends after framework middleware (slice.rb:1088),
# so Rack::Session::Cookie would precede these. config.ru wrapping is truly outermost.
_settings = Space::Server::App["settings"]

use HanamiForceSSL::Middleware,
  redirect:   _settings.force_ssl ? { exclude: ->(req) { req.path == "/up" } } : false,
  assume_ssl: _settings.assume_ssl

use Rack::Protection::HostAuthorization,
  permitted_hosts: _settings.permitted_hosts,
  allow_if:        ->(env) { env["PATH_INFO"] == "/up" }

# Static vite assets. Hanami does not serve public/ in production — on the
# studio deploy Caddy served /vite/* from disk; containerized, the bundles
# ship inside the image and the app serves them itself. Rack::Static maps
# the /vite prefix onto public/vite and falls through to the app when no
# file matches (Rack::Files itself is a standalone app in rack 3.2, not
# (app, root) middleware).
use Rack::Static, urls: ["/vite"], root: File.expand_path("public", __dir__)

run Hanami.app
