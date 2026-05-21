# Installing ACleaner — Step by Step

These instructions are written for VoiceOver users on macOS. Every step is done either in Terminal (by pasting one command) or in System Settings. No mouse needed.

---

## What you need

- A Mac running macOS 13 Ventura or later
- An internet connection
- About 5 minutes

---

## Step 1 — Install the Xcode command-line tools

This is a one-time step. If you have done this before, skip to Step 2.

1. Press **Cmd+Space** to open Spotlight
2. Type **Terminal** and press **Return**
3. In Terminal, paste the following command and press **Return**:

```
xcode-select --install
```

4. A dialog will appear on screen saying *"The xcode-select command requires the command line developer tools"*. VoiceOver will announce it. Press **Return** or click **Install**.
5. Wait for the download to finish. It may take a few minutes depending on your connection. Terminal will not say anything until it is done — this is normal.

---

## Step 2 — Download and build ACleaner

1. Open **Terminal** (Cmd+Space, type Terminal, press Return)
2. Paste the entire line below and press **Return**:

```
git clone https://github.com/radcan1/ACleaner.git ~/ACleaner && cd ~/ACleaner && ./build.sh
```

3. You will see lines of text appearing as it downloads and builds. This takes about 60 seconds on the first run.
4. When it finishes you will hear the message *"Build complete — ACleaner.app is on your Desktop"* and the app will open automatically.

You can close Terminal once the app has opened.

---

## Step 3 — Handle the security warning (first open only)

Because ACleaner is not sold through the Mac App Store, macOS may show a warning the first time it opens. If you see or hear a dialog saying the app *"cannot be opened because the developer cannot be verified"*:

1. Press **Escape** to dismiss that dialog
2. Open **Terminal** again
3. Paste this command and press **Return**:

```
xattr -dr com.apple.quarantine ~/Desktop/ACleaner.app
```

4. Now double-click **ACleaner** on your Desktop, or in Terminal type:

```
open ~/Desktop/ACleaner.app
```

> **Note:** If you built from source using Step 2, you usually will not see this warning at all. It mainly appears when downloading a zip file.

---

## Step 4 — Grant Full Disk Access (recommended)

When ACleaner opens for the first time, a permissions screen will appear. This only happens once.

Granting Full Disk Access lets Disk Detective and Clean Uninstall scan your Library folders without being interrupted by repeated permission prompts every time they run.

1. In the permissions screen, click **Open System Settings**
2. System Settings opens at **Privacy & Security → Full Disk Access**
3. Scroll down the list until you find **ACleaner**
4. Toggle it on. macOS may ask for your password.
5. Switch back to ACleaner
6. Click **Check Again** to confirm the permission was granted
7. Click **Continue** to enter the app

> You will never see this screen again after clicking Continue.

---

## Step 5 — Move ACleaner to your Applications folder (optional)

The build places ACleaner on your Desktop. To move it to Applications:

1. Open **Terminal**
2. Paste this command and press **Return**:

```
mv ~/Desktop/ACleaner.app /Applications/ACleaner.app
```

It will now appear in Launchpad and Spotlight like any other app.

---

## Updating ACleaner in future

When a new version is released, open Terminal and paste:

```
cd ~/ACleaner && git pull && ./build.sh
```

This downloads the latest changes and rebuilds the app in about 60 seconds.

---

## Troubleshooting

**Terminal says "command not found: git"**
Run Step 1 again to install the Xcode command-line tools.

**The build fails with a compiler error**
Run `xcode-select --install` in Terminal to make sure the tools are up to date, then try the build command again.

**ACleaner opens but Clean Uninstall does not detect apps in the Trash**
Go to **System Settings → Privacy & Security → Full Disk Access** and make sure ACleaner is toggled on. If you recently rebuilt the app, you may need to toggle it off and back on.

**The Disk Detective scan asks for permission for each folder**
This means Full Disk Access was not granted. Follow Step 4 above.

---

## Questions or feedback

Post in the [AppleVis forums](https://www.applevis.com) or open an issue at **github.com/radcan1/ACleaner/issues**.
