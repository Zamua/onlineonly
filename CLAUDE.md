# onlineonly: working notes

One binary, two front ends (CLI and stdio MCP server) over a small core that asks the
Dropbox desktop app to make paths online-only or available offline, through the local
interface its Finder integration uses. Objective-C, Foundation only, no dependencies.

## Layout

- `src/OODomain.{h,m}`: status codes, target actions, menu parsing. Pure.
- `src/OOBackend.h`: the port the service needs (status, offered actions, perform).
- `src/OODropbox.{h,m}`: the adapter to the Dropbox app. The wire format is described at the
  top of the `.m`; everything Dropbox-specific stays in this file.
- `src/OOService.{h,m}`: path resolution, folder listing, apply-with-wait (hold while
  syncing, resend, timeouts).
- `src/OOMCP.{h,m}`: JSON-RPC 2.0 over newline-delimited stdio; tools only.
- `src/main.m`: CLI. `src/version.h`: the version string, bumped at release.
- `tests/tests.m`: unit tests against an in-memory `FakeBackend`; `tests/mcp_stdio.sh`
  drives the real binary over stdio. `make test` runs both and needs no Dropbox.

## Behavior worth knowing

- Dropbox silently drops a request sent while the path is `syncing` (a just-created file or
  folder). `OOService.apply` holds requests until the path settles and re-sends after
  `resendInterval` if a settled path has not moved.
- Folder requests are recursive. Small trees flip in about a second.
- Placeholders are 0-byte files with a `com.dropbox.placeholder` xattr; reading one returns 0
  bytes and does not download it.
- The tool only sends an action Dropbox's own menu offers for the path, so a Dropbox change
  fails closed ("does not offer"), never as a different action.

## Release

Bump `src/version.h`, tag `vX.Y.Z` on `main`, then update `url` and `sha256` in
`Formula/onlineonly.rb` in `Zamua/homebrew-tap`; the formula builds from the tag's source
tarball, so a stale entry silently keeps serving the old version.

## Rules

- Never commit Dropbox code, binaries, or material extracted from the Dropbox app.
- Keep docs to what onlineonly does. Use Dropbox's current terms ("online-only",
  "available offline"), and keep the "not affiliated with Dropbox" notice in the README.
