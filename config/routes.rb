# frozen_string_literal: true

module Space
  module Server
    class Routes < Hanami::Routes
      mount HanamiHealthcheck::Endpoint.new, at: "/up"

      # Auth — OmniAuth callback (GET for redirect, POST for form submission)
      get  "/auth/:provider/callback", to: "sessions.create"
      post "/auth/:provider/callback", to: "sessions.create"
      get  "/auth/failure",            to: "sessions.failure"

      # Logout — both GET (link) and DELETE (form)
      get    "/logout", to: "sessions.destroy"
      delete "/logout", to: "sessions.destroy"

      # Root leads with spaces (same action, two paths)
      root to: "spaces.index"
      get  "/spaces", to: "spaces.index"

      # Spaces
      get "/spaces/:id",                      to: "spaces.show"
      get "/spaces/:id/stream",               to: "spaces.stream"
      get "/spaces/:id/stream/history",        to: "spaces.stream_history"
      get "/spaces/:id/artifacts/:artifact_id", to: "spaces.artifact"

      # Iterations — structured-record mouths (bearer); record read added by lane `surface`
      post "/iterations/ingest/freeze",      to: "iterations.ingest_freeze"
      post "/iterations/ingest/lane",        to: "iterations.ingest_lane"
      post "/iterations/ingest/verdict",     to: "iterations.ingest_verdict"
      post "/iterations/ingest/integration", to: "iterations.ingest_integration"

      # Conversations
      get  "/conversations",            to: "conversations.index"
      get  "/conversations/:id",                to: "conversations.show"
      get  "/conversations/:id/stream",         to: "conversations.stream"
      get  "/conversations/:id/stream/history", to: "conversations.stream_history"
      post "/conversations/ingest",     to: "conversations.ingest"
      patch  "/conversations/:id/publish", to: "conversations.publish"
      delete "/conversations/:id",         to: "conversations.destroy"

      # Messages (shallow member — publish toggle)
      patch "/messages/:id/publish", to: "messages.publish"

      # API tokens (per-user machine auth — mint/revoke; session-auth'd UI,
      # POST …/delete for the revoke)
      get  "/api_tokens",            to: "api_tokens.index"
      get  "/api_tokens/new",        to: "api_tokens.new"
      post "/api_tokens",            to: "api_tokens.create"
      post "/api_tokens/:id/delete", to: "api_tokens.destroy"
    end
  end
end
