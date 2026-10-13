# PerformanceMonitor macOS menu-bar app

This is the macOS menu-bar frontend for the Rust `perfmon-ffi` collector.

Build the Rust static library first, then build this Swift package:

```sh
cargo build -p perfmon-ffi --release
cd apps/macos-menubar
swift build -c release
```

The executable uses AppKit's `NSStatusItem` and polls the fixed-layout
`PerfmonSnapshot` C ABI once per second. Rust retains ownership of the platform
collector; the macOS frontend owns presentation and the menu-bar lifecycle.

To build a Finder-launchable `.app` with the desktop icon:

```sh
./apps/macos-menubar/build-app.sh "$HOME/Applications/PerformanceMonitor.app"
```

The icon is a performance gauge with a live needle and resource bars, stored in
`Resources/PerformanceMonitor.icns` with its SVG master alongside it.
