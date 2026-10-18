# onlineonly

Make Dropbox files and folders **online-only** or **available offline** from the macOS
command line and from AI agents, without right-clicking in Finder.

> Unofficial. onlineonly is an independent project, not affiliated with, endorsed by, or
> supported by Dropbox, Inc. "Dropbox" is a trademark of Dropbox, Inc.

```
$ onlineonly ls ~/Dropbox/Archive
online-only  2019/
online-only  2020/
offline      2024/
local        notes.md

$ onlineonly offline -w ~/Dropbox/Archive/2020
offline      /Users/you/Dropbox/Archive/2020

$ onlineonly online ~/Dropbox/Archive/2024
requested online: /Users/you/Dropbox/Archive/2024
```

It ships as a single binary that is both a CLI and an [MCP](https://modelcontextprotocol.io)
server, so Claude Code, Codex, Cursor and other agents can check and change which files are
kept on disk.

## Install

```
git clone https://github.com/Zamua/onlineonly && cd onlineonly
make && sudo make install              # or: make install PREFIX=~/.local
```

Needs macOS 11+, the Xcode command line tools (`xcode-select --install`) and the Dropbox
desktop app with its folder at `~/Dropbox`.

## CLI

```
onlineonly status  [--json] <path>...                  state of each path
onlineonly ls      [--json] <folder>                   state of each entry in a folder
onlineonly online  [-w] [-t secs] [--json] <path>...   make online-only (free disk space)
onlineonly offline [-w] [-t secs] [--json] <path>...   make available offline (download and keep)
onlineonly roots                                       Dropbox folders on this Mac
onlineonly mcp                                         run the MCP server on stdio
```

`-w` waits until Dropbox reports the new state; for `offline` that means the files have
downloaded. `-t` caps the wait (default 600 seconds). Folders apply recursively, exactly like
the Finder menu. Exit status is 0 on success, 1 if any path failed or timed out, 69 if Dropbox
is not reachable.

States:

| state | meaning |
| --- | --- |
| `online-only` | 0-byte placeholder on disk; content stays in the cloud |
| `offline` | downloaded and kept (Finder: "Make available offline") |
| `local` | downloaded, but Dropbox may reclaim the space |
| `syncing` | upload or download in progress |
| `mixed` | a folder whose contents are in different states |
| `error`, `ignored`, `locked` | as shown by the Finder badge |
| `none` | not managed by Dropbox |

A folder's state is its own setting, so `ls` is the way to see what is inside it.

## Agents (MCP)

`onlineonly mcp` is a stdio MCP server with three tools:

- `get_sync_status`: state of paths, optionally with each folder's children (read-only)
- `make_online_only`: free space by turning paths into placeholders
- `make_available_offline`: download and keep paths

Both changing tools wait for Dropbox to finish by default, for up to 45 seconds (`wait`,
`timeout_seconds`); paths still changing come back as `pending`. Raise `timeout_seconds` only
if your client allows tool calls longer than its usual 60 seconds.

Register it with all your agents in one step (needs Node.js):

```
npx add-mcp "$(which onlineonly)" --args mcp --name onlineonly -g
```

[add-mcp](https://github.com/neon-solutions/add-mcp) detects the agents you have installed,
lets you pick, and writes each one's own config: Claude Code, Codex, Cursor, VS Code, Claude
Desktop, Gemini CLI, opencode, Windsurf, Zed and more. The full path from `which` lets apps
launched from the Dock, which do not see your shell `PATH`, find the binary.

Without Node:

```
claude mcp add -s user onlineonly -- onlineonly mcp
codex mcp add onlineonly -- onlineonly mcp
```

Any other MCP client: command `onlineonly` (or its full path), argument `mcp`, transport stdio.

Agents without MCP can use the CLI directly; every command takes `--json`.

## How it works

onlineonly talks to the Dropbox desktop app on your Mac through the same local interface the
app's Finder integration uses. For each path it asks Dropbox which actions its Finder menu
offers, and sends only "Make online-only" or "Make available offline" when Dropbox offers it,
just as a click in Finder would. It does not modify the Dropbox app, read Dropbox's data
files, or contact Dropbox's servers.

Dropbox ignores a request for a path it is still syncing, so onlineonly holds the request until
the path settles and sends it again if nothing happens.

## Limits

- macOS only, and only the Dropbox app that keeps its folder at `~/Dropbox`. The File
  Provider version (`~/Library/CloudStorage/Dropbox`) works differently and is not supported.
- The interface is undocumented and unsupported by Dropbox, so a Dropbox update can break
  onlineonly. That shows up as "no reply" or "Dropbox does not offer ...", never as a wrong
  action.
- A placeholder reads as an empty file. Do not make online-only anything a program is
  actively using.

## Development

```
make test     # unit tests plus a stdio MCP round trip; no Dropbox needed
```

## License

MIT. Not affiliated with Dropbox, Inc.
