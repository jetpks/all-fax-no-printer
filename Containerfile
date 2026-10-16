# syntax=docker/dockerfile:1

# all-fax-no-printer — the space-server: web + import/executor/consumer
# workers in one supervised falcon topology (bin/serve → falcon.rb).
#
# No secrets are baked in: everything arrives at runtime via environment
# (DATABASE_URL, REDIS_URL, SESSION_SECRET, INGEST_TOKEN, ...). Production
# never wires the credentials key — config/credentials.yml.enc stays inert.

# ── Stage 1: frontend assets (vite build; node is build-time only) ──────────
FROM docker.io/library/node:24-slim AS frontend
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-fund --no-audit
# vite-plugin-ruby reads the Ruby-side vite config (config/vite.json) to find
# entrypoints and the output dir — it rides along with the ts configs for
# path aliases.
COPY vite.config.ts tsconfig.json tsconfig.app.json tsconfig.node.json ./
COPY config/vite.json config/vite.json
COPY app/frontend app/frontend
# Production output lands in public/vite (manifest + hashed assets), the same
# place vite-hanami resolves at runtime under RACK_ENV=production.
RUN npm run build

# ── Stage 2: gems (compiler toolchain stays behind) ─────────────────────────
FROM docker.io/library/ruby:4.0.5-slim AS gems
WORKDIR /app
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      build-essential libpq-dev libyaml-dev \
    && rm -rf /var/lib/apt/lists/*
COPY Gemfile Gemfile.lock ./
# In-tree path gems (hanami-credentials, vite-hanami, ...) resolve from
# gems/ at runtime — bundler only vendors their dependencies here.
COPY gems gems/
ENV BUNDLE_PATH=vendor/bundle \
    BUNDLE_WITHOUT=development:test
RUN bundle install --jobs 4

# ── Stage 3: runtime ─────────────────────────────────────────────────────────
FROM docker.io/library/ruby:4.0.5-slim
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends libpq5 libyaml-0-2 postgresql-client \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --user-group --home /app --shell /usr/sbin/nologin app
WORKDIR /app
ENV BUNDLE_PATH=vendor/bundle \
    BUNDLE_WITHOUT=development:test
COPY --from=gems /app/vendor/bundle vendor/bundle
COPY Gemfile Gemfile.lock config.ru falcon.rb ./
COPY gems gems/
COPY app app/
COPY config config/
COPY lib lib/
COPY bin bin/
COPY images images/
COPY --from=frontend /app/public/vite public/vite
RUN mkdir -p log tmp && chown -R app:app /app
USER app
ENV HANAMI_ENV=production \
    RACK_ENV=production \
    FALCON_BIND=http://0.0.0.0:3000
EXPOSE 3000
# bin/serve resolves INGEST_TOKEN from ENV (pass-through when set) and execs
# the supervised topology. Migrations run by overriding the command:
#   bundle exec hanami db prepare
CMD ["./bin/serve"]
