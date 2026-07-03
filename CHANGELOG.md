# Changelog

All notable changes to ACleaner are documented in this file.

## 2026-07-03 — Trash watcher reliability and orphan grouping

### Fixed

**Clean Uninstall: the detection dialog now appears every time an app is trashed**

Previously the detection dialog could fail to appear when moving an app to the
Trash. Two causes, both fixed:

- `AppState` remembered every detected Trash path in a permanent set, so any
  app that had been detected once in a session could never trigger the dialog
  again — even after being restored and re-trashed, or after the Trash was
  emptied and the same app trashed later. Detection dedup now uses a
  30-second time window instead of a permanent set
  (`Sources/CleanUninstall/AppState.swift`).
- `TrashWatcher`'s polling fallback had the same never-forgets problem in its
  `polledPaths` set. The watcher now maintains a single `knownPaths` set shared
  by both detection mechanisms (FSEvents and the 5-second poll), tracking which
  .app bundles are *currently* in the Trash. Entries are removed the moment an
  item leaves the Trash — either instantly via the FSEvents removal event, or
  on the next poll — so a re-trashed app always fires a fresh detection
  (`Sources/CleanUninstall/TrashWatcher.swift`).

Verified with a standalone harness built from the app's actual watcher code:
trash → one detection; restore + re-trash → new detection; empty Trash +
re-trash → new detection. As a side effect, the internal FSEvents/polling
double-fire per event is now deduped at the watcher level, and app-initiated
uninstalls (`trashAndScan`) suppress the watcher echo *before* the privileged
move runs, closing a race where the dialog could appear twice.

**Disk Detective: orphaned files are now batched per deleted app**

The orphan scanner grouped leftover files by the raw folder/file name found in
each Library directory. One deleted app leaves differently-named traces —
`com.spotify.client` in Preferences, `Spotify` in Application Support,
`spotify` in hidden config directories — which became separate groups
scattered far apart in the size-sorted list. The scanner now merges groups
that share an identifying name token, so each deleted app appears as a single
expandable row containing all of its files
(`Sources/DiskDetective/AppCleanerView.swift`).

Merging rules:

- For reverse-DNS bundle IDs, only the product token identifies the app
  (`com.spotify.client` → `spotify`), so different apps from the same vendor
  (e.g. `com.adobe.Photoshop` vs `com.adobe.Premiere`) do not merge.
- Generic words (`helper`, `client`, `agent`, `desktop`, …) never trigger a
  merge.
- Tokens also match by prefix extension (`sketch` / `sketch3`), with a
  5-character minimum on the shorter side.
- Merged groups take the most human-readable name available, preferring plain
  folder names (`Spotify`) over bundle IDs.

**Build script: builds now reach the copy of the app you actually run**

`build.sh` output ACleaner.app to the Desktop, while the launched copy lived in
`/Applications` — so rebuilds silently never updated the installed app (the
installed binary was over a week older than the source). The script now
installs directly to `/Applications/ACleaner.app`.

### Changed

- `build.sh` now prints step-by-step instructions for re-granting Full Disk
  Access after every ad-hoc-signed rebuild. macOS ties FDA grants to the code
  signature, and ad-hoc signatures change on every build, so a rebuild
  silently revokes FDA — which disables Trash watching and Library scans
  entirely. The permanent fix (adding an Apple ID in Xcode so a stable
  development certificate is used) is also described in the script output.
