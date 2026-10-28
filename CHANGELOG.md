# Changelog

## Unreleased

- English is the base language for all interface text. A few status lines,
  tooltips and an error hint were hard-coded in Russian; they are English now.
- Russian translation of the whole interface, used when Russian is the
  preferred language in macOS. Other languages fall back to English.

## 0.6.0 — sleep and network recovery

- Renamed to **Tailbar** (`Tailbar.app`, identifier `app.tailbar.menubar`,
  services `app.tailbar.*`). See INSTALL.md for upgrading from 0.5.
- Tailbar's own artwork: a nine-dot "bridge" glyph in the menu bar
  (connected, exit node, exit node not answering, warning, connecting) and a
  matching Dock icon, both drawn in code. The app no longer reads images from
  the official Tailscale app and contains no third-party code.

- Sleep and wake handling (Settings → Sleep and wake, on by default): with
  INCY/Happ keeping their VPN up during sleep, the app stops Tailscale before
  sleep, waits after wake for Wi-Fi (no deadline, so a hotspot joined by hand
  later still works) and the client's TUN/proxy, then reconnects with the same
  exit node and checks it with `tailscale ping`.
- **Reconnect Tailscale** in the menu bar menu and Settings runs the same
  cycle on demand.
- Network health and repair (Settings, on by default): detects Wi-Fi up but no
  working internet after changing networks, quitting INCY/Happ or turning an
  exit node off. The causes covered: a missing default route, a route into a
  dead tunnel, stale INCY/Tailscale DNS, a stuck exit node, or no answer from
  `captive.apple.com`. The repair stops Tailscale, restarts Wi-Fi and restores
  Tailscale with the same exit node, at most twice automatically. **Repair
  Network** in the menu, Settings and Diagnostics runs it on demand.
- The route helper restores a missing default route from the Wi-Fi gateway.
- The INCY TUN route helper detects a wake, drops its `/1` routes at once,
  and waits 20 s before adding them back.

## 0.5.0 — first public preview

- macOS menu bar and window interface for a separate Homebrew `tailscaled` daemon.
- Device list, search, exit-node controls, connection status, diagnostics, and preferences.
- Automatic local proxy detection for INCY/Happ listeners on ports 10808, 10809, and 10820.
- Top-left status dot: amber when the client app is running without a local listener;
  green when a local listener is available. The Dock icon has a permanent green
  identity dot.
- Optional bootstrap wrapper and IPv4 INCY TUN route helper are included as
  advanced, separately installed scripts.
- Quit closes the interface while leaving the daemon running.

This is a preview for Apple Silicon macOS 15+. The binary is ad-hoc signed,
not notarized. See [installation](docs/INSTALL.md) and [networking limitations](docs/NETWORKING.md).
