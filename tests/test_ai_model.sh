#!/usr/bin/env bash
# Tests for modes/ai/bin/distro-ai-model (Ollama model switcher).
# Hermetic: stubs the `ollama` CLI (list/pull/ps/stop) AND runs a fake Ollama
# HTTP API (so ensure_server / the /api/generate load succeed) on a throwaway
# port via OLLAMA_HOST, with a fake HOME so it can NEVER touch a real Ollama
# install or the system service. Also sanity-checks the embedded model table.
#
# The migrated distro-ai-model no longer reads the per-tier models.catalog.*.json
# (those were LM Studio HF-GGUF catalogs); it carries an embedded canonical
# Ollama-tag table and selects low-vs-high by tier + VRAM fit. These tests
# exercise that table + the ollama pull/ps/load path.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AIM="$REPO_ROOT/modes/ai/bin/distro-ai-model"

if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  note "skipping (need python3 + curl)"; finish; exit $?
fi

# --- integrity: every use-case variant in the EMBEDDED table resolves to a model ---
TABLE_JSON="$(awk "/<<'JSON'/{f=1;next} f&&/^JSON\$/{f=0} f" "$AIM")"
if printf '%s\n' "$TABLE_JSON" | python3 -c '
import json, sys
t = json.load(sys.stdin)
models = set(t["models"]); bad = []
for uc, d in t["use_cases"].items():
    for k, v in d.items():
        if k in ("label", "runtime"):
            continue
        if v not in models:
            bad.append(f"{uc}.{k} -> {v}")
sys.exit(1 if bad else 0)
'; then pass "model table: all use-case variants resolve to a model"; else fail "model table: a use-case variant references a missing model"; fi

# --- hermetic harness: fake HOME + stubbed ollama CLI + fake Ollama HTTP API ---
work="$(new_stubdir)"
OLLAMA_CALLS="$work/ollama.calls"
# Recording stub for the Ollama CLI. `list` prints only a header (so
# model_present() reports NOTHING installed -> load_model always exercises the
# `ollama pull` path). `ps` prints only a header (so unload_all stops nothing).
stub "$work" ollama '
echo "ollama $*" >> "'"$OLLAMA_CALLS"'"
case "$1" in
  pull) echo "pull ${*:2}: success"; exit 0 ;;
  list) echo "NAME  ID  SIZE  MODIFIED"; exit 0 ;;
  ps)   echo "NAME  ID  SIZE  PROCESSOR  UNTIL"; exit 0 ;;
  stop) exit 0 ;;
  show) echo "  Model"; exit 0 ;;
  *)    exit 0 ;;
esac'
# systemctl stub keeps `status`/`server` deterministic off a real systemd.
stub "$work" systemctl '
case "$*" in
  *is-active*) echo inactive; exit 0 ;;
  *)           exit 0 ;;
esac'
reset_calls() { rm -f "$OLLAMA_CALLS"; }
calls()       { cat "$OLLAMA_CALLS" 2>/dev/null || true; }

# aim_default: no OLLAMA_HOST -> uses the shipped default endpoint (127.0.0.1:11434).
aim_default() { HOME="$work" XDG_CONFIG_HOME="$work" PATH="$work:$PATH" "$AIM" "$@"; }

# --- list: reads the embedded table, needs no daemon ---
out="$(aim_default list 2>&1)"; rc=$?
assert_eq "list exits 0" "0" "$rc"
assert_contains "list shows the coding use-case" "$out" "coding"
assert_contains "list shows the image/ComfyUI tag" "$out" "ComfyUI"
assert_contains "list shows a canonical ollama tag" "$out" "qwen2.5-coder:32b"

# --- default endpoint is Ollama's :11434, not LM Studio's :8080 ---
# `status` prints "API: http://127.0.0.1:11434/v1 (...)" whether or not a server
# answers, so it pins the port without needing a live daemon.
out="$(aim_default status 2>&1)"; rc=$?
assert_eq "status exits 0" "0" "$rc"
assert_contains "status reports the Ollama :11434 endpoint" "$out" "127.0.0.1:11434/v1"
assert_not_contains "status does not mention the old :8080 port" "$out" "8080"

# --- error paths that never reach the daemon ---
# unknown use-case -> exit 2
aim_default use bogus </dev/null >/dev/null 2>&1; assert_eq "unknown use-case exits 2" "2" "$?"
# a ComfyUI tag is refused by `load` (it's not an Ollama model), no ollama call
reset_calls
aim_default load comfyui >/dev/null 2>&1; assert_eq "load ComfyUI tag is refused (exit 1)" "1" "$?"
assert_eq "refused ComfyUI tag never touches ollama" "" "$(calls)"

# --- live path: fake Ollama HTTP API on a throwaway port via OLLAMA_HOST -------
srv="$work/ollama_api.py"
cat > "$srv" <<'PY'
import http.server, json, sys
PORT = int(sys.argv[1])
class H(http.server.BaseHTTPRequestHandler):
    def _send(self, obj):
        data = json.dumps(obj).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(data))); self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        # /api/tags is the server_up probe; return an (empty) model list.
        self._send({"models": []})
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0)); body = json.loads(self.rfile.read(n) or b'{}')
        if self.path.startswith("/api/generate"):
            m = body.get("model")
            # No model field -> Ollama would 400 with an error; mirror that.
            self._send({"error": "model is required"} if not m else {"model": m, "done": True, "response": ""})
        else:
            self._send({})
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", PORT), H).serve_forever()
PY

LIVE_PORT="$(python3 -c '
import socket
for p in (11534, 11634, 11734, 11834, 11934):
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", p)); s.close(); print(p); break
    except OSError:
        pass
')"

if [ -n "$LIVE_PORT" ]; then
  python3 "$srv" "$LIVE_PORT" & SRV_PID=$!; sleep 1
  OH="127.0.0.1:$LIVE_PORT"
  # aim <tier> <vram_mib> <args...> — points BASE at the fake API.
  aim() { HOME="$work" XDG_CONFIG_HOME="$work" PATH="$work:$PATH" OLLAMA_HOST="$OH" \
          REFRACT_AI_TIER="$1" REFRACT_VRAM_MIB="$2" "$AIM" "${@:3}"; }

  # use coding at a 32GB-class tier -> the 32B coder, actually pulled+loaded via ollama
  reset_calls
  out="$(aim max 0 use coding 2>&1)"; rc=$?
  assert_eq "use coding exits 0" "0" "$rc"
  assert_contains "use coding resolves the 32B coder tag" "$out" "qwen2.5-coder:32b"
  assert_contains "use coding pulls via ollama" "$(calls)" "pull qwen2.5-coder:32b"
  assert_contains "use coding checks resident models via ollama ps" "$(calls)" "ollama ps"
  assert_contains "use coding loads and reports the model field" "$out" "model: qwen2.5-coder:32b"

  # legacy variant aliases still work: fast->cpu, best->high
  out="$(aim max 0 use coding fast 2>&1)"
  assert_contains "use coding fast (alias) -> 3B coder" "$out" "qwen2.5-coder:3b"
  out="$(aim max 0 use coding best 2>&1)"
  assert_contains "use coding best (alias) -> 32B coder" "$out" "qwen2.5-coder:32b"

  # tier drives low-vs-high: entry -> 7B low, cpu -> 3B cpu
  out="$(aim entry 0 use coding 2>&1)"
  assert_contains "entry tier coding -> 7B low tag" "$out" "qwen2.5-coder:7b"
  out="$(aim cpu 0 use coding 2>&1)"
  assert_contains "cpu tier coding -> 3B cpu tag" "$out" "qwen2.5-coder:3b"

  # VRAM fit: at max tier but only ~8GB, the 32B "high" is skipped for the 7B "low"
  out="$(aim max 8192 use coding 2>&1)"
  assert_contains "8GB VRAM downgrades coding to the 7B tag" "$out" "qwen2.5-coder:7b"
  assert_not_contains "8GB VRAM did NOT pick the 32B tag" "$out" "qwen2.5-coder:32b"

  # explicit oversized variant is honored but warns (min_vram_gb > detected)
  out="$(aim max 8192 use coding best 2>&1)"
  assert_contains "explicit best on 8GB still loads the 32B tag" "$out" "qwen2.5-coder:32b"
  assert_contains "explicit oversized tag warns about VRAM" "$out" "WARNING"

  # named alternates + a vision use-case
  out="$(aim max 0 use day-to-day alt 2>&1)"
  assert_contains "use day-to-day alt -> gemma3:4b" "$out" "gemma3:4b"
  out="$(aim max 0 use vision 2>&1)"
  assert_contains "use vision (high) -> qwen2.5vl:32b" "$out" "qwen2.5vl:32b"

  # image use-case routes to ComfyUI and must NOT touch ollama
  reset_calls
  out="$(aim max 0 use image 2>&1)"; rc=$?
  assert_eq "use image exits 0" "0" "$rc"
  assert_contains "use image routes to ComfyUI" "$out" "ComfyUI"
  assert_eq "use image does not touch ollama" "" "$(calls)"

  # load a specific ollama tag directly
  reset_calls
  out="$(aim max 0 load qwen2.5vl:7b 2>&1)"; rc=$?
  assert_eq "load specific tag exits 0" "0" "$rc"
  assert_contains "load specific tag reports it loaded" "$out" "model: qwen2.5vl:7b"
  assert_contains "load specific tag pulls via ollama" "$(calls)" "pull qwen2.5vl:7b"

  kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null
else
  note "no free port for the fake Ollama API — skipping live load-path checks"
fi

rm -rf "$work"
finish
