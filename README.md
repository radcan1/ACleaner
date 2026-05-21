# ACleaner

**[⬇ Download ACleaner.zip — v1.0.0](https://github.com/radcan1/ACleaner/releases/download/v1.0.0/ACleaner.zip)**

> Unzip, double-click ACleaner.app. If macOS says the developer cannot be verified, right-click the app → **Open** → **Open**.

---

A **VoiceOver-first** macOS maintenance suite that bundles three tools into one native app:

- **Updater** — keep Homebrew and Mac App Store apps up to date
- **Disk Detective** — find and remove what is eating your disk space, including Time Machine local snapshots
- **Clean Uninstall** — automatically clean up leftover files when you move an application to the Trash

Navigate between tools using the sidebar. Each tool runs independently and all state is preserved when switching between them.

---

## Accessibility

ACleaner is built around VoiceOver from the ground up.

- **Sidebar navigation** — each tool is a clearly labelled sidebar item; no guessing, no unlabelled segments.
- **Flat list structure** — the Disk Detective list is fully flat so VoiceOver never needs to interact or uninteract to reach items. Every category header and every result row is at the same level.
- **Enter key activation** — pressing Enter on any focused row toggles its selection; pressing Enter on a category header expands or collapses it.
- **One element per row** — every list row reads as a single, complete item (name, detail, path, size, state). No drilling through sub-elements.
- **Rotor actions** — VoiceOver rotor actions are available on every interactive row (toggle selection, reveal in Finder, copy path, show release notes, skip app).
- **Spoken announcements** — key milestones are announced automatically: scan complete with item count, each app as it starts updating, cleanup done, and app detected in Trash.
- **Auto tab switching** — when Clean Uninstall detects an app in the Trash, ACleaner brings itself to the front and automatically switches to the Clean Uninstall tab so the prompt is immediately visible.
- **No spinners or TUIs** — all progress is plain text, streamed line by line.
- **Native password dialogs** — when admin rights are needed, the standard macOS authorization dialog is used. Terminal never opens.

---

## Tools

### Updater

Scans Homebrew formulae, Homebrew casks, and the Mac App Store for available updates. Shows download sizes and release notes for every item. Lets you skip apps you manage elsewhere — the skip list persists across launches.

**Keyboard shortcuts:**
- Cmd-R — Check for Updates
- Cmd-Return — Update Selected
- Cmd-Shift-A — Update All

**Requires:** [Homebrew](https://brew.sh) · [`mas`](https://github.com/mas-cli/mas) (optional, for App Store updates)

---

### Disk Detective

Scans over 30 known locations for caches, logs, backups, downloads, game data, and more. Results are grouped by category with collapsible sections and a category filter so you can focus on what matters.

**Disk scan:**
- **Scan Now** (Cmd-R) — runs the disk scan across known locations
- **Select Safe Items** — selects only items that delete automatically, leaving anything that needs manual review untouched
- **Delete Selected** (Cmd-Delete) — moves selected items to the Trash
- **Filter** button — show or hide specific categories from results

**Time Machine snapshots:**
- Lists all local Time Machine snapshots with their date, time, and reclaimable size
- Tick individual snapshots or use Select All, then click **Delete Selected**
- A single native macOS password prompt covers the whole batch — Terminal never opens
- The list refreshes automatically after deletion and shows how much space was freed

---

### Clean Uninstall

Watches the Trash in the background. When you move an application to the Trash, ACleaner automatically switches to the Clean Uninstall tab, brings the window to front, and offers to scan for leftover files.

**Workflow:**
1. Move any app to the Trash as normal
2. ACleaner detects it, switches tabs, and shows the detected app
3. Click **Scan for leftover files**
4. Review the list of preferences, caches, and support files found
5. Click **Move selected to Trash** to remove them

The Watch Trash toggle in the header lets you pause monitoring without quitting the app. A login item option is available in Settings to start ACleaner automatically at login.

---

## Privacy & Permissions

On first launch, ACleaner shows a one-time permissions screen. Granting **Full Disk Access** in System Settings lets Disk Detective and Clean Uninstall scan Library folders freely without per-folder prompts.

- The permissions screen only appears once — your choice is remembered permanently
- You can re-open it at any time via **ACleaner menu → Privacy & Permissions**
- Everything runs locally. The only network requests are to Homebrew's API and Apple's iTunes Lookup API to fetch update sizes and release notes — no accounts, no telemetry, no analytics

---

## Requirements

- macOS 13 (Ventura) or newer
- Xcode command-line tools (`xcode-select --install`)
- [Homebrew](https://brew.sh) — for the Updater tool
- [`mas`](https://github.com/mas-cli/mas) — optional, for Mac App Store updates (`brew install mas`)

---

## Install

### Option 1 — Download (easiest)

1. **[Download ACleaner.zip](https://github.com/radcan1/ACleaner/releases/download/v1.0.0/ACleaner.zip)**
2. Unzip it (double-click the zip)
3. Drag `ACleaner.app` anywhere — Desktop, Applications, wherever you like
4. Double-click to open

**First launch only:** macOS will say *"ACleaner cannot be opened because the developer cannot be verified."* This is normal for apps outside the App Store. Right-click (or Control-click) the app → **Open** → **Open** in the dialog. You only need to do this once.

### Option 2 — Build from source

```bash
git clone https://github.com/radcan1/ACleaner.git
cd ACleaner
./build.sh
```

Compiles the app with `swiftc` and places `ACleaner.app` on your Desktop. Requires Xcode command-line tools (`xcode-select --install`).

---

## How it works

ACleaner is a thin native front-end over tools you already have:

- `brew update`, `brew outdated`, `brew upgrade` — Homebrew updates
- `mas outdated`, `mas upgrade`, `mas install` — Mac App Store updates
- `tmutil listlocalsnapshots`, `tmutil deletelocalsnapshots` — Time Machine snapshot management
- `diskutil apfs listSnapshots` — per-snapshot size information
- Homebrew's public JSON API and Apple's iTunes Lookup API — download sizes and release notes
- `FSEventStream` on `~/.Trash` — real-time Trash monitoring for Clean Uninstall
- macOS `Security.framework` authorization — native password prompts, no Terminal

---

## License

[MIT](LICENSE)
