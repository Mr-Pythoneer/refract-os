#!/usr/bin/env bash
#
# Preloads the AI-mode LLM/vision models from config/models.catalog.json via
# `lms get`. Image-generation models (FLUX/SDXL) are NOT here — those run in
# ComfyUI, see 04-download-image-models.sh.
#
# Default: pull ALL LM Studio models in the catalog (~150GB — the catalog is
# the 5090 'max' tier). Pass a space-separated list of catalog ids, or a single
# use-case, to pull a subset.
#
# Usage:
#   ./02-preload-models.sh                         # ALL lmstudio models (~150GB)
#   ./02-preload-models.sh coding                  # just the models for the 'coding' use-case
#   ./02-preload-models.sh qwen2.5-coder-32b llama3.2-3b   # specific catalog ids

set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as your normal user, not root (models download into ~/.lmstudio/models)." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG="$SCRIPT_DIR/../config/models.catalog.json"
LMS="$HOME/.lmstudio/bin/lms"
command -v "$LMS" >/dev/null 2>&1 || LMS="$(command -v lms || echo "$LMS")"

[ -f "$CATALOG" ] || { echo "Catalog not found: $CATALOG" >&2; exit 1; }
[ -x "$LMS" ] || { echo "lms CLI not found ($LMS) — run 01-install-lmstudio.sh first." >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 required to read the catalog." >&2; exit 1; }

# Resolve the requested catalog ids: none -> all lmstudio models; a single
# known use-case -> that use-case's models; otherwise treat args as ids.
resolve_ids() {
    CATALOG="$CATALOG" python3 - "$@" <<'PY'
import json, os, sys
cat = json.load(open(os.environ["CATALOG"]))
models, use_cases = cat["models"], cat["use_cases"]
args = sys.argv[1:]
def lmstudio_only(ids): return [i for i in ids if models.get(i, {}).get("runtime") == "lmstudio"]
if not args:
    ids = [i for i, m in models.items() if m.get("runtime") == "lmstudio"]
elif len(args) == 1 and args[0] in use_cases:
    uc = use_cases[args[0]]
    ids = lmstudio_only([v for k, v in uc.items() if k not in ("label", "runtime")])
else:
    ids = []
    for a in args:
        if a not in models:
            print(f"__ERR__ unknown catalog id or use-case: {a}", file=sys.stderr); sys.exit(2)
        ids.append(a)
    ids = lmstudio_only(ids)
# print id<TAB>repo<TAB>quant<TAB>size_gb
seen = set()
for i in ids:
    if i in seen: continue
    seen.add(i); m = models[i]
    print(f"{i}\t{m['repo']}\t{m['quant']}\t{m.get('size_gb','?')}")
PY
}

# Capture resolve_ids' status directly — a process substitution's exit status
# is NOT seen by mapfile, so `mapfile ... || ...` can't detect resolve failure.
rows_out="$(resolve_ids "$@")" || { echo "Failed to resolve models from catalog." >&2; exit 1; }
if [ -z "$rows_out" ]; then echo "No LM Studio models matched." >&2; exit 1; fi
mapfile -t ROWS <<< "$rows_out"

total=0
echo -e "\033[36mModels to download:\033[0m"
for row in "${ROWS[@]}"; do
    IFS=$'\t' read -r id repo quant size <<< "$row"
    printf '  %-24s %s@%s  (~%s GB)\n' "$id" "$repo" "$quant" "$size"
    total=$(python3 -c "print(round($total + ${size:-0}, 1))")
done
echo -e "\033[33mApprox total download: ~${total} GB. Ensure you have the disk + bandwidth (provision ~220GB free if pulling everything incl. image models).\033[0m"
echo "Models with vision (qwen2.5-vl*) pull their mmproj projector automatically via lms get."

for row in "${ROWS[@]}"; do
    IFS=$'\t' read -r id repo quant size <<< "$row"
    echo -e "\033[36m\n== $id : $repo@$quant ==\033[0m"
    # Full HF-URL form + @quant resolves to a single artifact and minimizes
    # prompting. Both attempts pass --yes so neither blocks on a confirm.
    "$LMS" get "https://huggingface.co/$repo@$quant" --yes 2>/dev/null \
        || "$LMS" get "$repo@$quant" --yes \
        || echo "WARNING: 'lms get' failed for $id — pull it manually in the LM Studio Discover tab ($repo)." >&2
done

echo -e "\033[32m\nDone. Loaded none yet — pick one with: distro-ai-model use <use-case>  (e.g. coding).\033[0m"
echo "Downloaded models live in ~/.lmstudio/models (gitignored — never commit weights)."
