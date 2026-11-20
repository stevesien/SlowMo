# SlowMo 🐢

Brings back **hold Shift (or any key) to minimize windows in slow motion** on modern macOS.

**[Download SlowMo 1.0.1](https://github.com/stevesien/SlowMo/releases/download/v1.0.1/SlowMo-1.0.1.dmg)** (signed and notarized), or read more at **[stevesien.github.io/SlowMo](https://stevesien.github.io/SlowMo/)**.

- macOS 13 Ventura or later, Apple silicon and Intel
- Menu-bar only, no network code, no data collected

## Keeping it running

Tick **Open at login** in SlowMo's menu to keep the tortoise in your menu bar after restarts. SlowMo ticks it the first time you open it.

If you'd rather not keep it running, that's fine: with Shift as your key, slow motion keeps working anyway, because the setting lives in the Dock. Open SlowMo once and forget about it. A big macOS update can reset the Dock's settings, though. If slow motion stops working after one, open SlowMo again. A key other than Shift needs SlowMo running.

## How it works

1. The Dock still contains Apple's slow-motion animation; since High Sierra it is switched off. SlowMo sets `com.apple.dock slow-motion-allowed` back on and restarts the Dock, so Shift + minimize works again.
2. If you pick a different trigger key (Fn, Control, Option, Command or any regular key), SlowMo watches for it and, while it is held, presses a virtual Shift so the Dock sees Shift. This part needs Accessibility permission.

## Build from source

```sh
bash build.sh           # builds SlowMo.app for this Mac
bash build.sh install   # builds, copies to /Applications and launches
bash release.sh         # universal, Developer ID-signed, notarized .dmg
```

Needs the Xcode command-line tools (`xcode-select --install`). `release.sh` also needs a Developer ID Application certificate and stored `notarytool` credentials. It explains both if they're missing.

## Why not the Mac App Store?

The App Store sandbox doesn't allow changing another app's preferences, restarting the Dock, or posting keyboard events, which are the three things SlowMo does.
