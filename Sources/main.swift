import AppKit

// MARK: - Bootstrap
// The app is an accessory (no Dock icon, no menu bar entry of its own beyond the
// status item); everything it does starts in AppDelegate.applicationDidFinishLaunching.
//   AppDelegate.swift          the panel, hover/scroll/launch behaviour, status wiring
//   AppDelegate+Debug.swift    --flags that replace or script the app for a test run
//   AppDelegate+SelfTest.swift --selftest: gestures, hit regions, the status machine
//   IslandState.swift          notch geometry + the observable state the views render
//   IslandRoot.swift           the collapsed bar / status ledger / expanded modes
//   Status.swift, AXStatus.swift, NetMonitor.swift   where "working" comes from
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
