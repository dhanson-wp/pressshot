# Install PressShot

PressShot is a macOS menu bar app for screenshots and screen recordings that upload to your WordPress site. It needs macOS 12.3 or newer and runs on Apple silicon and Intel Macs.

## Quick install

Paste this into Terminal and press Return:

```sh
curl -fsSL https://get-pressshot.space.fast/install.sh | sh
```

It downloads the latest build, checks it, puts PressShot in your Applications folder, and opens it. Run the same line again to upgrade.

PressShot isn't notarized by Apple yet. Installing from Terminal avoids the "can't be opened" warning you'd get from a browser download.

## Three things only you can do

No script or agent can do these for you; macOS and WordPress.com ask you directly.

1. **Allow Screen Recording.** macOS asks the first time you capture. Allow it under System Settings > Privacy & Security > Screen & System Audio Recording, then quit and reopen PressShot.
2. **Connect your WordPress site.** Open PressShot Settings > Upload destinations, click Connect a site, enter your site's address, click Yes, I approve of this connection on the WordPress page, and Save. WordPress makes the application password for PressShot, so there's nothing to copy or paste. Your first site becomes the primary destination.
3. **Allow Keychain access.** On the first upload after each update, macOS asks for your Mac password so PressShot can read your saved sign-in. Enter it and choose Always Allow. This repeats after updates until PressShot is signed with an Apple Developer ID.

## For agents

The installer never prompts, so you can run it for someone. Ask for `--json` and read the single JSON line on stdout; everything else goes to stderr.

```sh
curl -fsSL https://get-pressshot.space.fast/install.sh | sh -s -- --json
```

| Option | Environment variable | What it does |
| --- | --- | --- |
| `--check` | `PRESSSHOT_CHECK=1` | Report installed and latest builds; change nothing |
| `--json` | `PRESSSHOT_JSON=1` | One JSON result line on stdout |
| `--no-open` | `PRESSSHOT_NO_OPEN=1` | Don't launch PressShot afterwards |
| `--no-quit` | `PRESSSHOT_NO_QUIT=1` | Fail (exit 5) instead of quitting a running PressShot |
| `--reinstall` | `PRESSSHOT_REINSTALL=1` | Install even when this build is already there |
| `--dir <folder>` | `PRESSSHOT_INSTALL_DIR` | Where `PressShot.app` goes |
| `--feed <url>` | `PRESSSHOT_FEED` | Folder URL holding `latest.json` and the archive |

Result fields: `status`, `version`, `build`, `previous_build`, `path`, `message`, and `needs_human` (the steps above, as a list, after a real install or upgrade).

| `status` | Meaning |
| --- | --- |
| `installed` | Fresh install finished |
| `upgraded` | A different build was replaced |
| `current` | This build was already installed; nothing changed |
| `update_available` | `--check` only: a newer build exists |
| `not_installed` | `--check` only: PressShot isn't on this Mac |
| `failed` | See `message` and the exit code |

| Exit code | Meaning |
| --- | --- |
| 0 | Done, or nothing to do |
| 1 | Unexpected failure; the previous copy was put back if there was one |
| 2 | Bad option, run as root, or no feed configured |
| 3 | This Mac can't run PressShot |
| 4 | Download or verification failed; nothing was installed |
| 5 | PressShot is running and `--no-quit` was given |

Guidance for agents:

- Upgrading quits a running PressShot, which ends any recording in progress. Ask the person first, or pass `--no-quit` and report exit 5.
- After `installed` or `upgraded`, relay every item in `needs_human` to the person. Don't try to click through the Screen Recording, browser approval, or Keychain prompts on their behalf, and never ask for or type their Mac password.
- `pressshot://settings` opens PressShot's Settings window if the person wants a shortcut to step 2.
- Don't run the installer with `sudo`.
- To confirm it's running: `pgrep -x PressShot`.

## What the installer checks

- The archive's size and SHA-256 match `latest.json`.
- The archive holds exactly one `PressShot.app`.
- The app's signature is valid and comes from a certificate listed in `TRUSTED_SIGNERS` in `install.sh`.
- The app's build hash matches the one in `latest.json`.

`latest.json` itself is trusted over HTTPS.

## Publishing a build (maintainers)

1. Build the universal Release app and sign it with a certificate listed in `TRUSTED_SIGNERS` in `install.sh`.
2. Run `scripts/package-release.sh /path/to/PressShot.app /path/to/output-folder` (an output folder outside this repository).
3. Publish `latest.json`, the zip, `install.sh`, and the page in `apps/download/` to https://get-pressshot.space.fast, and attach the zip and `latest.json` to a GitHub release.

PressShot is GPLv3, built on MacShot. Anyone who receives the app is entitled to its source, so the source needs to be available to them when builds are shared.
