#!/usr/bin/env bash
# Baut die App, signiert sie für die registrierten Familien-iPhones (Ad Hoc)
# und veröffentlicht sie auf GitHub Pages (Branch gh-pages).
#
#   scripts/release.sh "Was ist neu"
#
# Danach zeigt die App auf allen iPhones „Update verfügbar“.
# Neue iPhones vorher im Developer-Portal registrieren, sie landen dann
# automatisch im Profil.
set -euo pipefail

cd "$(dirname "$0")/.."
NOTES="${1:-}"
PROJECT=HomeVault.xcodeproj
SCHEME=HomeVault
OUT=build/release

die() { echo "Fehler: $*" >&2; exit 1; }

# --- GitHub-Repo und Pages-Adresse aus dem Git-Remote ---
REMOTE=$(git remote get-url origin 2>/dev/null) || die "Kein Git-Remote 'origin'. Erst ein GitHub-Repo anlegen und verbinden."
SLUG=$(echo "$REMOTE" | sed -E 's#(git@github\.com:|https://github\.com/)##; s#\.git$##')
OWNER=${SLUG%%/*}
REPO=${SLUG#*/}
[[ "$OWNER" != "$SLUG" ]] || die "Remote ist kein GitHub-Repo: $REMOTE"
PAGES_URL=${PAGES_URL:-"https://$(echo "$OWNER" | tr '[:upper:]' '[:lower:]').github.io/$REPO"}

# --- Einstellungen aus dem Projekt ---
SETTINGS=$(xcodebuild -showBuildSettings -project "$PROJECT" -target "$SCHEME" -configuration Release 2>/dev/null)
setting() { echo "$SETTINGS" | awk -v k="$1" '$1 == k && $2 == "=" { $1 = ""; $2 = ""; sub(/^ +/, ""); print; exit }'; }
TEAM=$(setting DEVELOPMENT_TEAM)
VERSION=$(setting MARKETING_VERSION)
BUNDLE_ID=$(setting PRODUCT_BUNDLE_IDENTIFIER)
[[ -n "$TEAM" ]] || die "Kein Team gesetzt. In Xcode: Target HomeVault → Signing & Capabilities → Team."

# --- Zertifikat bald abgelaufen? ---
while IFS= read -r end; do
  [[ -n "$end" ]] || continue
  ts=$(date -j -f "%b %e %T %Y %Z" "$end" +%s 2>/dev/null) || continue
  left=$(( (ts - $(date +%s)) / 86400 ))
  if (( left < 30 )); then
    echo "⚠️  Ein Apple-Distribution-Zertifikat läuft in $left Tagen ab ($end)."
    echo "    Xcode erneuert es beim Export automatisch, danach diesen Release einfach nochmal ausführen."
  fi
done < <(security find-certificate -a -c "Apple Distribution" -p 2>/dev/null \
  | awk '/BEGIN/{c=""} {c=c $0 "\n"} /END/{printf "%s", c | "openssl x509 -noout -enddate"; close("openssl x509 -noout -enddate")}' \
  | sed 's/notAfter=//')

# Build-Nummer = Zeitstempel, damit jede Veröffentlichung neuer ist
BUILD=$(date +%Y%m%d%H%M)
echo "▶︎ homevault $VERSION ($BUILD) für $PAGES_URL"

rm -rf "$OUT"
mkdir -p "$OUT"

# --- Bauen ---
xcodebuild archive \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$OUT/HomeVault.xcarchive" \
  -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$BUILD" \
  HV_UPDATE_URL="$PAGES_URL" \
  | grep -E "error:|warning: .*signing|ARCHIVE (SUCCEEDED|FAILED)" || true
[[ -d "$OUT/HomeVault.xcarchive" ]] || die "Archivieren fehlgeschlagen (Ausgabe oben)."

# --- Exportieren (Ad Hoc mit Manifest für die Installation per Link) ---
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>release-testing</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>thinning</key><string>&lt;none&gt;</string>
  <key>compileBitcode</key><false/>
  <key>manifest</key>
  <dict>
    <key>appURL</key><string>$PAGES_URL/HomeVault.ipa</string>
    <key>displayImageURL</key><string>$PAGES_URL/icon-57.png</string>
    <key>fullSizeImageURL</key><string>$PAGES_URL/icon-512.png</string>
  </dict>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath "$OUT/HomeVault.xcarchive" \
  -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -allowProvisioningUpdates \
  | grep -E "error:|EXPORT (SUCCEEDED|FAILED)" || true
IPA=$(find "$OUT/export" -name "*.ipa" | head -1)
[[ -f "$IPA" && -f "$OUT/export/manifest.plist" ]] || die "Export fehlgeschlagen (Ausgabe oben)."

# --- Profil auslesen: gültig bis, Anzahl Geräte ---
PROFILE="$OUT/profile.plist"
unzip -p "$IPA" "Payload/*.app/embedded.mobileprovision" | security cms -D > "$PROFILE"
EXPIRES=$(plutil -extract ExpirationDate raw -o - "$PROFILE")
DEVICES=$(plutil -extract ProvisionedDevices raw -o - "$PROFILE" 2>/dev/null || echo "?")
EXPIRES_DE=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$EXPIRES" "+%d.%m.%Y" 2>/dev/null || echo "$EXPIRES")

# --- Seite zusammenstellen ---
SITE="$OUT/site"
mkdir -p "$SITE"
cp "$IPA" "$SITE/HomeVault.ipa"
cp "$OUT/export/manifest.plist" "$SITE/manifest.plist"
ICON=HomeVault/Assets.xcassets/AppIcon.appiconset/icon.png
sips -z 57 57 "$ICON" --out "$SITE/icon-57.png" >/dev/null
sips -z 512 512 "$ICON" --out "$SITE/icon-512.png" >/dev/null
sips -z 180 180 "$ICON" --out "$SITE/icon-180.png" >/dev/null
touch "$SITE/.nojekyll"

MANIFEST_URL="$PAGES_URL/manifest.plist"
DATE_DE=$(date "+%d.%m.%Y")
HV_VERSION="$VERSION" HV_BUILD="$BUILD" HV_BUNDLE="$BUNDLE_ID" HV_MANIFEST="$MANIFEST_URL" \
HV_EXPIRES="$EXPIRES" HV_EXPIRES_DE="$EXPIRES_DE" HV_NOTES="$NOTES" HV_DATE="$DATE_DE" \
python3 - "$SITE" <<'PY'
import html, json, os, sys
site = sys.argv[1]
e = os.environ
info = {
    "version": e["HV_VERSION"],
    "build": e["HV_BUILD"],
    "bundle": e["HV_BUNDLE"],
    "manifest": e["HV_MANIFEST"],
    "expires": e["HV_EXPIRES"],
    "notes": e["HV_NOTES"],
    "date": e["HV_DATE"],
}
with open(f"{site}/version.json", "w", encoding="utf-8") as f:
    json.dump(info, f, ensure_ascii=False, indent=2)
with open("scripts/site/index.html", encoding="utf-8") as f:
    page = f.read()
for k, v in {
    "VERSION": info["version"], "BUILD": info["build"], "MANIFEST_URL": info["manifest"],
    "EXPIRES": e["HV_EXPIRES_DE"], "DATE": info["date"],
    "NOTES": html.escape(info["notes"]) or "Fehlerbehebungen und Verbesserungen",
}.items():
    page = page.replace("{{" + k + "}}", v)
with open(f"{site}/index.html", "w", encoding="utf-8") as f:
    f.write(page)
PY

# --- Auf GitHub Pages veröffentlichen (Branch gh-pages, ohne Verlauf) ---
(
  cd "$SITE"
  git init -q
  git checkout -q -b gh-pages
  git add -A
  git -c user.name="$(git -C ../../.. config user.name || echo homevault)" \
      -c user.email="$(git -C ../../.. config user.email || echo homevault@localhost)" \
      commit -q -m "homevault $VERSION ($BUILD)"
  git push -q -f "$REMOTE" gh-pages
)

echo
echo "✅ Veröffentlicht: homevault $VERSION ($BUILD)"
echo "   Installationsseite: $PAGES_URL"
echo "   Gültig bis:         $EXPIRES_DE"
echo "   Registrierte Geräte im Profil: $DEVICES"
echo "   (Beim ersten Mal: GitHub → Settings → Pages → Branch 'gh-pages' auswählen.)"
