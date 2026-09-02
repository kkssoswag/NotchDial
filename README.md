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

Kick off a long agent run, switch away, and glance at the notch: while an agent works, the black bar grows past the notch — the working apps' icons fan out as an overlapping deck on the left, and a single aggregate glyph sits on the right (spinner while anyone is still working, rubber stamp once they're all done). Each extra agent costs only the overlap step, so the bar stays compact no matter how many are running. When the task finishes, the spinner pops into a **green ✓ that stays until you actually switch to that app** (or it auto-clears a few seconds after you're already there). Expanded, each mode speaks its own dialect: a rubber-stamped ✓ on the paper ticket, a badge on the orbit icon, a neon tick under the sign.

The widened bar is itself a hover target, split by where you enter: glide in over the **notch** and you get the switcher, as always; glide in over the **widened part beside it** and the bar itself grows downward into a small status ledger — one continuous silhouette whose top corners flare out in concave curves, like it's growing out of the screen edge. One receipt row per **session** — its name, which agent it belongs to, and how long it has been running — separated by ticket perforation. **Click a row and that session comes to the front**, by pressing its own sidebar row rather than guessing at a URL scheme; the top strip still passes every click through to the menu bar, and the ledger retracts the moment you leave.

### Where the status comes from

Guessing does not work, and it is worth being blunt about why. Agents increasingly
run in the cloud while the desktop app is just a viewer, so every local proxy is
measuring the wrong thing. Measured on a real session, with the agent's own turn
boundaries as ground truth:

| signal | agent streaming | agent idle |
| --- | --- | --- |
| local storage writes | 26 B/s | **583 B/s** |
| network in | 484 B/s | 193 B/s |
| app CPU | 9.7% | 21.1% |

The idle column is *higher*. Any threshold you pick on those numbers is a coin flip.
So NotchDial reads the truth instead, in this order:

1. **The composer's interrupt control (authoritative, turn-level).** This is the
   one thing in the UI whose meaning is exactly "a turn is in progress", and the
   reason is definitional: a turn is interruptible for precisely as long as it
   lasts, so the stop control exists for precisely that long.

   The obvious-looking signal is the wrong one, and it took a while to see why.
   Claude's sidebar labels a live session `Running <name>` — but that tracks the
   model *emitting tokens*, so it drops out for the entire thirty seconds a tool
   call takes and comes back after. Read that, and a single turn reports
   working → done → working → done → working → done. No amount of better reading
   fixes it; the quantity itself is not the one you want. Measured, same session,
   same minute: six state changes in 30 s before, one in 90 s after.

   `AXWebArea`'s title (`<session> - Claude`) says which session the control
   belongs to, so the composer speaks only for the session on screen. The two
   signals are taken as a **union**, not a hierarchy: measured over 796 sweeps they
   agree 99.6% of the time, and where they disagree each covers the other's blind
   spot — the sidebar flips the instant you hit send but the interrupt control takes
   a beat to render; the interrupt control spans a whole turn but only exists for
   the visible session. Either one alone was wrong in a way the other is right
   about, so it takes both being quiet to call a turn finished.

   Losing sight of a session is not the same as watching it stop. A row that says
   `Mark as unread <name>` settles immediately, and so does the visible session when
   its interrupt control goes; but a session that simply becomes unreadable — a
   partial tree, a re-rendered row, a background agent whose row we lose — is given
   a minute before NotchDial will call it finished.

   Two practical notes, both learned the hard way. Chromium keeps its web
   accessibility tree off until an assistive client opts in (`AXManualAccessibility`),
   and it switches the tree back **off** again when it decides nobody is listening —
   so the opt-in has to be re-asserted or the signal dies silently and never returns.
   And walking that tree is emphatically not free: a full walk every second made all
   three Electron apps report **zero windows** — confirmed against System Events, so
   it is the apps and not this client — and they stayed that way while anything kept
   retrying, coming back a couple of minutes after being left alone. Retrying harder
   is what keeps it down, so the re-assert backs off to five minutes. NotchDial
   locates the rows and the composer once, then re-reads those elements for a couple
   of IPC calls each (measured: 6 nodes, ~1 ms per sweep), and re-walks only to
   discover something new.

   Needs a one-time grant: **menu bar → 精确状态**, or System Settings › Privacy &
   Security › Accessibility › NotchDial. See **Keeping the permission** below if you
   build from source often.

2. **Hooks (exact — the agent tells you).** For **local** Claude Code sessions this
   beats everything above, because nothing you can observe from outside is as good as
   being told. Install the bundled plugin:

   ```bash
   # Claude Code
   /plugin marketplace add kkssoswag/NotchDial
   /plugin install notchdial

   # Codex — same plugin, same hooks.json schema, same two events
   codex plugin marketplace add kkssoswag/NotchDial
   codex plugin add notchdial@notchdial
   ```

   Codex asks you to trust a new hook before it will run it — approve it once in
   the Codex TUI (`1 hook needs review`). Your existing `notify` is untouched.

   `UserPromptSubmit` → working, `Stop` → done, both `async` so they never delay the
   turn they report on. Everything between those two events — every tool call, every
   retry — stays *working*, which is precisely what a sampled UI signal cannot get
   right. Note this covers sessions running **on your Mac**; a session running in
   Anthropic's cloud fires its hooks in the cloud container, so those fall back to
   signal 1.

   Cursor (`~/.cursor/hooks.json`: `beforeSubmitPrompt` / `stop`) can drive the same
   file protocol below.

3.5. **Network inflow (the fallback for a backgrounded app AX went blind on).**
   A long-idle backgrounded Electron app tears its accessibility tree down, and
   neither re-asserting `AXManualAccessibility` nor a brief foreground revives it —
   so signal 1 goes dark in exactly the case that matters, "I switched away, tell me
   when it finishes". Tokens arriving from the cloud do not care about the a11y tree:
   while a turn streams, bytes come in over the websocket; between turns they don't.
   Measured, the separation is clean — idle apps show **zero** inbound bytes, an
   active session shows KB-scale bursts (CPU, by contrast, is noise: an idle app
   spiked to 51%). NotchDial reads per-app inbound bytes from one long-lived `nettop`
   stream and treats sustained inflow (>800 B/s for a couple of seconds) as working,
   a quiet stretch as finished. It only speaks for an app AX cannot currently read,
   and never for the frontmost app (its own UI traffic isn't work). Coarser than the
   AX stop-button — it can't name the session or pin the exact boundary — but it
   works where AX can't. Toggle: `defaults write com.dd.notchdial statusNet -bool false`.

   Cost: the nettop child sits at ~0.4% CPU. It **must** be launched with an idle
   pipe on stdin — nettop keeps an interactive key loop even in `-x -l 0` mode, and
   with `/dev/null` (what a launchd-started GUI app hands its children) that loop
   spins at 120%+ CPU forever. NotchDial does this; if you ever see a hot `nettop`
   under it, that is the bug to look for. NotchDial also retires any other running
   copy of itself on launch, so a redeploy can't stack two instances and two helpers.

3. **File protocol (explicit — agents report themselves).** One word into one file:

   ```bash
   mkdir -p ~/.notchdial/status
   echo working > ~/.notchdial/status/claude-code   # spinner on
   echo done    > ~/.notchdial/status/claude-code   # ✓ until acknowledged
   ```

   The file name is the target's slug: its `name` in `Targets.swift`, lowercased, spaces → `-` (`codex`, `cursor`, `claude-code`). Concurrent sessions each get their own file, `<slug>.<session-id>`, and are aggregated — any session working means the app is working. `working` files older than 30 min are ignored (crashed agent); NotchDial deletes them once the ✓ is acknowledged.

   The plugin above writes exactly this; anything else — a wrapper script, a CI job,
   the agent itself — needs only that one `echo`.

4. **Local-work fallback (only where 1–3 are silent).** Sustained CPU from a
   **background** app's process tree — a local build, an export, indexing — reads as
   *working*, via pure `libproc` syscalls (nothing spawned, no permissions). The
   frontmost app never auto-triggers, because using an app is not the same as the app
   working. This is a guess, and it is switched off per app the moment the
   Accessibility signal can read that app for real.

Toggle: menu bar → 工作状态指示, or `defaults write com.dd.notchdial statusEnabled -bool false`.
Troubleshooting: `defaults write com.dd.notchdial statusDebug -bool true` logs every
signal and state change to `~/Library/Logs/NotchDial/status.log` (mode 0600, rotated
at 4 MB). Matched labels are your chat titles, read out of another app's window, so
they are redacted to a length by default; add `statusDebugLabels -bool true` if you
are tuning `busyPrefixes` and need to see the text.

### Keeping the permission

macOS ties the Accessibility grant to the app's **code signature**, and `build.sh`
falls back to an ad-hoc signature — a new identity every single build. So every
rebuild silently drops the permission, and a stale TCC row can show the toggle ON
while the app is actually denied. If you are iterating on the source, do this once:

1. **Keychain Access → Certificate Assistant → Create a Certificate…**
2. Name `NotchDial Local Signing`, Identity Type **Self Signed Root**,
   Certificate Type **Code Signing**. Create.
3. Rebuild. `build.sh` finds the identity by name and uses it (or set
   `NOTCHDIAL_SIGN_ID` to your own name).

Grant Accessibility once more after that first signed build; from then on the
identity is stable and the grant survives every rebuild. Costs nothing and involves
no Apple account — it is a local certificate, so other people's Macs still treat
your build as unidentified. Shipping to other people is a different problem: that
needs a **Developer ID** certificate plus notarization, which requires the paid
[Apple Developer Program](https://developer.apple.com/programs/) ($99/year). The Mac
App Store is not an option for this app at all — it requires sandboxing, and the
Accessibility API is not available to sandboxed apps.

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
- Agent status: spinner beside the notch while an agent works, rubber stamp when it finishes — cleared by switching to that app; hover the widened bar for the per-agent ledger and click a row to jump.
- Menu bar capsule icon: switch modes (⌘1/⌘2/⌘3), pause hover trigger, toggle status indicators, grant the Accessibility permission that makes status exact, launch at login, quit.

## Configure your apps

Targets live in `Sources/Targets.swift` (name / bundle path / brand tint / planet palette) — three entries, edit and rebuild. Or just let your agent do it (see above).

## Debug flags

`--pin` keep expanded · `--snap out.png` offscreen snapshot · `--film dir/` frame-by-frame capture · `--selftest` gesture engine + hit-region + status state-machine tests · `--clicktest` synthesized-click hit-testing test · `--launchtest` measures click→app-activation latency · `--teartest` real tear-launch-retract cycle · `--demo <0|1|2>` scripted showcase run (for screen-recording demos) · `--statustest` scripted status choreography through the real file pipeline · `--cpuprobe` prints each target's measured CPU utilization over 4 s · `--axprobe` polls the Accessibility signal for 24 s (busy / nodes / ms per app) · `--axdump` lists every button label an app exposes, for tuning `AXStatus.busyPrefixes`

## License

MIT
