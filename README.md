# Uberkey

### [⬇ Download Uberkey.dmg](https://github.com/b3nhartl3y/uberkey/releases/latest/download/Uberkey.dmg)

Open it, drag Uberkey into Applications, then **right-click Uberkey and choose Open** the
first time. [Why right-click?](#why-the-scary-warning)

---

Caps Lock becomes the Uber key — one key standing in for ⌃⌥⌘. A native, dependency-free
reimplementation of [hyperkey.app](https://hyperkey.app/): one 500-line Swift file, no
Homebrew, no Karabiner, no DriverKit.

## Install

**Download it** — [latest release](https://github.com/b3nhartl3y/uberkey/releases/latest):

1. Download `Uberkey.dmg` and open it.
2. Drag **Uberkey** into the Applications folder, as the window shows.
3. **Right-click it and choose Open** — not a double-click, the first time. Uberkey is not
   notarised, so macOS refuses a plain double-click and offers no way past it. Right-click
   → Open gives you the "open anyway" button. If it still refuses, go to **System Settings
   › Privacy & Security**, scroll to the bottom, and click **Open Anyway**.
4. Grant **Accessibility** access when asked.

Nothing visible happens when it opens — no window, no Dock icon. Uberkey lives in the
menu bar, so look for the caps-lock icon up there. That is it working, not failing.

It adds itself as a login item, so it starts with your Mac from then on. There is no
installer to run and nothing else to configure.

**Or build from source**, which skips the Gatekeeper warning entirely because the app is
then signed on your own machine:

```bash
git clone https://github.com/b3nhartl3y/uberkey.git
cd uberkey
./install.sh
```

That creates a signing identity on first run, builds into `~/Applications/Uberkey.app`,
and starts it at login. Re-run it to update — every step is idempotent.

`Uberkey.zip` is also on the release if you would rather not mount a disk image.

### Why the scary warning

Getting rid of it needs an Apple Developer account at $99/year plus notarisation, for a
free single-file utility. Building from source avoids it, because a locally signed app is
never quarantined.

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
- **Sideways: switch windows** — the mouse sweep described below
- **Reverse sweep direction** — if left and right come out the wrong way round
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

## Cycling windows with the mouse

Hold the Uber key and **sweep sideways** to move through the windows you have recently been
in. Each sweep moves one window and brings it straight to the front — no overlay, nothing
to confirm. Sweep back the other way to return.

Why it exists: macOS has no equivalent. Cmd-Tab switches *apps* and Cmd-` cycles within
*one* app, but nothing walks recently-used windows across apps — so two Chrome windows and
a Figma file are three separate destinations here, each with its own title.

Details that matter in use:

- **A history of 5**, most recent first, seeded from the windows already open at launch so
  it is never empty after a restart.
- **One sweep, one window** — however far you sweep. An earlier version accumulated raw
  distance, which fired 23 raises in 9 seconds and strobed across the whole list.
  Reversing re-arms instantly; continuing the same way needs a brief pause.
- **Scroll and pointer movement both count.** On a trackpad or Magic Mouse a swipe is
  fingers on the surface, which is a scroll and moves the pointer barely a pixel.
- **Ordinary windows only.** Permission prompts, onboarding panels and sheets were getting
  in and eating slots, so entries are filtered on the window's AX subrole rather than by a
  list of process names.
- **Vertical is ignored on purpose**, so normal scrolling triggers nothing — and macOS
  already switches Spaces on a horizontal swipe of its own, which needs no help from us.

No Accessibility call happens on the event tap's thread. macOS switches off a tap that
responds too slowly, and while it is off keystrokes pass through unmodified — which looks
exactly like a chord randomly failing to fire.

## Files

| | |
|---|---|
| `Uberkey.swift` | the whole app |
| `install.sh` | the entry point: identity, build, login agent; `--uninstall` to remove |
| `build.sh` | compiles, signs, registers the icon, restarts the launch agent |
| `make-cert.sh` | run-once signing identity, called by `install.sh` |
| `make-icon.swift` | renders `Uberkey.icns` from an SF Symbol |
| `make-dmg.sh` | packages the DMG, background image and all |
| `make-zip.sh` | packages a plain zip |

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
