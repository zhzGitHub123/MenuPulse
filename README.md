**English** | [简体中文](README.zh-CN.md)

# MenuPulse

A minimal macOS menu bar monitor that shows **network throughput** and **CPU usage** in real time, right in your status bar.

![MenuPulse sitting in the macOS menu bar](docs/screenshot.png)

Two lines of monospaced text in a compact block. No main window, no Dock icon — install it and forget it's there. It holds **14 MB** of memory, ships as a **233 KB** binary, and keeps CPU under **1% of a single core** while sampling.

## Features

- **Featherweight** — 14 MB resident, zero third-party dependencies, no SwiftUI runtime, no render loop
- **Both metrics at a glance** — upload/download speed and CPU usage side by side, no panel to open
- **Power aware** — sampling pauses on screen sleep, session switch, and system sleep, and resumes on wake
- **Idle throttling** — when the network is quiet and the CPU is idle, the sampling interval stretches out to cut wakeups
- **Adaptive appearance** — the status item renders as a template image and follows the light/dark menu bar automatically
- **Stable width** — the status bar width adjusts smoothly as values grow and shrink, without jitter
- **Accessible** — full VoiceOver labels
- **Zero dependencies** — pure AppKit, no third-party libraries
- **Sandboxed** — App Sandbox enabled, requests only what it needs

## Performance

A menu bar monitor that costs you measurable battery life defeats its own purpose. These are measured numbers, not estimates — reproduce them yourself with Activity Monitor and `footprint`.

| | Measured |
| --- | --- |
| Memory footprint | **14 MB** (`phys_footprint`, peak equals steady state) |
| CPU while sampling | **~0.6%** of one core, over a 300 s window — the scale Activity Monitor reports |
| Executable size | **233 KB** |
| Third-party dependencies | **0** |

Where that comes from:

- **No SwiftUI runtime.** A SwiftUI `MenuBarExtra` keeps a rendering pipeline resident for the lifetime of the app. MenuPulse is plain AppKit with a single `NSStatusItem` — there is no view hierarchy to diff and no render loop to run.
- **Nothing heavy on the main thread.** Sampling happens on a dedicated `utility` QoS queue. The main thread only ever assigns a string to the status item's title.
- **Coalesced wakeups.** The timer carries 400 ms of leeway, which lets the kernel batch this app's wakeup with work it was already going to do. Timer coalescing is where most of the energy savings in a periodic app actually come from — a rigid timer forces a dedicated wakeup every cycle.
- **Idle throttling.** Once both directions stay under 1 KB/s and CPU under 10% for five consecutive samples, the interval stretches and the leeway widens. Any real activity resets the streak instantly, so responsiveness is not traded away.
- **No redundant redraws.** The status bar is repainted only when the rendered title actually differs from what's already on screen. A steady 0 B/s costs zero drawing.
- **A full stop, not a slowdown.** On screen sleep, session switch, or system sleep, the timer is torn down entirely — not merely slowed. Nothing samples, nothing draws, nothing wakes the CPU until the state clears.

Every metric comes from a direct kernel call (`sysctl`, `host_statistics`). There is no polling of external processes, no shelling out, no network traffic, and no disk I/O in the sampling path.

## Requirements

- macOS 15.1 or later
- Xcode 16 or later to build from source

## Install

### Download a prebuilt binary

Grab `MenuPulse.zip` from the [latest release](https://github.com/zhzGitHub123/MenuPulse/releases/latest), unzip it, and move `MenuPulse.app` into your Applications folder.

The app is **not notarized by Apple**, so macOS will refuse to open it the first time — usually with "cannot be opened because the developer cannot be verified" or "is damaged". Nothing is actually damaged; the app simply isn't enrolled in the Apple Developer Program. Clear the quarantine attribute once and it runs normally:

```bash
xattr -cr /Applications/MenuPulse.app
```

If you'd rather not run an unsigned binary, build it yourself — the source is right here.

### Build with Xcode

```bash
open MenuPulse.xcodeproj
```

Select the `MenuPulse` scheme and press ⌘R.

### Build from the command line

```bash
xcodebuild -project MenuPulse.xcodeproj -scheme MenuPulse -configuration Release -derivedDataPath DerivedData build
```

The product lands in `DerivedData/Build/Products/Release/MenuPulse.app`. Drag it into your Applications folder.

## Usage

The app lives entirely in the menu bar and **never appears in the Dock or the ⌘Tab switcher** (it uses the `.accessory` activation policy).

Click the status item to open its menu, which currently holds a single entry:

| Menu item | Shortcut |
| --- | --- |
| Quit | ⌘Q |

## How it works

### Data collection

| Metric | Source |
| --- | --- |
| Network speed | Interface byte counters read via `sysctl`, differenced between consecutive samples |
| CPU usage | Tick counts from `host_statistics(HOST_CPU_LOAD_INFO)`, computed from user/system/nice/idle deltas |

Both are **deltas rather than instantaneous readings**, so the first sample produces no output — data starts flowing from the second one.

Elapsed time comes from `ProcessInfo.systemUptime` rather than the wall clock, so changing the system time or time zone won't produce bogus speed values.

Counter wraparound is handled differently for each metric:

- **CPU** — tick values are 32-bit `natural_t`; after a wrap the delta is corrected against `UInt32.max` and remains usable
- **Network** — a counter that moves backwards marks the sample as untrustworthy, and it is **discarded** so the next cycle starts fresh

### Sampling strategy

- Base interval is **2 seconds**, with **400 ms** of leeway so the system can coalesce wakeups
- When both directions stay under **1 KB/s** and CPU stays under **10%** for **5 consecutive samples**, the app switches to a longer idle cadence with more leeway. Any activity resets the streak immediately, so the next sample is back at full rate
- Sampling runs on a dedicated `utility` QoS queue and never blocks the main thread
- The status bar is redrawn only when the title actually changes

### Pause conditions

Monitoring depends on two things: whether the status item is visible, and whether any pause reason is active. Pause reasons are represented as an `OptionSet` and can stack:

| Reason | Triggering notification |
| --- | --- |
| Screens asleep | `screensDidSleepNotification` |
| Session inactive | `sessionDidResignActiveNotification` |
| System sleeping | `willSleepNotification` |

Sampling resumes only when all three are cleared and the status item is visible. Each restart bumps a generation counter so stale callbacks from the previous round are dropped, preventing a race from putting outdated data on screen.

## Tooling

`Tools/GenerateAppIcon.swift` generates the full set of app icon assets.

## License

[MIT](LICENSE) © 2026 zhzGitHub123
