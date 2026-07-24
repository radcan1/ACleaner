#!/bin/bash
# Builds ACleaner.app and installs it to /Applications.
# (Previously built to the Desktop — but the copy actually launched lives in
# /Applications, so rebuilds silently never reached it.)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="ACleaner"
APP_BUNDLE="/Applications/$APP_NAME.app"
BINARY_DIR="$APP_BUNDLE/Contents/MacOS"

echo "Building ACleaner..."
echo "This takes about 30-90 seconds on first build."
echo ""

rm -rf "$APP_BUNDLE"
mkdir -p "$BINARY_DIR"

swiftc \
  -framework Cocoa \
  -framework SwiftUI \
  -O \
  "$SCRIPT_DIR/Sources/Shared/FileSize.swift" \
  "$SCRIPT_DIR/Sources/Shared/Announcer.swift" \
  "$SCRIPT_DIR/Sources/Shared/CleanupJournal.swift" \
  "$SCRIPT_DIR/Sources/Shared/ScanCache.swift" \
  "$SCRIPT_DIR/Sources/Shared/AppTokenMatcher.swift" \
  "$SCRIPT_DIR/Sources/Shared/ExclusionStore.swift" \
  "$SCRIPT_DIR/Sources/Shared/BrewReceipts.swift" \
  \
  "$SCRIPT_DIR/Sources/main.swift" \
  "$SCRIPT_DIR/Sources/RootView.swift" \
  "$SCRIPT_DIR/Sources/UpdateChecker.swift" \
  "$SCRIPT_DIR/Sources/SelfUpdater.swift" \
  "$SCRIPT_DIR/Sources/Cleanup/CleanupEngine.swift" \
  "$SCRIPT_DIR/Sources/Cleanup/CleanupView.swift" \
  "$SCRIPT_DIR/Sources/PermissionsChecker.swift" \
  "$SCRIPT_DIR/Sources/PermissionsView.swift" \
  \
  "$SCRIPT_DIR/Sources/Updater/CommandRunner.swift" \
  "$SCRIPT_DIR/Sources/Updater/SizeFetcher.swift" \
  "$SCRIPT_DIR/Sources/Updater/ReleaseNotesFetcher.swift" \
  "$SCRIPT_DIR/Sources/Updater/SkipList.swift" \
  "$SCRIPT_DIR/Sources/Updater/Sudo.swift" \
  "$SCRIPT_DIR/Sources/Updater/UpdateEngine.swift" \
  "$SCRIPT_DIR/Sources/Updater/InstallEngine.swift" \
  "$SCRIPT_DIR/Sources/Updater/MaintenanceEngine.swift" \
  "$SCRIPT_DIR/Sources/Updater/UpdaterView.swift" \
  "$SCRIPT_DIR/Sources/Updater/InstallView.swift" \
  "$SCRIPT_DIR/Sources/Updater/MaintenanceView.swift" \
  "$SCRIPT_DIR/Sources/Updater/UpdateLogSheet.swift" \
  "$SCRIPT_DIR/Sources/Updater/SkippedAppsSheet.swift" \
  "$SCRIPT_DIR/Sources/Updater/ReleaseNotesSheet.swift" \
  \
  "$SCRIPT_DIR/Sources/DiskDetective/ScanEngine.swift" \
  "$SCRIPT_DIR/Sources/DiskDetective/DiskScanView.swift" \
  "$SCRIPT_DIR/Sources/DiskDetective/DiskDetectiveView.swift" \
  "$SCRIPT_DIR/Sources/DiskDetective/TimeMachineView.swift" \
  "$SCRIPT_DIR/Sources/DiskDetective/HistoryView.swift" \
  "$SCRIPT_DIR/Sources/DiskDetective/AppCleanerView.swift" \
  "$SCRIPT_DIR/Sources/DiskDetective/FolderSizeView.swift" \
  "$SCRIPT_DIR/Sources/DiskDetective/DevScanWalker.swift" \
  \
  "$SCRIPT_DIR/Sources/CleanUninstall/AppState.swift" \
  "$SCRIPT_DIR/Sources/CleanUninstall/InstalledAppsView.swift" \
  "$SCRIPT_DIR/Sources/CleanUninstall/Cleaner.swift" \
  "$SCRIPT_DIR/Sources/CleanUninstall/LoginItem.swift" \
  "$SCRIPT_DIR/Sources/CleanUninstall/SoundPlayer.swift" \
  "$SCRIPT_DIR/Sources/CleanUninstall/LeftoverFile.swift" \
  "$SCRIPT_DIR/Sources/CleanUninstall/TrashedApp.swift" \
  "$SCRIPT_DIR/Sources/CleanUninstall/LeftoverScanner.swift" \
  "$SCRIPT_DIR/Sources/CleanUninstall/ScanLocations.swift" \
  "$SCRIPT_DIR/Sources/CleanUninstall/TrashWatcher.swift" \
  "$SCRIPT_DIR/Sources/CleanUninstall/MainView.swift" \
  "$SCRIPT_DIR/Sources/CleanUninstall/SettingsView.swift" \
  \
  "$SCRIPT_DIR/Sources/StartupManager/StartupItem.swift" \
  "$SCRIPT_DIR/Sources/StartupManager/StartupScanner.swift" \
  "$SCRIPT_DIR/Sources/StartupManager/StartupManagerView.swift" \
  \
  "$SCRIPT_DIR/Sources/LLMScanner/LLMModel.swift" \
  "$SCRIPT_DIR/Sources/LLMScanner/LLMScanner.swift" \
  "$SCRIPT_DIR/Sources/LLMScanner/LLMScannerView.swift" \
  \
  "$SCRIPT_DIR/Sources/ClaudeCleanup/ClaudeCleanupItem.swift" \
  "$SCRIPT_DIR/Sources/ClaudeCleanup/ClaudeCleanupScanner.swift" \
  "$SCRIPT_DIR/Sources/ClaudeCleanup/ClaudeSkillItem.swift" \
  "$SCRIPT_DIR/Sources/ClaudeCleanup/ClaudeSkillsScanner.swift" \
  "$SCRIPT_DIR/Sources/ClaudeCleanup/ClaudeCleanupView.swift" \
  -o "$BINARY_DIR/$APP_NAME"

# Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>ACleaner</string>
    <key>CFBundleDisplayName</key>
    <string>ACleaner</string>
    <key>CFBundleIdentifier</key>
    <string>com.user.ACleaner</string>
    <key>CFBundleVersion</key>
    <string>1.2.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.2.0</string>
    <key>CFBundleExecutable</key>
    <string>ACleaner</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

# Code signing — sign with a STABLE identity so the code signature (and
# therefore the Full Disk Access grant, which macOS ties to it) stays the same
# across rebuilds. Preference order:
#   1. A real Apple Development / Developer ID certificate, if one exists.
#   2. The local self-signed "ACleaner Local Signing" certificate, kept in a
#      dedicated keychain (~/Library/Keychains/acleaner-signing.keychain-db).
#      Set up once; see docs/signing.md. It is untrusted for distribution but
#      gives a STABLE identity, which is all TCC needs to keep the grant.
#   3. Ad-hoc (the old behaviour) — only if neither of the above is available,
#      in which case Full Disk Access must be re-granted after every rebuild.
SIGN_KC="$HOME/Library/Keychains/acleaner-signing.keychain-db"
STABLE_CERT_NAME="ACleaner Local Signing"

IDENTITY=""
SIGN_KC_ARG=""

APPLE_ID=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -E '"(Apple Development|Mac Developer|Developer ID)' \
  | head -1 \
  | sed -E 's/.*"(.+)".*/\1/')

if [ -n "$APPLE_ID" ]; then
  IDENTITY="$APPLE_ID"
elif [ -f "$SIGN_KC" ] && security find-identity -p codesigning "$SIGN_KC" 2>/dev/null | grep -q "$STABLE_CERT_NAME"; then
  # Unlock the dedicated keychain (it locks on logout/reboot) so codesign can
  # use the key without an interactive prompt. Password is intentionally a
  # fixed local value — the cert protects nothing of value off this machine.
  security unlock-keychain -p acleaner "$SIGN_KC" >/dev/null 2>&1 || true
  IDENTITY="$STABLE_CERT_NAME"
  SIGN_KC_ARG="--keychain $SIGN_KC"
fi

SIGNED_STABLE=0
if [ -n "$IDENTITY" ]; then
  if codesign --sign "$IDENTITY" $SIGN_KC_ARG --force --deep "$APP_BUNDLE" 2>/dev/null; then
    echo "Signed with stable identity: $IDENTITY"
    SIGNED_STABLE=1
  else
    codesign --sign - --force --deep "$APP_BUNDLE" 2>/dev/null || true
    echo "(stable signing failed — fell back to ad-hoc)"
  fi
else
  codesign --sign - --force --deep "$APP_BUNDLE" 2>/dev/null || true
fi

echo ""
echo "Build complete — ACleaner.app installed in /Applications."
echo ""

if [ "$SIGNED_STABLE" = "1" ]; then
  echo "This build is signed with a stable identity, so Full Disk Access will"
  echo "persist across future rebuilds. If this is the FIRST build after setting"
  echo "up signing, grant Full Disk Access one final time (System Settings >"
  echo "Privacy & Security > Full Disk Access, remove ACleaner if listed, then add"
  echo "/Applications/ACleaner.app). After that, it stays granted."
  echo ""
else
  echo "IMPORTANT: This build is ad-hoc signed (no stable identity found). macOS"
  echo "ties Full Disk Access to the code signature, and an ad-hoc signature"
  echo "changes on EVERY rebuild, so the grant will need re-adding each time."
  echo ""
  echo "To set up stable signing once, see docs/signing.md."
  echo ""
fi

echo "NOTE: If macOS says the developer cannot be verified, right-click the"
echo "app icon, choose Open, then click Open in the dialog."
echo ""

open "$APP_BUNDLE"
