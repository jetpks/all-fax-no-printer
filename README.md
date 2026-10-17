# all-fax-no-printer

A Ruby/Hanami application for exploring and sharing AI agent sessions. Watch a
captured session land live over SSE, browse the persisted transcript with rich
markdown and code rendering, and publish conversations read-only.

## Lineage

This repo began as a fork of `jetpks/chat_share`, lived on as the `server/`
subtree of the `jetpks/space-architect` monorepo, and was extracted into this
standalone repository with `git filter-repo --subdirectory-filter server` —
git history is preserved. Pre-extraction (monorepo) history and changelog live
in [jetpks/space-architect](https://github.com/jetpks/space-architect).
The application itself is still `space-server` internally (`Space::Server`
modules, `bin/serve`, `space_server_*` database names) — only the repository
changed.

## Feature areas

The UI leads with spaces: `/` and `/spaces` are the spaces index,
`/conversations` lists captured sessions across spaces.

- **Spaces** — architect-loop space directories (iterations, artifacts,
  decisions) browsable at `/spaces/:id`; a space's show page interleaves its
  iterations with its captured conversations on one timeline. Conversations
  not filed into a space are grouped by working directory under the index's
  "Unspaced" section.
- **Conversations** — every captured agent session lands as a conversation
  (index at `/conversations`, show at `/conversations/:id`, publish toggle,
  delete). A capture still landing mounts a live view on its show page while
  its status is `pending` or `live`. The parser is the pi harness stream
  (`lib/space/server/normalizer/pi.rb`); a body that parses but yields no
  recognizable events fails the conversation visibly instead of leaving it
  `live` forever (pi's first-line classification doesn't claim fails the
  conversation — there is no fallback parser).
- **Live streaming (SSE)** — `GET /conversations/:id/stream` replays the
  Redis backlog honoring the client's `Last-Event-ID` header, then fans out
  live with a 15s heartbeat. Event vocabulary: `session_init` (the capture is
  live), `message_start`, `block_open`, `text_delta`, `tool_args_delta`,
  `block_close`, `message_complete`, `tool_result`, and the terminal
  `conversation_complete` (the client closes the stream on it).

## Setup

```sh
bundle install
npm install
```

Credentials are managed via Hanami's encrypted credentials store:

```sh
bin/credentials edit   # opens $EDITOR; set github_oauth_id/secret and db url
```

## Run

```sh
bin/dev   # starts web server (:3000) and Vite (:3036)
```

## Test

```sh
bundle exec rake test  # Ruby suite
npm test               # Vitest (TypeScript/component tests)
npm run check          # TypeScript type check
```

## Ingest mouth

`POST /conversations/ingest` accepts a `pi --mode json` JSONL body and lands
it as a conversation. The first line of a session's first POST must be the
`{"type":"session",...}` record; it may reappear in later chunks —
re-processing it is a metadata no-op.

Machine pushes authenticate with `Authorization: Bearer <token>`: per-user
`sat_` tokens are the primary path; the shared `INGEST_TOKEN` remains as
legacy back-compat. No bearer → `401`.

### Optional headers (applied idempotently per POST)

| Header                     | Effect                                                                                             |
|----------------------------|----------------------------------------------------------------------------------------------------|
| `X-Space-Slug`             | Find-or-create the authenticated user's space and file the conversation under it; absent → the conversation is grouped by working directory instead |
| `X-Parent-Session-Id`      | Marks the conversation as a subagent transcript of the session with that id                          |
| `X-Agent-Role`             | Role tag (architect/builder/judge/narrator/coordinator/…); absent = interactive                       |
| `X-Agent-Name`             | Agent display name                                                                                   |
| `X-Session-Complete: true` | Terminal: the conversation's status becomes `completed` and a terminal `conversation_complete` SSE event is emitted; absent → status `live` |

### Idempotency

The pi session record's `id` is the conversation key — find-or-create by
`(user_id, session_id)`. Each applied pi record's `id` is tracked on the
conversation, and an already-applied record is skipped entirely: no message
write and no Redis event, so whole-file re-sends, chunk retries, and
reconnect replays land zero duplicates.

The response is `202` JSON `{id, session_id, status, events}` (plus `error`
when the body parses but yields no recognizable events — a visible failure,
never silent live-forever).

### Per-user API tokens (primary)

Each user mints named tokens at **Api Tokens** (`/api_tokens` — session
sign-in required; bearer is for the data API, not this page). Minting takes
only a name: the server generates the secret (`sat_` + 64 hex chars, from
`SecureRandom.hex(32)`), shows it **exactly once** in the mint response, and
persists only its SHA-256 hex digest in `api_tokens.token_hash` (unique
index). The plaintext is never stored and cannot be recovered — the mint view
shows it exactly once, with a copy-to-clipboard affordance, so store it then.
Revocation is soft (`revoked_at` stamp), so mint history stays auditable.

Requests carrying `Authorization: Bearer <token>` authenticate **as the
token's owner** on the bearer endpoint (`POST /conversations/ingest`);
ownership and visibility then flow per-user with no further configuration.
Lookup is a unique-index hit on the presented token's SHA-256 digest — never
a linear scan or plaintext comparison. Every use touches `last_used_at` on
the token row. Failed bearer attempts warn-log request path and outcome only
— never token material.

### Legacy global INGEST_TOKEN (back-compat)

| Env var             | Description                                      |
|---------------------|--------------------------------------------------|
| `INGEST_TOKEN`      | Secret bearer token for `POST /conversations/ingest` |
| `INGEST_USER_ID`    | Integer user ID that ingested conversations are owned by (plain config, not a secret) |

When both are set, requests carrying `Authorization: Bearer <INGEST_TOKEN>` are
authenticated as the configured user and bypass CSRF (machine pushes carry no
session cookie). Browser/cookie requests are unaffected and continue to
enforce CSRF normally. Deployed CLI setups configured this way keep working
unchanged; per-user tokens take precedence when a presented bearer matches
one.

## Deploy

Production serves from `studio.slush.systems` via the `deploy/ansible` role —
see [docs/how-to/deploy-on-the-studio.md](docs/how-to/deploy-on-the-studio.md).

## Retention & Cleanup (v1: manual)

**Redis conversation streams.** The `conversation:<id>` display stream
self-evicts: every `XADD` refreshes the key's TTL to `StreamKey::TTL_SECONDS`
(1800s / 30 minutes), so a stream with no further writes simply expires. No
operator action needed.

**Postgres growth.** `conversations` and `messages` rows are never deleted by
the app — there is no rake task, cron, or GC job. If a table needs pruning,
that's a manual `DELETE` an operator issues directly; no tooling ships for it
in v1.
