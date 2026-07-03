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
  \
  "$SCRIPT_DIR/Sources/main.swift" \
  "$SCRIPT_DIR/Sources/RootView.swift" \
  "$SCRIPT_DIR/Sources/UpdateChecker.swift" \
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
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
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

# Code signing — prefer a stable development cert so TCC grants survive rebuilds
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -E '"(Apple Development|Mac Developer|Developer ID)' \
  | head -1 \
  | sed -E 's/.*"(.+)".*/\1/')

if [ -n "$IDENTITY" ]; then
  codesign --sign "$IDENTITY" --force --deep "$APP_BUNDLE" 2>/dev/null \
    && echo "Signed with: $IDENTITY" \
    || { codesign --sign - --force --deep "$APP_BUNDLE" 2>/dev/null || true
         echo "(fell back to ad-hoc signing)"; }
else
  codesign --sign - --force --deep "$APP_BUNDLE" 2>/dev/null || true
fi

echo ""
echo "Build complete — ACleaner.app installed in /Applications."
echo ""

if [ -z "$IDENTITY" ]; then
  echo "IMPORTANT: No development certificate found, so this build is ad-hoc"
  echo "signed. macOS ties Full Disk Access to the code signature, and an"
  echo "ad-hoc signature changes on EVERY rebuild — so any earlier Full Disk"
  echo "Access grant no longer applies. Without it, Trash watching and the"
  echo "Library scans silently find nothing."
  echo ""
  echo "After each rebuild, re-grant access:"
  echo "  1. Open System Settings, then Privacy and Security, then Full Disk Access."
  echo "  2. Remove ACleaner from the list if present (select it, press the minus button)."
  echo "  3. Press the plus button and add /Applications/ACleaner.app."
  echo "  4. Relaunch ACleaner."
  echo ""
  echo "Permanent fix: open Xcode > Settings > Accounts, add your Apple ID, and"
  echo "this script will automatically sign with a stable certificate instead."
  echo ""
fi

echo "NOTE: If macOS says the developer cannot be verified, right-click the"
echo "app icon, choose Open, then click Open in the dialog."
echo ""

open "$APP_BUNDLE"
