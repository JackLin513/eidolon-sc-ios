#!/usr/bin/env bash
# 用模拟器版 UnityFramework/Data 构建 EidolonIOS（M2/调试用），构建完自动把仓库里的
# 真机版 framework/Data 换回去。模拟器版产物来自：
#   spikes/porting-3d/unity-spike/build/ios-export-sim/（iOSExport.BuildSimulator + xcodebuild）
# 用法：tools/build_sim_app.sh [simulator-udid]
set -euo pipefail
cd "$(dirname "$0")/.."

# No device UDID is baked in: use the first argument / EIDOLON_SIM_UDID, else the
# canonical iPhone Air 3D simulator, else the first available iPhone. Reuse the existing
# device instead of adding a new simulator for every agent run.
SIM_NAME=${EIDOLON_SIM_NAME:-iPhone Air 3D}
SIM_UDID=${1:-${EIDOLON_SIM_UDID:-}}
if [ -z "$SIM_UDID" ]; then
  SIM_UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
items = [d for ds in json.load(sys.stdin)["devices"].values() for d in ds]
for d in items:
    if d.get("name") == name and d.get("isAvailable"):
        print(d["udid"]); raise SystemExit
for d in items:
    if d.get("isAvailable") and "iPhone" in d.get("deviceTypeIdentifier", ""):
        print(d["udid"]); raise SystemExit
raise SystemExit(1)
' "$SIM_NAME")
fi
[ -n "$SIM_UDID" ] || { echo "no available iPhone simulator; create one or pass a UDID" >&2; exit 1; }
EXPORT=spikes/porting-3d/unity-spike/build/ios-export-sim
SIM_FRAMEWORK="$EXPORT/build/derived/Build/Products/Release-iphonesimulator/UnityFramework.framework"
SIM_DATA="$EXPORT/Data"
DEVICE_BACKUP=build/UnitySimSwap/device
FRAMEWORK_TARGET=EidolonIOS/UnityRuntime/UnityFramework.framework
DATA_TARGET=EidolonIOS/Resources/Unity/Data

[ -d "$SIM_FRAMEWORK" ] || { echo "missing $SIM_FRAMEWORK (build the simulator export first)" >&2; exit 1; }
[ -d "$SIM_DATA" ] || { echo "missing $SIM_DATA" >&2; exit 1; }

mkdir -p "$DEVICE_BACKUP"
restore() {
  rm -rf "$FRAMEWORK_TARGET" "$DATA_TARGET"
  [ -d "$DEVICE_BACKUP/UnityFramework.framework" ] && cp -R "$DEVICE_BACKUP/UnityFramework.framework" "$FRAMEWORK_TARGET"
  [ -d "$DEVICE_BACKUP/Data" ] && cp -R "$DEVICE_BACKUP/Data" "$DATA_TARGET"
  /opt/homebrew/bin/xcodegen generate >/dev/null
}
trap restore EXIT

if [ ! -d "$DEVICE_BACKUP/UnityFramework.framework" ]; then
  cp -R "$FRAMEWORK_TARGET" "$DEVICE_BACKUP/UnityFramework.framework"
  cp -R "$DATA_TARGET" "$DEVICE_BACKUP/Data"
fi
rm -rf "$FRAMEWORK_TARGET" "$DATA_TARGET"
cp -R "$SIM_FRAMEWORK" "$FRAMEWORK_TARGET"
cp -R "$SIM_DATA" "$DATA_TARGET"

/opt/homebrew/bin/xcodegen generate >/dev/null
xcodebuild -project EidolonIOS.xcodeproj -scheme EidolonIOS -configuration Debug \
  -sdk iphonesimulator -destination "platform=iOS Simulator,id=$SIM_UDID" \
  -derivedDataPath build/dd-sim CODE_SIGNING_ALLOWED=NO build

APP=build/dd-sim/Build/Products/Debug-iphonesimulator/Eidolon.app
xcrun simctl install "$SIM_UDID" "$APP"
echo "installed $APP on $SIM_UDID"
