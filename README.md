# Uberkey

Caps Lock becomes the Uber key — one key standing in for ⌃⌥⌘. A native, dependency-free
reimplementation of [hyperkey.app](https://hyperkey.app/): one 500-line Swift file, no
Homebrew, no Karabiner, no DriverKit.

```bash
./make-cert.sh                  # once: signing identity so grants survive rebuilds
./build.sh && ./install.sh
```

Then grant **System Settings › Privacy & Security › Accessibility → Uberkey**. The menu
bar icon carries a warning badge until access is granted; the app then picks it up on its
own within ~15 seconds.

The concept is usually called a "hyper key" — Alfred and Raycast both use that word in
their own shortcut UI — but nothing here depends on
[hyperkey.app](https://hyperkey.app/); Uberkey links only against Apple system frameworks.

## Which modifiers

**⌃⌥⌘ by default — not ⌃⌥⇧⌘.** This matches Hyperkey, whose `hyperFlags` default is
`1835008` (control + option + command). It matters more than it looks: launcher hotkeys are
bound to an exact chord, so sending a fourth modifier makes it a *different* shortcut and
nothing fires. If you have used Hyperkey, your existing Alfred and Raycast bindings expect
these three. Change the set from **Uber key sends** in the menu bar if you need to.

## How it works

1. Physical Caps Lock is remapped to **F18** via `hidutil`, so macOS stops treating it as a
   lock key. The app does this itself on launch, again on wake, and again whenever a
   keyboard is connected — and undoes it when you quit or switch it off.
2. A `CGEventTap` swallows F18 and emits the modifiers as **real `flagsChanged` events**,
   one at a time with a cumulative flag set, exactly as a keyboard reports a chord. It also
   stamps the flags onto keys pressed while it is held, so both kinds of consumer see them.
   A 10-second watchdog force-releases the modifiers if a key-up is ever missed, so stuck
   modifiers are not a risk.
3. A tap on its own — under 1 second, no other key — sends **Escape**, switchable to
   **Caps Lock** or **Nothing**.

Emitting real modifiers rather than only stamping flags is the part that matters for
launchers: a shortcut registered with the OS is matched against actual modifier state, not
against the flags on a key event.

## Menu bar

- **Uber Key: On / Off** — pause the tap without uninstalling
- **Quick tap sends** — Escape / Caps Lock / Nothing
- **Uber key sends** — Control / Option / Shift / Command, individually
- **Remap Caps Lock to Uber Key** — off hands Caps Lock back to macOS as a normal Caps Lock,
  which also means no hyper key until you switch it on again
- **Quit Uberkey** — clears the remap on the way out, so Caps Lock is never left dead

The icon is an outline when idle and **fills while the key is held**, which is the quickest
way to tell whether Uberkey is firing or the receiving app is ignoring the chord. It gains
a warning badge when Accessibility access is missing.

Quit really quits: the launch agent uses `KeepAlive: SuccessfulExit=false`, so a clean exit
stays dead while the wait-for-Accessibility retry, which exits non-zero, is respawned.

## Not getting stuck

Three things guard against the failure modes that make a keyboard tool feel broken:

- **One instance only.** Two would each install a tap and each emit the chord, so a single
  press would send it twice. The second instance takes the `flock`, fails, and exits.
- **Modifiers are dropped on sleep, screen lock, and fast user switch**, because a key-up
  never arrives if the Mac sleeps mid-hold.
- **A 10-second watchdog** releases them if a key-up is missed for any other reason.

## Files

| | |
|---|---|
| `Uberkey.swift` | the whole app |
| `build.sh` | compiles, signs, and restarts the launch agent |
| `install.sh` | login agent; `--uninstall` to remove |
| `make-cert.sh` | run-once signing identity |
| `make-icon.swift` | renders `Uberkey.icns` from an SF Symbol |

## State it keeps

- `~/Library/Application Support/Uberkey/status` — `live` or `waiting-for-accessibility`
- `~/Library/Application Support/Uberkey/lock` — `flock`ed for the process lifetime; a
  second instance sees it, logs why, and exits 0
- `~/Library/Application Support/Uberkey/log` — off by default. Enable with
  `defaults write agency.honcho.uberkey log -bool true` (takes effect immediately, no
  restart). Records hyper key events only, never which other key was pressed; that would
  make it a keylogger.
- Settings live in `defaults read agency.honcho.uberkey`

## Why the certificate

TCC stores an app's *designated requirement*. Ad-hoc signing makes that the cdhash, which
changes on every build — so each rebuild silently voided the Accessibility grant while
leaving the checkbox switched on, the "enabled but nothing works" state. `make-cert.sh`
creates a stable self-signed identity, making the requirement:

```
identifier "agency.honcho.uberkey" and certificate leaf = H"<cert hash>"
```

Identical across rebuilds, so the grant sticks. `build.sh` uses the identity when present
and falls back to ad-hoc plus a `tccutil reset` — so the failure is at least honest — when
it is not.

## Diagnosing it

```bash
~/Applications/Uberkey.app/Contents/MacOS/Uberkey --doctor
```

Prints the bundle, whether an instance holds the lock, tap state, key mapping, the modifier
set, every setting, launch agent state, and the signature. Exits non-zero with a list of
problems if anything is wrong, so it works as a check and not just a readout. This is the
first thing to run if the key ever stops working — every debugging session on this app so
far began by assembling the same facts by hand.

## Self-test

```bash
swiftc -Onone -o /tmp/uberkey Uberkey.swift -framework Cocoa -framework IOKit && /tmp/uberkey --selftest
```

Covers the quick-tap decision and locks the default modifier set to `1835008`.

## Uninstall

```bash
./install.sh --uninstall
```

Removes the launch agent, clears the key mapping, and restores Caps Lock. Then delete
`~/Applications/Uberkey.app`.

## Known limits

- `AXIsProcessTrusted()` caches per process, so a running app cannot notice a grant made
  while it is running. Uberkey retries in a fresh process every ~15s rather than polling in
  place.
- **The app cannot be double-clicked, and Finder draws a prohibitory badge on its icon.**
  The certificate is self-signed rather than notarised, so `spctl` rejects it
  (`origin=Uberkey Self-Signed`) even though `codesign --verify` passes. This does not
  affect operation: launchd starts the executable by path, which bypasses Gatekeeper's
  app-launch assessment. To make it launchable by hand, add an exception —
  `sudo spctl --add ~/Applications/Uberkey.app` — which needs an admin password. This is
  the price of the grant surviving rebuilds; ad-hoc signing is double-clickable but voids
  the grant on every build.
- Copying the bundle to another Mac will not work for the same reason. Run `make-cert.sh`
  and `build.sh` there instead.
- The optional log has no rotation, so if you turn it on, turn it off again.
- Releasing the hyper key resets to no modifiers rather than to the real hardware state, so
  tapping it while physically holding e.g. Shift briefly drops that Shift. The next
  physical modifier event corrects it.
