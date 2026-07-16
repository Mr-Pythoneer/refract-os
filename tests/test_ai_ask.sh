#!/usr/bin/env bash
# Tests for modes/ai/bin/distro-ai-ask (thin OpenAI-compatible client for Ollama).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ASK="$REPO_ROOT/modes/ai/bin/distro-ai-ask"

if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  note "skipping (need python3 + curl)"; finish; exit $?
fi

# empty prompt is rejected without needing a server
printf '' | "$ASK" "" >/dev/null 2>&1; assert_eq "empty prompt exits 1" "1" "$?"

# unreachable server (nothing on 11434) -> clear failure. With no Ollama running,
# the model probe (/api/ps then /api/tags) resolves nothing, so ask can't build a
# request and exits 1. Only meaningful if 11434 is actually free; else skip.
if ! curl -fsS --max-time 2 -o /dev/null "http://127.0.0.1:11434/" 2>/dev/null; then
  "$ASK" "hi" >/dev/null 2>&1; assert_eq "unreachable server exits 1" "1" "$?"
else
  note "port 11434 already in use — skipping unreachable-server check"
fi

# stub an Ollama server on 11434 and exercise happy + malformed + no-model paths.
# The stub speaks the two surfaces ask depends on:
#   GET  /api/ps   and  /api/tags  -> which model to name (Ollama's OpenAI
#                                     endpoint REQUIRES an explicit model field)
#   POST /v1/chat/completions      -> the reply
# In "ok" mode the chat reply echoes back the model it received, so the assertion
# proves ask resolved the loaded model from /api/ps and put it in the request.
srv="$(new_stubdir)/srv.py"
cat > "$srv" <<'PY'
import http.server, json, sys
MODE = sys.argv[1] if len(sys.argv) > 1 else "ok"
MODEL = "qwen2.5-coder:7b"
class H(http.server.BaseHTTPRequestHandler):
    def _send(self, obj):
        data = json.dumps(obj).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(data))); self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        # /api/ps = resident models, /api/tags = installed models. "nomodel" mode
        # reports an empty list on both so ask has nothing to name.
        if self.path.startswith("/api/ps") or self.path.startswith("/api/tags"):
            self._send({"models": [] if MODE == "nomodel" else [{"name": MODEL}]})
        else:
            self._send({})
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0)); body = json.loads(self.rfile.read(n))
        if MODE == "bad":
            self._send({"unexpected": "shape"}); return
        model = body.get("model", "")
        msg = body["messages"][0]["content"]
        self._send({"choices": [{"message": {"content": "echo[model=%s]: %s" % (model, msg)}}]})
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 11434), H).serve_forever()
PY

start_srv() { python3 "$srv" "$1" & SRV_PID=$!; sleep 1; }
stop_srv() { kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; }

if python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",11434)); s.close()' 2>/dev/null; then
  start_srv ok
  out="$("$ASK" "hello" 2>&1)"; rc=$?
  assert_eq "happy path exits 0" "0" "$rc"
  assert_contains "happy path returns the reply" "$out" "hello"
  # proves ask named the resident model (from /api/ps) in the chat request body
  assert_contains "ask sends the resolved model in the request" "$out" "model=qwen2.5-coder:7b"
  out="$(printf 'via stdin' | "$ASK" 2>&1)"; assert_contains "reads prompt from stdin" "$out" "echo[model=qwen2.5-coder:7b]: via stdin"
  stop_srv

  start_srv nomodel
  "$ASK" "x" >/dev/null 2>&1; assert_eq "no model loaded/installed exits 1" "1" "$?"
  stop_srv

  start_srv bad
  "$ASK" "x" >/dev/null 2>&1; assert_eq "malformed response shape exits 1" "1" "$?"
  stop_srv
else
  note "could not bind 127.0.0.1:11434 — skipping live server checks"
fi
rm -rf "$(dirname "$srv")"

finish
