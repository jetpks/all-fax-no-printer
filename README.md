# all-fax-no-printer

A Ruby/Hanami application for exploring and sharing AI agent runs. Watch a
streaming trace land live over SSE, browse the persisted transcript with rich
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

- **Runs** — streaming trace ingest over SSE (`POST /runs` + `POST
  /runs/:id/ingest` push traces, `/runs/:id/stream` renders them live).
  Ingest answers `202` with `{id, status, events}` — plus `error` when the
  stream failed — and a body that parses but yields no recognizable events
  fails the run visibly instead of leaving it `live` forever. The pi harness
  stream is the one parser (`lib/space/server/normalizer/pi.rb`); a stream
  pi's first-line classification doesn't claim fails the run (there is no
  fallback parser).
- **Conversations** — ingested runs persist incrementally as browsable
  conversations (index, show, publish toggle, delete). Publishing follows
  the published/owned semantics: owners and viewers of a published
  conversation see the whole transcript; everyone else sees only
  individually-published messages.
- **Spaces** — importing architect-loop space directories (iterations,
  artifacts, transcripts) for browsing.

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

## Ingest Token Auth

Machine pushes (e.g. from the CLI dispatch harness) authenticate with a bearer
token. Per-user API tokens are the primary path; the shared `INGEST_TOKEN`
remains as legacy back-compat.

### Per-user API tokens (primary)

Each user mints named tokens at **API tokens** (`/api_tokens` — session sign-in
required; bearer is for the data API, not this page). Minting takes only a
name: the server generates the secret (`sat_` + 64 hex chars, from
`SecureRandom.hex(32)`), shows it **exactly once** in the mint response, and
persists only its SHA-256 hex digest in `api_tokens.token_hash` (unique index).
The plaintext is never stored and cannot be recovered — the mint view shows it
exactly once, with a copy-to-clipboard affordance, so store it then.
Revocation is soft (`revoked_at` stamp), so mint history stays auditable.

Requests carrying `Authorization: Bearer <token>` authenticate **as the
token's owner** on the bearer endpoints (`POST /runs`, `POST
/runs/:id/ingest`); ownership and visibility then flow per-user with no
further configuration. Lookup is a unique-index hit on the presented token's
SHA-256 digest — never a linear scan or plaintext comparison. Every use
touches `last_used_at` on the token row. Failed bearer attempts warn-log
request path and outcome only — never token material.

### Legacy global INGEST_TOKEN (back-compat)

| Env var             | Description                                      |
|---------------------|--------------------------------------------------|
| `INGEST_TOKEN`      | Secret bearer token for `POST /runs` and `POST /runs/:id/ingest` |
| `INGEST_USER_ID`    | Integer user ID that ingested runs are owned by (plain config, not a secret) |

When both are set, requests carrying `Authorization: Bearer <INGEST_TOKEN>` are
authenticated as the configured user and bypass CSRF (machine pushes carry no
session cookie). Browser/cookie requests are unaffected and continue to
enforce CSRF normally. Deployed CLI setups configured this way keep working
unchanged; per-user tokens take precedence when a presented bearer matches
one.

## Deploy

Production runs on `studio.slush.systems` via the `deploy/ansible` role — see
[docs/how-to/deploy-on-the-studio.md](docs/how-to/deploy-on-the-studio.md).

## Retention & Cleanup (v1: manual)

**Redis run streams.** The `run:<id>` display stream self-evicts: every
`XADD` refreshes the key's TTL to `StreamKey::TTL_SECONDS` (1800s / 30
minutes), so a stream with no further writes simply expires. No operator
action needed.

**Postgres growth.** `runs`, `conversations`, and `messages` rows are never
deleted by the app — there is no rake task, cron, or GC job. If a table needs
pruning, that's a manual `DELETE` an operator runs directly; no tooling ships
for it in v1.