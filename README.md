# ACleaner

A **VoiceOver-first** macOS maintenance suite that bundles three tools into one native app:

- **Updater** — keep Homebrew and Mac App Store apps up to date
- **Disk Detective** — find and remove what's eating your disk space
- **Clean Uninstall** — clean up leftover files when you trash an application

Navigate between tools using the sidebar. Each tool runs independently.

---

## Accessibility

ACleaner is built around VoiceOver from the ground up.

- **Sidebar navigation** — each tool is a labelled sidebar item, readable by VoiceOver without guesswork.
- **One element per row** — every list row reads as a single, complete item (name, version, size, state).
- **Rotor actions** — VoiceOver rotor actions are available on every interactive row.
- **Spoken announcements** — key milestones (scan complete, update started, cleanup done) are announced automatically.
- **No spinners or TUIs** — all progress is plain text, streamed line by line.
- **Native password dialogs** — admin prompts use the standard macOS authorization dialog.

---

## Tools

### Updater
Scans Homebrew formulae, Homebrew casks, and the Mac App Store. Shows download sizes and release notes. Lets you skip apps you manage elsewhere.

**Requires:** [Homebrew](https://brew.sh) · [`mas`](https://github.com/mas-cli/mas) (optional, for App Store updates)

### Disk Detective
Scans over 30 known locations for caches, logs, backups, and large files. Collapsible categories, a category filter, and safe-item selection make it easy to reclaim space without removing anything important.

### Clean Uninstall
Watches the Trash. When you move an application there, it scans for leftover preferences, caches, and support files and offers to remove them in one step.

---

## Requirements

- macOS 13 (Ventura) or newer
- Xcode command-line tools (`xcode-select --install`)

---

## Install

### Option 1 — Build from source

```bash
git clone https://github.com/radcan1/ACleaner.git
cd ACleaner
./build.sh
```

`build.sh` compiles the app, writes `ACleaner.app` to your Desktop, signs it, and opens it. No Gatekeeper prompt when built locally.

### Option 2 — Download

Go to the [Releases](../../releases) page, download `ACleaner.zip`, unpack it, and drag `ACleaner.app` to `/Applications`. Then clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine /Applications/ACleaner.app
```

---

## Usage

The window has a sidebar on the left with three items. Click or use VoiceOver to select a tool.

### Updater
- **Check for Updates** (Cmd-R) — scans Homebrew and the App Store
- **Update Selected** (Cmd-Return) — updates ticked items
- **Update All** (Cmd-Shift-A) — selects and updates everything
- **Skipped** button (top-right) — review apps you've chosen to skip

### Disk Detective
- **Scan Now** (Cmd-R) — runs the disk scan
- **Select Safe Items** — selects only items that delete automatically
- **Delete Selected** (Cmd-Delete) — moves selected items to the Trash
- Use the **Filter** button to show or hide categories

### Clean Uninstall
- Turn on **Watch Trash** to start monitoring
- When an app is trashed, click **Scan for leftover files**, review the list, and click **Move selected to Trash**

---

## Privacy

Everything runs locally. The only network requests are to Homebrew's API and Apple's public iTunes Lookup API to fetch update sizes and release notes — no accounts, no telemetry, no analytics.

## License

[MIT](LICENSE)
