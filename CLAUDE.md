# onlineonly: working notes

One binary, two front ends (CLI and stdio MCP server) over a small core that asks the
Dropbox desktop app to make paths online-only or available offline, through the local
interface its Finder integration uses. Objective-C, Foundation only, no dependencies.

## Layout

- `src/OODomain.{h,m}`: status codes and target states. Pure, and free of Dropbox's wire
  vocabulary.
- `src/OOBackend.h`: the port the service needs, in domain terms: a path's status, and "move
  this path toward a target if Dropbox offers it" (sent, not offered, or unanswered). A missing
  or malformed reply comes back with an error string, so it is never confused with a real
  status or an action Dropbox declined to offer.
- `src/OODropbox.{h,m}`: the adapter to the Dropbox app. The wire format is described at the
  top of the `.m`; everything Dropbox-specific stays in this file: the menu verbs, the menu
  parser, and the reply decoders (`OOStatusFromReply`/`OOVerbsFromReply`, unit-tested).
  Dropbox's replies always carry their key (`status`, `menu`), even for paths outside
  Dropbox, so a reply without it is malformed.
- `src/OOResult.{h,m}`: typed results (status report, folder entry and listing, apply result
  with an `OOOutcome`) and their one JSON shape, which the CLI's `--json` and the MCP tools'
  `structuredContent` both emit. `TestResultContract` pins that shape per outcome.
- `src/OOJob.{h,m}`: one path's apply lifecycle (Unsent, Sent, Final) as an immutable value
  whose `-next:` is the only transition. Events are a status read, Dropbox's answer to the
  request a read asked for, and the deadline; time arrives in the events, so tests feed
  sequences instead of sleeping.
- `src/OOService.{h,m}`: path resolution, status with an optional folder listing, and the
  apply loop: it polls, sends the requests `OOJob` asks for, and times out.
- `src/OOMCP.{h,m}`: JSON-RPC 2.0 over newline-delimited stdio; tools only. `OOTool` is the
  one tool table: definitions and dispatch are exhaustive switches over it. Arguments are
  parsed once against the schema before anything runs; a present argument of the wrong type
  is an error, an unknown key is ignored, and null counts as absent.
- `src/main.m`: CLI. `src/version.h`: the version string, bumped at release.
- `tests/tests.m`: unit tests against an in-memory `FakeBackend`; `tests/mcp_stdio.sh`
  drives the real binary over stdio. `make test` runs both and needs no Dropbox.

## Behavior worth knowing

- Dropbox silently drops a request sent while the path is `syncing` (a just-created file or
  folder). `OOJob` holds requests until the path settles and re-sends after
  `resendInterval` if a settled path has not moved. Once one request has gone through, an
  unanswered resend keeps waiting instead of failing the path.
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
