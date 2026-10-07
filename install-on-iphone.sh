#!/bin/zsh
# Builds Subtext and installs it on the iPhone plugged into this Mac.
# With a free Apple ID the app stops opening after 7 days; run this again to renew it.
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f Config/Local.xcconfig ]]; then
  echo "Config/Local.xcconfig is missing. Copy Config/Local.xcconfig.example to Config/Local.xcconfig"
  echo "and fill in your Spotify Client ID, Apple team ID and bundle ID prefix (see the README)."
  exit 1
fi

devices_json=$(mktemp)
xcrun devicectl list devices --json-output "$devices_json" >/dev/null
read -r udid name <<<"$(/usr/bin/python3 - "$devices_json" <<'EOF'
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
for d in devices:
    hw = d.get("hardwareProperties", {})
    # Real devices may omit "reality"; simulators always say "simulated".
    if hw.get("reality") != "simulated" and hw.get("platform") == "iOS" and hw.get("udid"):
        print(hw["udid"], d.get("deviceProperties", {}).get("name", "iPhone").replace(" ", "_"))
        break
EOF
)"
rm -f "$devices_json"

if [[ -z "${udid:-}" ]]; then
  echo "No iPhone found. Plug it in with a cable, unlock it, and tap Trust if it asks."
  exit 1
fi
echo "Building Subtext for ${name//_/ }…"

log=build/install-last.log
mkdir -p build
if ! xcodebuild -project Subtext.xcodeproj -scheme Subtext -configuration Release \
  -destination "id=$udid" -derivedDataPath build/device \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  build >"$log" 2>&1; then
  grep -E "error:" "$log" | sort -u | head -20
  echo "The build failed. The full log is in $log"
  exit 1
fi
echo "Build succeeded."

app=build/device/Build/Products/Release-iphoneos/Subtext.app

bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Info.plist")
xcrun devicectl device install app --device "$udid" "$app"
if ! xcrun devicectl device process launch --device "$udid" "$bundle_id" >/dev/null 2>&1; then
  echo
  echo "Installed. If it won't open, on the iPhone go to Settings → General → VPN & Device Management,"
  echo "tap your Apple ID under Developer App, and tap Trust. Then open Subtext."
else
  echo "Installed and opened on ${name//_/ }."
fi
