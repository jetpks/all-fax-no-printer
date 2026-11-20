# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- typescript 6.0.3 → 7.0.2 (dev toolchain; supersedes dependabot #14,
  whose CI failed because TS7 rejects named imports from the app's
  `export =` prism-styles shim). The shim now declares `nightOwl` as a
  merging named export — no runtime change.
- Dependency refresh round: sequel 5.110.0 + minitest 6.1.0 (re-lands
  the surviving half of dependabot #42, closed obsolete after the Ruby
  bump rewrote the lock); npm dev group (@types/node 26, jsdom 31,
  vite 8.3.7, vitest 5.1), axios 1.20, lucide-react 1.61, shadcn
  4.22.1, and the docker/* GitHub Actions bumps.
- Bumped Ruby 4.0.9 → 4.0.10 (security release): toolchain (`mise.toml`,
  `.ruby-version`), `Gemfile`/`Gemfile.lock` for the app and all five
  in-tree gems, and the `ruby:4.0.10-slim` Containerfile base image.
  (rack 3.2.8 landed with the #35 dep refresh; omniauth 2.3.1 already
  cleared CVE-2026-63183's 2.2.0 floor.)
- omniauth 2.3.1 → 2.4.2 (host header injection CVE-2026-63183 line;
  latest 2.x), with rack-protection 4.2.1 → 4.2.2 as its only ripple.

### Removed

- The retired studio deploy: `deploy/` and
  `docs/how-to/deploy-on-the-studio.md`. Production runs on sombrero,
  deployed from the GHCR image via ansible-pull CD.
- `bin/pg_linux_compile_check.sh` — a one-time pg source-compile proof
  from the standalone extraction; the multi-arch image build in CI is the
  compile gate now.

## [0.1.0] - 2026-10-14

### Added

- Standalone extraction of the former `server/` subdirectory of the
  [jetpks/space-architect](https://github.com/jetpks/space-architect)
  monorepo (itself descended from a fork of `jetpks/chat_share`), via
  `git filter-repo --subdirectory-filter server`. Git history is preserved;
  pre-extraction (monorepo) history is documented in
  [space-architect's CHANGELOG](https://github.com/jetpks/space-architect/blob/main/CHANGELOG.md).
