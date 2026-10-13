//! Platform abstraction for performance_monitor.
//!
//! Platform modules expose cumulative counters. Consumers are responsible for
//! converting counter deltas into rates and retaining history. This keeps the
//! Linux and macOS implementations interchangeable for both TUI and SwiftUI.

use std::collections::HashMap;
use std::io;

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "macos")]
mod macos;

#[derive(Clone, Copy, Debug, Default)]
pub struct InterfaceCounter {
    pub rx_bytes: u64,
    pub tx_bytes: u64,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct DiskCounter {
    pub read_bytes: u64,
    pub write_bytes: u64,
}

#[derive(Clone, Debug, Default)]
pub struct DiskSpace {
    pub used_percent: f64,
    pub total_bytes: u64,
    pub used_bytes: u64,
    pub available_bytes: u64,
    pub device: String,
}

pub trait PlatformMonitor {
    fn default_interface(&self) -> io::Result<String>;
    fn interfaces(&self) -> io::Result<Vec<String>>;
    fn network_counters(&self) -> io::Result<HashMap<String, InterfaceCounter>>;
    fn host_uptime_seconds(&self) -> Option<f64>;
    fn cpu_counters(&self) -> Option<(u64, u64)>;
    fn memory_used_percent(&self) -> Option<f64>;
    fn swap_used_percent(&self) -> Option<f64>;
    fn disk_space(&self) -> Option<DiskSpace>;
    fn disk_counters(&self) -> Option<DiskCounter>;
}

#[cfg(target_os = "linux")]
pub fn current() -> Box<dyn PlatformMonitor> {
    Box::new(linux::LinuxMonitor)
}

#[cfg(target_os = "macos")]
pub fn current() -> Box<dyn PlatformMonitor> {
    Box::new(macos::MacOsMonitor)
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
compile_error!("performance_monitor currently supports Linux and macOS only");
