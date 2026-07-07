# Changelog

All notable changes to ACleaner are documented in this file.

## 2026-07-07 — Scan freeze fix, single-pass dev scan, accurate app usage dates, stable signing

### Fixed

**The real cause of scans that never finished: a stderr deadlock**

When measuring folder sizes, `du`'s error output was connected to a pipe that
nothing ever read. Whenever Full Disk Access was missing (which happened on
every ad-hoc rebuild), `du` emitted thousands of "Permission denied" lines,
filled the pipe's ~64 KB buffer, and blocked forever on the write — so its
completion handler never fired and the whole scan hung. This was the true
reason scans appeared to run for 30+ minutes: they were stuck, not slow.

Fixed by routing `du`'s (and every other subprocess helper's) stderr to a null
sink instead of an unread pipe, in `FileSize.swift`, both `shell()` helpers
(`ScanEngine`, `AppCleanerView`), `TimeMachineView`, and `Sudo`. A reproduction
test confirmed the old pattern froze against a permission-denied flood while
the fixed version completed in 0.2 s.

**"Last used" showed "never opened" for apps in daily use**

The Applications list read `kMDItemLastUsedDate` from Spotlight, but modern
macOS returns null for it even for apps used every day (Apple restricted the
field), so every app read as "never opened" — making the list look like it was
recommending deletion of apps you actively use. ACleaner now estimates last-use
from the newest modification time among the folders an app writes to when it
runs (its sandbox container, preferences, saved state, and Application Support
data). Apps touched in the last 14 days are labelled "Recently used — keep it
unless you're sure," and the section is reworded as "your biggest installed
apps, in case you want to uninstall one" rather than a junk list. (Verified:
Word, Excel, Chrome, etc. now show real dates; apps used today are flagged
recently-used.)

### Changed

**Developer-junk discovery: eight home-folder walks collapsed into one**

Finding node_modules, build folders (Rust `target`, Swift `.build`, Flutter
`build`, Next.js `.next`, Nuxt `.nuxt`), Python virtualenvs, `.DS_Store` files,
and stale large files previously ran eight separate full traversals of the home
folder back-to-back, each descending *into* every match (often 100 000+ files
apiece). A new `DevScanWalker` does all of it in a single `find` pass that
prunes `~/Library` and the Trash and never descends into a matched folder. On a
real home folder this completed in ~1.2 s versus the minutes the old approach
took. (Also fixed a latent bug: the old `.next`/`.nuxt`/`.venv` searches used a
path filter that silently excluded the very folders they were looking for.)

**Scan areas now run concurrently**

Known locations, Downloads, SDK caches, and the developer-folder walk run at the
same time rather than one after another, so total scan time is the slowest
single area instead of the sum of all of them. The `/Applications` sizing that
used to run `du` once per app in a sequential shell loop is now a single
parallel batch, and the per-item concurrency limit was raised from 8 to 16.

### Added

**Stable local code signing so Full Disk Access stops resetting**

`build.sh` now signs ACleaner with a stable code-signing identity, so macOS
keeps its Full Disk Access grant across rebuilds instead of treating each
rebuild as a brand-new app. It prefers a real Apple Development / Developer ID
certificate if one exists, and otherwise uses a self-signed "ACleaner Local
Signing" certificate kept in a dedicated keychain
(`~/Library/Keychains/acleaner-signing.keychain-db`), scoped so only
`/usr/bin/codesign` can use it and configured to sign without a password prompt.
Verified stable: two consecutive rebuilds produced a byte-for-byte identical
designated requirement (`certificate leaf = H"…"`), which is what TCC keys on.
Setup and removal are documented in `docs/signing.md`. When no stable identity
is available, the build falls back to ad-hoc signing as before.

## 2026-07-06 — Fix Disk Detective hangs; add scan progress and Stop button

### Fixed

**Disk Detective scans could take 30+ minutes with no way to stop them**

The native file-sizing change from 2026-07-03 fixed a real shell-injection
risk in `du`-based sizing, but did so by replacing `du` with a native
FileManager directory walk everywhere — including for whole known
directories like `~/Library/Caches`, Xcode's DerivedData, and other large
Library folders. That native walk has far more per-file overhead than `du`,
so scanning large folders got dramatically slower: a scan that used to take
well under a minute could take 30+ minutes.

The actual fix was simpler than what shipped on 2026-07-03: the injection
risk came specifically from building a shell command string
(`bash -c "du ... \(path) ..."`), not from using `du` itself. `du` is now
called as a direct executable with the path passed as a plain argument — no
shell ever parses it, so the injection risk stays closed, while sizing
speed is back to where it was before (`Sources/Shared/FileSize.swift`).

Also fixed in passing: a genuine hang regression in `FolderSizeView`, where
sizing logic that should have run in the background was accidentally left
running on the main thread, freezing the app on every visit to Disk
Detective. Confirmed both the speedup and the fix with targeted tests
(file-count timing comparison, and a heartbeat-based test proving the main
thread stays responsive).

### Added

**Scan progress and a Stop button**

Disk Detective previously gave no indication of how far a scan had
progressed and offered no way to cancel one in progress. It now shows a
determinate progress bar and "step N of M" status text as it works through
each scan phase (known locations, Downloads, node_modules, build artifacts,
etc.), and a Stop button that genuinely cancels — including terminating any
`du` process still running, not just refusing to start new ones — and keeps
whatever was found before stopping.

## 2026-07-03 — Performance, safety, and smarter detection (Phase 1 + 2)

A new `Sources/Shared/` module holds logic now used across multiple tools:
`FileSize.swift`, `Announcer.swift`, `CleanupJournal.swift`, `ScanCache.swift`,
`AppTokenMatcher.swift`, `ExclusionStore.swift`.

### Performance

**Native file sizing replaces per-file `du` process spawning**

Disk Detective, the orphan scanner, the Clean Uninstall leftover scanner, and
Claude Cleanup all measured file sizes by spawning `/bin/bash` + `du` once per
item — the orphan scanner alone could spawn hundreds of processes per scan,
sequentially in some code paths. `Sources/Shared/FileSize.swift` replaces
every one of those call sites with `FileManager`'s native directory
enumerator, batched with a bounded `TaskGroup` (max 8 concurrent). This also
closes a shell-injection exposure: every replaced call site had embedded a
*discovered* file path into a bash string, so a folder named with backticks
or `$(...)` would previously have executed as shell code.

Also fixed in passing: the orphan scanner's hidden dot-directory scan
computed each candidate's size via a one-shot shell script, then discarded
that result and re-measured every item individually with a second `du`
process — the second measurement is now removed, reusing the value the
script already computed.

Kept as-is: the one-shot inventory scripts used for the initial `/Applications`
sweep (they run once per scan, not once per item, and never interpolate a
discovered path).

### Safety

**Undo Last Cleanup**

Every deletion in ACleaner already goes through `FileManager.trashItem`
rather than permanent deletion. `CleanupJournal` now records where each
trashed item lands, and an "Undo" button — present in every tool's footer and
the Clean Uninstall done screen — moves the most recent batch back to where
it came from. Restoration fails per-item, never overwriting an existing file
and reporting individually when the Trash copy is gone or the original spot
is occupied.

**Exclusion list for orphan and leftover scans**

A false positive in the orphan scanner or Clean Uninstall's leftover matcher
no longer needs dismissing every time it reappears. Right-click any orphan
group (or use the VoiceOver rotor) to exclude it permanently; a new
"Exclusions" sheet in the Orphaned Files header manages the list. One shared
list covers both scan flows — excluding an app from Orphaned Files also keeps
it out of Clean Uninstall's leftover results for that app.

### Smarter detection

**Leftover matching no longer produces false positives from substring matching**

Clean Uninstall matched leftover files by checking whether the file name
*contained* the app's name as a raw substring — so an app named "Photo" would
match a "Photoshop" folder. The matching logic from the orphan scanner
(word-boundary tokenization, generic-word exclusion, version-suffix
extension matching) is now shared via `AppTokenMatcher` and used by both
scanners, plus a substring fallback specifically against the full bundle ID
for camelCase folder names that don't tokenize cleanly.

**The Clean Uninstall dialog no longer fires for app self-updates**

When an app updates itself (Sparkle, Homebrew, etc.), the old version
typically passes through the Trash while the new one is already installed —
which previously triggered ACleaner's uninstall dialog for an app the user
never meant to remove. Detection now waits 2 seconds and checks whether the
bundle ID still resolves to a live, non-Trash install; if so, it logs a
"Ignored — updated, still installed" event instead of interrupting.

**Last-activity dates on orphan rows**

Each orphan group now shows when its newest file was last modified ("Last
activity: 2 years ago"), fetched in the same enumeration pass as the size
measurement — no extra I/O. Groups touched within the last 30 days get a
"Recently active" caution tag, since those are the riskier deletes.

### Accessibility

**VoiceOver progress announcements during long scans**

Disk Detective and the orphan scanner previously updated only a visual status
label during a scan, leaving VoiceOver users in silence until it finished.
Scans now announce start, throttled progress (at most once every 4 seconds),
and a final summary. LLM Scanner and Claude Cleanup announce start and
completion.

### Persistence

**Scan results and category state survive relaunch**

Disk Detective, Orphaned Files, and LLM Scanner results are cached to disk
and reloaded on next launch, with entries whose paths no longer exist
dropped automatically ("Results from 2 hours ago — press Scan to refresh.").
Disk Detective's collapsed-category state moved from in-memory `@State` to
`@AppStorage` for the same reason.

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
