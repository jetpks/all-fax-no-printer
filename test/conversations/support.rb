# frozen_string_literal: true

# Minimal bootstrap for conversations unit tests — does NOT boot Hanami.
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)

require "space/server/conversations"
require "minitest/autorun"
