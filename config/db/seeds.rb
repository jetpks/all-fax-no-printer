# This seeds file should create the database records required to run the app.
#
# The code should be idempotent so that it can be executed at any time.

# No seeds are currently required: the legacy service-account row died with
# the shared global-token fallback — machine auth is per-user sat_ tokens only.
# The file stays loadable because `hanami db prepare` always runs it.
