# Container Cradle

A macOS menu bar app that manages [apple/container](https://github.com/apple/container)
and — crucially — **brings your containers back after the runtime restarts**.

## Why this exists

`apple/container` has no restart policy (`container run` has no `--restart` flag).
When the runtime stops, every container stops with it; when the runtime comes back,
your containers do not. The official CLI does not plan to solve this.

This app runs a resident supervisor that detects apiserver generation changes
(pid + process start time token, not naive down→up edge detection) and
automatically restarts the containers you whitelist. Everything else — lists,
logs, stats, volume/image management — is convenience on top.

## Features

- **Supervisor**: whitelist containers, they come back automatically after
  `container system stop`/`start`, Mac reboots, or runtime crashes.
  Exponential backoff, circuit breaker (with system notification), and a
  manual "start now" escape hatch. Environment-not-ready failures (external
  disk not yet mounted after reboot) never trip the breaker — they retry
  with capped backoff, because that is exactly the moment this app exists for.
- **Container list & details**: status, image, networks; environment variables
  are **redacted at the type level** (`SecretString`) — plaintext cannot reach
  logs, crash reports, or screenshots by construction. Copying a secret uses
  the concealed-pasteboard convention so clipboard managers skip it.
- **Logs**: follow/pause/search/clear, bounded ring buffer (memory-safe for
  chatty containers), log content passes through redaction too.
- **Stats**: CPU% / memory sparklines.
- **Volumes**: shows real allocated size next to the sparse limit
  (`70 MB used / 512 GB max`) so you don't panic-delete a healthy volume;
  deletion requires typing the volume name.
- **Images**: list and delete, with infra images filtered out.
- **Runtime updater**: checks GitHub once a day for a new stable apple/container
  release and asks via a system notification (update now / skip this version).
  **Check for Updates** in the menu upgrades straight away when a newer release
  exists. An upgrade is a planned runtime restart: the app downloads the signed
  installer, asks for your administrator password, stops the runtime, installs,
  starts it again, and brings back every container that was running before —
  not only whitelisted ones. If the install fails after the stop, the runtime
  is started again; if the app is quit or killed mid-upgrade, the next launch
  waits for the install to finish, then starts the runtime and restores the
  containers. Automatic checks can be turned off in the menu.

## Requirements

- macOS 15+ on Apple Silicon
- [apple/container](https://github.com/apple/container) 1.4.1 installed and initialized
  (the app is built against the 1.4.1 client; other runtime versions are untested)
- Xcode 27+ (only if building from source)

## Install

### Option A — build from source (recommended)

```sh
git clone <repo-url>
cd <repo>
xcodebuild -project CradleOfFilth.xcodeproj -scheme CradleOfFilth -configuration Release build
```

The built product is `Container Cradle.app` (the Xcode project keeps its internal
scheme name). Locally built apps carry no quarantine flag, so Gatekeeper does
not object.

### Option B — download the DMG

Release DMGs are currently **unsigned** (no paid Apple Developer membership).
macOS will warn on first launch:

1. Open the DMG, drag the app to Applications.
2. **Right-click the app → Open → Open** (needed once; a plain double-click
   shows a warning with no "Open" button).

The app is not sandboxed by design: it must reach the
`com.apple.container.apiserver` XPC mach service, which sandboxed apps cannot.
Same distribution model as Docker Desktop / OrbStack / Podman Desktop.

## Security posture

- Secrets in container environments are wrapped in `SecretString`:
  `description`, `debugDescription` and `Codable` output `<redacted>`;
  plaintext requires an explicit `.reveal()` call, and a source-level boundary
  test budget counts every such call.
- No third-party crash reporting or telemetry.
- **Network access (runtime updater only).** The app contacts
  `api.github.com` to read the latest apple/container release (at most once a
  day, and only while automatic checks are on, plus whenever you click
  **Check for Updates**), and downloads the installer from
  `github.com/apple/container/releases` (GitHub redirects the download to its
  asset CDN) only when you start an upgrade. Nothing about you or your
  containers is sent. Turn off automatic checks in the menu to stop the daily
  request.
- **Privileged install.** The installer package is checked twice — once by the
  app and again as root right before installing: SHA-256 must match the
  digest published in the GitHub release, the signature must be Apple
  Developer ID Installer from the apple/container team (`UPBK2H6LZM`) and
  notarized, and the package version must be the one you were offered.
  Authorization happens before the runtime is stopped, so cancelling the
  password prompt changes nothing.
- On macOS 27 the password prompt shows only generic system text ("…wants
  administrator access to a script", plus a notice that Apple could not check
  the script for malware); the custom explanation the app passes is not
  displayed. The menu shows which version is being installed and that the
  runtime and running containers will restart while the prompt is open.
- Upstream dependency is pinned (`exact: 1.4.1`) and isolated behind an
  anti-corruption layer (a small, test-enforced allowlist of files); the core
  package cannot even import it.

## Known limitations

- **Registries must speak HTTPS.** Image pulls and container creation always
  use HTTPS. apple/container 1.3.0 removed the `auto` scheme that used to fall
  back to plain HTTP for localhost, private IPs and the internal DNS domain,
  and this app deliberately does not re-implement that downgrade.
  To use an HTTP-only registry, pull with the CLI first, then create the
  container in the app using **the same image reference and platform** — the
  app reuses the local image instead of fetching it again:

  ```sh
  container image pull --scheme http <registry>/<image>:<tag>
  ```

## License

Apache-2.0. See [LICENSE](LICENSE).
