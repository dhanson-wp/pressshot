<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="apps/download/brand/lockup-white.svg">
    <img src="apps/download/brand/lockup-ink.svg" width="360" alt="PressShot">
  </picture>
</p>

<p align="center"><strong>Screenshots and screen recordings that live on your own WordPress site.</strong></p>

<p align="center">
PressShot is a free Mac app that lives in your menu bar. Capture or record, and the file uploads<br>
to your WordPress media library with the link already on your clipboard.
</p>

---

## Why I built it

I wanted the things I capture to live on a site I control, not in someone else's cloud. A screenshot or a quick recording is often the fastest way to explain something, and I'd rather those files sit next to the rest of my work in WordPress, where I can find them, share them, and delete them.

## What it does

- **Captures** an area or the whole screen, including scrolling captures that stitch a long page into one image.
- **Marks up** a capture before you share it: arrows, text, shapes, and blur or pixelate for anything private.
- **Records** an area or the whole screen, with system audio, your microphone, or both. Cut out the parts you don't need before you share.
- **Uploads to WordPress.** Connect a WordPress.com site (private ones included) or a self-hosted site, and uploads go to its media library. Recordings on WordPress.com sites go to VideoPress.
- **Copies the link** as soon as the upload finishes.
- **Keeps a history** of recent captures, so you can get back to one later.

Nothing leaves your Mac until you upload.

## Install

Paste this into Terminal and press Return:

```sh
curl -fsSL https://get-pressshot.space.fast/install.sh | sh
```

It downloads the latest build, checks it, puts PressShot in your Applications folder, and opens it. Run the same line again later to upgrade.

PressShot isn't notarized by Apple yet, so macOS would block a copy downloaded through a browser. The Terminal line skips that. It also means macOS asks for your Mac password on the first upload after each update, so PressShot can read your saved sign-in; choose Always Allow.

You'll need macOS 12.3 or newer, on Apple silicon or Intel. There's a [download page](https://get-pressshot.space.fast) with the same steps, and [INSTALL.md](INSTALL.md) has the full guide, including a section for AI agents installing on someone's behalf.

## Using it

1. Allow Screen Recording when macOS asks, then quit and reopen PressShot.
2. Open Settings, go to Upload destinations, click Connect a site, enter your site's address, and approve PressShot on the WordPress page.
3. Click the PressShot icon in the menu bar and choose what to capture or record.

When the upload finishes, paste the link wherever you need it.

The shortcuts work from anywhere:

| Shortcut | What it does |
| --- | --- |
| ⇧⌥3 | Capture an area |
| ⇧⌥4 | Quick capture: select an area and skip the markup step |
| ⇧⌥5 | Record an area |
| ⇧⌥2 | Record a GIF |

You can change any of them in Settings, and give a shortcut to the actions that don't start with one: capturing or recording the whole screen, scrolling capture, capturing text, and opening your history.

The menu also has an "Open library" item. It's for a companion web library that isn't part of this release, so it stays switched off.

## Privacy

PressShot asks macOS for permission to see your screen, and asks you once, in your browser, to let it upload to your WordPress site. Your sign-in is stored in the macOS Keychain. Captures and recordings stay on your Mac until you upload them, and they only go to a destination you set up.

## For developers

| Location | Purpose |
| --- | --- |
| `apps/macos/` | The Mac app, derived from MacShot; upstream's internal layout is preserved |
| `apps/auth/` | The small sign-in service that completes WordPress.com approval without putting a secret in the app |
| `apps/download/` | The download page served at get-pressshot.space.fast |
| `scripts/` | Packaging and source-import tooling |
| `install.sh` | The installer behind the one-line install |

## Built on MacShot

PressShot is built on [MacShot](https://github.com/sw33tLie/macshot) by sw33tLie, which supplies the capture, markup, and recording tools. Thank you, sw33tLie, for building it in the open.

MacShot v4.4.0 source lives in `apps/macos/` with its upstream license and attribution preserved. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for every bundled dependency. PressShot isn't an official MacShot release.

## License

[GNU General Public License v3.0](LICENSE), the same license as MacShot. If you receive a build, you're entitled to the source, and this repository is where it lives.
