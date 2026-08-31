# NotchDial

Turn your MacBook notch into a playful switcher for your AI coding agents.

Hover the notch, and switch between **Codex / Cursor / Claude** in one of three hand-crafted modes — a pocket universe, a neon sign, or a strip of tear-off tickets. Click, and the app is frontmost in ~12 ms. While an agent is working, its icon and a spinning ring live beside the notch — and a green ✓ lands there the moment it finishes.

https://github.com/user-attachments/assets/39c76579-0f78-4b29-822e-a5045ef01156

| Orbit · Black Hole | Tear Tickets |
| --- | --- |
| ![orbit](docs/demo-orbit.gif) | ![tickets](docs/demo-ticket.gif) |

## Modes

- **Orbit · Black Hole** — a transparent deep-space scene composited straight onto your desktop: lensed starfield, twin nebulae, faint planet silhouettes, an accretion disk in the selected app's brand color. Swipe once and the next app flies in from deep space as a textured planet, bursts apart mid-flight and reassembles as its icon.
- **Neon Sign** — the current agent as a hand-bent neon sign: power-down flicker, letter-by-letter ignition, electric surge on launch.
- **Tear Tickets** — three paper tickets feed out of the notch and sway on real pendulum physics (roots pinned in the slot). Click one to tear its stub along the perforation — commit after tear.

## 🟢 Live agent status in the notch

Kick off a long agent run, switch away, and glance at the notch: while an agent works, the black bar quietly widens — its app icon on the left, a spinner in the app's color on the right. When the task finishes, the spinner pops into a **green ✓ that stays until you actually switch to that app** (or it auto-clears a few seconds after you're already there). Expanded, each mode speaks its own dialect: a rubber-stamped ✓ on the paper ticket, a badge on the orbit icon, a neon tick under the sign.

Two signals, merged per app:

1. **File protocol (precise — agents report themselves).** One word into one file:

   ```bash
   mkdir -p ~/.notchdial/status
   echo working > ~/.notchdial/status/claude-code   # spinner on
   echo done    > ~/.notchdial/status/claude-code   # ✓ until acknowledged
   ```

   The file name is the target's slug: its `name` in `Targets.swift`, lowercased, spaces → `-` (`codex`, `cursor`, `claude-code`). `working` files older than 30 min are ignored (crashed agent); NotchDial deletes the file once the ✓ is acknowledged.

   Claude Code wiring (`~/.claude/settings.json` hooks):

   ```json
   {"hooks": {
     "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "mkdir -p ~/.notchdial/status; echo working > ~/.notchdial/status/claude-code"}]}],
     "Stop":             [{"hooks": [{"type": "command", "command": "echo done > ~/.notchdial/status/claude-code"}]}]
   }}
   ```

   Codex / Cursor / anything else: any hook, wrapper script, or the agent itself running that one `echo` works the same way.

2. **CPU fallback (automatic).** Sustained CPU from an app's process tree — a local build, an export, indexing — flips it to *working* with zero setup, via pure `libproc` syscalls (nothing spawned, no permissions). Sustained-threshold hysteresis filters out typing and scrolling bursts. Note: cloud-side agents streaming into a background window barely touch local CPU — that's exactly what the file protocol is for.

Toggle: menu bar → 工作状态指示, or `defaults write com.dd.notchdial statusEnabled -bool false`.

## ⚡ One-prompt setup with your AI agent

You don't have to configure anything by hand. Paste this into **Claude Code, Codex, or Cursor**, filling in your own three apps:

> Clone https://github.com/kkssoswag/NotchDial and set it up for me. Follow the "Instructions for AI agents" section in its README: replace the three targets with **App 1**, **App 2** and **App 3**, then build, verify and install it.

中文提示词：

> 克隆 https://github.com/kkssoswag/NotchDial 并帮我装好。按照 README 里 "Instructions for AI agents" 一节操作：把三个目标应用换成 **应用1**、**应用2**、**应用3**，然后构建、验证并安装。

## Instructions for AI agents

You are configuring NotchDial for this user's three apps. Environment: a notched MacBook (Apple Silicon), macOS 13+, Xcode Command Line Tools (`xcode-select --install`). No full Xcode, no dependencies.

1. `git clone https://github.com/kkssoswag/NotchDial.git && cd NotchDial`
2. Resolve each app's real bundle path and confirm it exists (`/Applications`, `~/Applications`, `/System/Applications`).
3. Edit the three `AppTarget` entries in `Sources/Targets.swift` — keep **exactly three**, `id` stays `0/1/2` (left-to-right order):
   - `name`: short display name (≤ 8 characters renders best in Neon mode; it also defines the status-file slug — lowercased, spaces → `-`)
   - `path`: absolute path to the `.app` bundle
   - `tint`: the app's brand color
   - `planetHi` / `planetLo`: lighter / darker shades of that color (Orbit-mode planet sprite)
4. In `Sources/TicketView.swift`, the ticket label special-cases target 2 (`tg.id == 2 ? "CLAUDE" : tg.name.uppercased()`). Swap `"CLAUDE"` for a short uppercase label fitting the new app, or reduce the expression to `tg.name.uppercased()`.
5. Icons are loaded from the app bundles at runtime — no asset work needed.
6. Build: `./build.sh` → `build/NotchDial.app` (ad-hoc signed).
7. Verify — both must pass:
   - `./build/NotchDial.app/Contents/MacOS/NotchDial --selftest` → prints `SELFTEST ALL PASS`
   - `defaults write com.dd.notchdial mode -int 2` then `./build/NotchDial.app/Contents/MacOS/NotchDial --clicktest` → prints a `CLICK->` line for each of the three apps (the user can re-pick their preferred mode later from the menu bar, ⌘1/⌘2/⌘3)
8. Install: `pkill -x NotchDial 2>/dev/null; rm -rf /Applications/NotchDial.app && ditto build/NotchDial.app /Applications/NotchDial.app && open /Applications/NotchDial.app`
9. Launch at login (optional — ask the user first): `/Applications/NotchDial.app/Contents/MacOS/NotchDial --enable-login`
10. Tell the user: hover the notch to open; swipe to browse (Orbit/Neon) or click a ticket; the menu-bar capsule icon switches modes.

If you modify UI code, respect these invariants (each one guards a bug that actually shipped): attach gestures **before** `.position`/`.offset`/`.transformEffect`; never animate parametric motion with implicit `withAnimation` — use the timer pattern in `main.swift`; never delay `Launcher.launch` behind an animation; keep icon views outside `TimelineView`; verify visuals with `--film` (offscreen `--snap` drops 3D transforms).

## Manual install

Requirements: macOS 13+, a notched MacBook (Apple Silicon), Xcode Command Line Tools.

```bash
./build.sh
cp -R build/NotchDial.app /Applications/
open /Applications/NotchDial.app
```

## Usage

- Hover the notch to expand; move away to collapse.
- Orbit / Neon: one swipe = one step (momentum is ignored by design); click the centered item to activate the app, Dock-style.
- Tickets: just click a ticket.
- Agent status: spinner beside the notch while an agent works, green ✓ when it finishes — cleared by switching to that app.
- Menu bar capsule icon: switch modes (⌘1/⌘2/⌘3), pause hover trigger, toggle status indicators, launch at login, quit.

## Configure your apps

Targets live in `Sources/Targets.swift` (name / bundle path / brand tint / planet palette) — three entries, edit and rebuild. Or just let your agent do it (see above).

## Debug flags

`--pin` keep expanded · `--snap out.png` offscreen snapshot · `--film dir/` frame-by-frame capture · `--selftest` gesture engine + hit-region + status state-machine tests · `--clicktest` synthesized-click hit-testing test · `--launchtest` measures click→app-activation latency · `--teartest` real tear-launch-retract cycle · `--demo <0|1|2>` scripted showcase run (for screen-recording demos) · `--statustest` scripted status choreography through the real file pipeline · `--cpuprobe` prints each target's measured CPU utilization over 4 s

## License

MIT
