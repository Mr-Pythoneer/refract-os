#!/usr/bin/env bash
# Tests for modes/ai/bin/distro-ai-ask (thin OpenAI-compatible client).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ASK="$REPO_ROOT/modes/ai/bin/distro-ai-ask"

if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  note "skipping (need python3 + curl)"; finish; exit $?
fi

# empty prompt is rejected without needing a server
printf '' | "$ASK" "" >/dev/null 2>&1; assert_eq "empty prompt exits 1" "1" "$?"

# unreachable server (nothing on 8080) -> clear failure
# (only meaningful if 8080 is actually free; if something's there, skip)
if ! curl -fsS --max-time 2 -o /dev/null "http://127.0.0.1:8080/" 2>/dev/null; then
  "$ASK" "hi" >/dev/null 2>&1; assert_eq "unreachable server exits 1" "1" "$?"
else
  note "port 8080 already in use — skipping unreachable-server check"
fi

# stub an OpenAI-compatible server on 8080 and exercise happy + malformed paths
srv="$(new_stubdir)/srv.py"
cat > "$srv" <<'PY'
import http.server, json, sys
MODE = sys.argv[1] if len(sys.argv) > 1 else "ok"
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0)); body = json.loads(self.rfile.read(n))
        if MODE == "ok":
            msg = body["messages"][0]["content"]
            data = json.dumps({"choices":[{"message":{"content":"echo: "+msg}}]}).encode()
        else:
            data = b'{"unexpected":"shape"}'
        self.send_response(200); self.send_header("Content-Length", str(len(data))); self.end_headers()
        self.wfile.write(data)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 8080), H).serve_forever()
PY

start_srv() { python3 "$srv" "$1" & SRV_PID=$!; sleep 1; }
stop_srv() { kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; }

if python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",8080)); s.close()' 2>/dev/null; then
  start_srv ok
  out="$("$ASK" "hello" 2>&1)"; rc=$?
  assert_eq "happy path exits 0" "0" "$rc"
  assert_contains "happy path returns the reply" "$out" "echo: hello"
  out="$(printf 'via stdin' | "$ASK" 2>&1)"; assert_contains "reads prompt from stdin" "$out" "echo: via stdin"
  stop_srv

  start_srv bad
  "$ASK" "x" >/dev/null 2>&1; assert_eq "malformed response shape exits 1" "1" "$?"
  stop_srv
else
  note "could not bind 127.0.0.1:8080 — skipping live server checks"
fi
rm -rf "$(dirname "$srv")"

finish
