# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - 2026-10-14

### Added

- Standalone extraction of the former `server/` subdirectory of the
  [jetpks/space-architect](https://github.com/jetpks/space-architect)
  monorepo (itself descended from a fork of `jetpks/chat_share`), via
  `git filter-repo --subdirectory-filter server`. Git history is preserved;
  pre-extraction (monorepo) history is documented in
  [space-architect's CHANGELOG](https://github.com/jetpks/space-architect/blob/main/CHANGELOG.md).
