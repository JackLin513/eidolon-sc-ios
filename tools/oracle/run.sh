#!/usr/bin/env bash
# Runs both engines on the same scenarios and diffs their prompts verbatim (ADR-0012).
# Needs the upstream checkout (default ../eidolon-sc), uv, and a content bundle exported
# from that checkout's data. No model is called.
set -euo pipefail

cd "$(dirname "$0")/../.."
UPSTREAM=${UPSTREAM:-../eidolon-sc}
BUNDLE=${BUNDLE:-build/eidolon-content.eidolonpkg}
OUT=${OUT:-build/oracle}
SCENARIOS=${SCENARIOS:-"tools/oracle/scenario.json tools/oracle/scenario-call.json tools/oracle/scenario-call-directed.json tools/oracle/scenario-today-her-birthday.json tools/oracle/scenario-today-others-birthday.json tools/oracle/scenario-today-holiday.json"}

mkdir -p "$OUT"
root=$(pwd)

swift build --package-path EidolonCore --product prompt-oracle >/dev/null
bin=$(swift build --package-path EidolonCore --product prompt-oracle --show-bin-path)

status=0

# The bar's prompt is a pure function of its own inputs, so its scenario is compared with
# the bar builder alone (ADR-0021) rather than through a turn.
if [ "${BAR:-1}" = 1 ]; then
    name=scenario-bar
    (cd "$UPSTREAM" && uv run --project backend python \
        "$root/tools/oracle/upstream_bar_prompt.py" \
        --upstream . \
        --scenario "$root/tools/oracle/$name.json" \
        --out "$root/$OUT/upstream-$name.json")
    "$bin/prompt-oracle" --bar --bundle "$BUNDLE" --scenario "tools/oracle/$name.json" \
        --out "$OUT/app-$name.json" >/dev/null
    echo "== $name"
    python3 tools/oracle/compare.py "$OUT/upstream-$name.json" "$OUT/app-$name.json" || status=1
fi

for scenario in $SCENARIOS; do
    name=$(basename "$scenario" .json)
    (cd "$UPSTREAM" && uv run --project backend python \
        "$root/tools/oracle/upstream_prompt.py" \
        --upstream . \
        --scenario "$root/$scenario" \
        --out "$root/$OUT/upstream-$name.json")
    "$bin/prompt-oracle" --bundle "$BUNDLE" --scenario "$scenario" \
        --out "$OUT/app-$name.json" >/dev/null
    echo "== $name"
    python3 tools/oracle/compare.py "$OUT/upstream-$name.json" "$OUT/app-$name.json" || status=1
done
exit $status
