#!/usr/bin/env bash
# Runs both engines on the same scenario and diffs their prompts verbatim (ADR-0012).
# Needs the upstream checkout (default ../eidolon-sc), uv, and a content bundle exported
# from that checkout's data. No model is called.
set -euo pipefail

cd "$(dirname "$0")/../.."
UPSTREAM=${UPSTREAM:-../eidolon-sc}
SCENARIO=${SCENARIO:-tools/oracle/scenario.json}
BUNDLE=${BUNDLE:-build/eidolon-content.eidolonpkg}
OUT=${OUT:-build/oracle}

mkdir -p "$OUT"
root=$(pwd)

(cd "$UPSTREAM" && uv run --project backend python \
    "$root/tools/oracle/upstream_prompt.py" \
    --upstream . \
    --scenario "$root/$SCENARIO" \
    --out "$root/$OUT/upstream.json")

swift build --package-path EidolonCore --product prompt-oracle >/dev/null
bin=$(swift build --package-path EidolonCore --product prompt-oracle --show-bin-path)
"$bin/prompt-oracle" --bundle "$BUNDLE" --scenario "$SCENARIO" --out "$OUT/app.json"

python3 tools/oracle/compare.py "$OUT/upstream.json" "$OUT/app.json"
