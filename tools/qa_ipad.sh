#!/usr/bin/env bash
# S2.1 visual QA: seed the real 283 content/stand packs, run the visual UI test on an iPad
# and an optional iPhone, and extract the five layout screenshots into .qa-screenshots/.
# A human/agent must still open the images and judge them; this script only captures them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON_ROOT="$(cd "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
DERIVED="${EIDOLON_QA_DERIVED_DATA:-$ROOT/build/QADerivedData}"
OUT="${EIDOLON_QA_OUTPUT:-$ROOT/.qa-screenshots}"
CONTENT_PACK="${EIDOLON_TEST_CONTENT_PACK:-}"
STAND_PACK="${EIDOLON_TEST_STAND_PACK:-$COMMON_ROOT/build/eidolon-stand.eidolonpkg}"
BUNDLE_ID="com.jacklin.eidolon"

if [[ -z "$CONTENT_PACK" ]]; then
  for candidate in "$COMMON_ROOT/build/eidolon-content.eidolonpkg" \
                   "$COMMON_ROOT/build/eidolon-content-3dtest.eidolonpkg"; do
    if [[ -f "$candidate" ]]; then CONTENT_PACK="$candidate"; break; fi
  done
fi
[[ -n "$CONTENT_PACK" && -f "$CONTENT_PACK" ]] || {
  echo "missing content pack; set EIDOLON_TEST_CONTENT_PACK" >&2; exit 2;
}
[[ -f "$STAND_PACK" ]] || {
  echo "missing stand pack; set EIDOLON_TEST_STAND_PACK" >&2; exit 2;
}

if [[ -z "${IPAD_UDID:-}" ]]; then
  IPAD_UDID="$(xcrun simctl list devices booted -j | python3 -c '
import json,sys
for runtime in json.load(sys.stdin)["devices"].values():
    for device in runtime:
        if device.get("state")=="Booted" and "iPad" in device.get("name",""):
            print(device["udid"]); raise SystemExit
')"
fi
[[ -n "$IPAD_UDID" ]] || { echo "no booted iPad; boot one or set IPAD_UDID" >&2; exit 2; }

mkdir -p "$OUT"
if [[ "${EIDOLON_QA_RESET:-0}" == "1" ]]; then
  xcrun simctl uninstall "$IPAD_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  [[ -n "${PHONE_UDID:-}" ]] && xcrun simctl uninstall "$PHONE_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
fi
STATUS=(
  --time "9:41" --wifiBars 3 --cellularBars 4
  --batteryState charged --batteryLevel 100
)

seed_and_mark() {
  local udid="$1" with_stand="$2"
  local data docs
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  data="$(xcrun simctl get_app_container "$udid" "$BUNDLE_ID" data 2>/dev/null || true)"
  [[ -n "$data" ]] || { echo "app is not installed on $udid" >&2; exit 2; }
  docs="$data/Documents"
  mkdir -p "$docs"
  if [[ ! -f "$docs/.qa-content-installed" ]]; then
    cp "$CONTENT_PACK" "$docs/"
    env \
      SIMCTL_CHILD_EIDOLON_FAKE_CHAT=1 \
      SIMCTL_CHILD_EIDOLON_IMPORT_BUNDLE=eidolon-content.eidolonpkg \
      xcrun simctl launch --terminate-running-process "$udid" "$BUNDLE_ID" >/dev/null
    # First import includes decompression and embedding metadata; give it room.
    sleep 180
    touch "$docs/.qa-content-installed"
  fi
  if [[ "$with_stand" == "1" && ! -f "$docs/.qa-stand-installed" ]]; then
    cp "$STAND_PACK" "$docs/"
    env \
      SIMCTL_CHILD_EIDOLON_FAKE_CHAT=1 \
      SIMCTL_CHILD_EIDOLON_IMPORT_STAND_BUNDLE=eidolon-stand.eidolonpkg \
      xcrun simctl launch --terminate-running-process "$udid" "$BUNDLE_ID" >/dev/null
    sleep 120
    touch "$docs/.qa-stand-installed"
  fi
}

run_visual_test() {
  local udid="$1" test_name="$2" result="$3"
  rm -rf "$result"
  xcodebuild test \
    -project "$ROOT/EidolonIOS.xcodeproj" -scheme EidolonIOS -configuration Debug \
    -destination "platform=iOS Simulator,id=$udid" \
    -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO \
    -only-testing:"EidolonIOSUITests/IPadVisualQATests/$test_name" \
    -resultBundlePath "$result" >/dev/null
}

extract_shots() {
  local result="$1" raw="$2"
  rm -rf "$raw"
  xcrun xcresulttool export attachments --path "$result" --output-path "$raw" >/dev/null
  python3 - "$raw" "$OUT" <<'PY'
import json, pathlib, shutil, sys
raw, out = map(pathlib.Path, sys.argv[1:3])
manifest = json.loads((raw / "manifest.json").read_text())
for test in manifest:
    for attachment in test.get("attachments", []):
        name = attachment.get("suggestedHumanReadableName", "").split("_0_")[0]
        if name in {"landscape-standard", "landscape-collapsed", "landscape-expanded", "portrait-push", "compact-phone"}:
            shutil.copy(raw / attachment["exportedFileName"], out / f"{name}.png")
            print(f"captured {out / (name + '.png')}")
PY
}

xcrun simctl status_bar "$IPAD_UDID" override "${STATUS[@]}" >/dev/null 2>&1 || true
seed_and_mark "$IPAD_UDID" 1
run_visual_test "$IPAD_UDID" testIPadVisualStates "$ROOT/build/qa-ipad.xcresult"
extract_shots "$ROOT/build/qa-ipad.xcresult" "$ROOT/build/qa-ipad-attachments"

if [[ -n "${PHONE_UDID:-}" ]]; then
  xcrun simctl status_bar "$PHONE_UDID" override "${STATUS[@]}" >/dev/null 2>&1 || true
  seed_and_mark "$PHONE_UDID" 0
  run_visual_test "$PHONE_UDID" testCompactPhoneVisualState "$ROOT/build/qa-phone.xcresult"
  extract_shots "$ROOT/build/qa-phone.xcresult" "$ROOT/build/qa-phone-attachments"
else
  echo "PHONE_UDID not set; skipped compact-phone" >&2
fi

echo "QA screenshots in $OUT"
