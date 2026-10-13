# PerformanceMonitor macOS menu-bar app

This is the SwiftUI frontend for the Rust `perfmon-ffi` collector.

Build the Rust static library first, then build this Swift package:

```sh
cargo build -p perfmon-ffi --release
cd apps/macos-menubar
swift build -c release
```

The app uses `MenuBarExtra` and polls the fixed-layout `PerfmonSnapshot` C ABI
once per second. Rust retains ownership of the platform collector; SwiftUI only
owns presentation and the menu-bar lifecycle.
