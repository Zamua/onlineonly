#!/usr/bin/env bash
# Drives `onlineonly mcp` over real stdio and checks the JSON-RPC exchange. Independent of
# whether Dropbox is running: the only tool call targets a path that cannot exist.
set -euo pipefail
bin="${1:-./onlineonly}"

out=$(
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}'
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    printf '\n'
    printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_sync_status","arguments":{"paths":["/nonexistent/onlineonly-smoke"]}}}'
    printf '\xff\xfe\n'
    printf '%s\n' '{"jsonrpc":"2.0","id":4,"method":"ping"}'
  } | "$bin" mcp
)

python3 - "$out" <<'EOF'
import json, sys
lines = sys.argv[1].splitlines()
msgs = [json.loads(l) for l in lines]
assert [m.get("id") for m in msgs] == [1, 2, 3, None, 4], [m.get("id") for m in msgs]
assert msgs[0]["result"]["protocolVersion"] == "2025-06-18"
assert msgs[0]["result"]["serverInfo"]["name"] == "onlineonly"
names = [t["name"] for t in msgs[1]["result"]["tools"]]
assert names == ["get_sync_status", "make_online_only", "make_available_offline"], names
assert msgs[2]["result"]["isError"] is True
assert msgs[3]["error"]["code"] == -32700
assert msgs[4]["result"] == {}
print(f"mcp stdio: {len(msgs)} responses ok")
EOF
