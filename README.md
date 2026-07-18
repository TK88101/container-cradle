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

## Requirements

- macOS 15+ on Apple Silicon
- [apple/container](https://github.com/apple/container) 1.1.0 installed and initialized
- Xcode 16+ (only if building from source)

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
- No third-party crash reporting or telemetry. Nothing leaves your machine.
- Upstream dependency is pinned (`exact: 1.1.0`) and isolated behind an
  anti-corruption layer (4 files); the core package cannot even import it.

## License

Apache-2.0. See [LICENSE](LICENSE).
