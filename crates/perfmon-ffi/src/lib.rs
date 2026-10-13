//! Stable C ABI for the native macOS menu-bar frontend.
//!
//! The Swift app consumes this small ABI instead of reaching into Rust's
//! internal data structures. Rust-owned strings and collections never cross
//! the boundary; callers receive a fixed-layout snapshot and own the copy.

use perfmon::platform::{self, DiskCounter, InterfaceCounter, PlatformMonitor};
use std::collections::HashMap;
use std::time::Instant;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct PerfmonSnapshot {
    pub cpu_percent: f64,
    pub memory_percent: f64,
    pub swap_percent: f64,
    pub rx_bytes_per_sec: u64,
    pub tx_bytes_per_sec: u64,
    pub disk_read_bytes_per_sec: u64,
    pub disk_write_bytes_per_sec: u64,
    pub uptime_seconds: f64,
    pub valid: u8,
}

pub struct PerfmonHandle {
    monitor: Box<dyn PlatformMonitor>,
    interface: String,
    previous_network: HashMap<String, InterfaceCounter>,
    previous_cpu: Option<(u64, u64)>,
    previous_disk: Option<DiskCounter>,
    previous_at: Instant,
}

/// Create a monitor using the platform's default network interface.
#[no_mangle]
pub extern "C" fn perfmon_create() -> *mut PerfmonHandle {
    let monitor = platform::current();
    let Ok(interface) = monitor.default_interface() else {
        return std::ptr::null_mut();
    };
    let previous_network = monitor.network_counters().unwrap_or_default();
    Box::into_raw(Box::new(PerfmonHandle {
        monitor,
        interface,
        previous_network,
        previous_cpu: None,
        previous_disk: None,
        previous_at: Instant::now(),
    }))
}

/// Collect the next sample. Returns 1 when the snapshot is valid, otherwise 0.
///
/// # Safety
///
/// `handle` must be a pointer returned by `perfmon_create` that has not been
/// destroyed, and `out` must point to writable storage for one snapshot.
#[no_mangle]
pub unsafe extern "C" fn perfmon_sample(
    handle: *mut PerfmonHandle,
    out: *mut PerfmonSnapshot,
) -> i32 {
    if handle.is_null() || out.is_null() {
        return 0;
    }
    let handle = &mut *handle;
    let now = Instant::now();
    let elapsed = now.duration_since(handle.previous_at).as_secs_f64();
    if elapsed <= 0.0 {
        return 0;
    }

    let networks = handle.monitor.network_counters().unwrap_or_default();
    let (rx_bytes_per_sec, tx_bytes_per_sec) = networks
        .get(&handle.interface)
        .zip(handle.previous_network.get(&handle.interface))
        .map(|(current, previous)| {
            (
                (current.rx_bytes.saturating_sub(previous.rx_bytes) as f64 / elapsed) as u64,
                (current.tx_bytes.saturating_sub(previous.tx_bytes) as f64 / elapsed) as u64,
            )
        })
        .unwrap_or_default();

    let cpu = handle.monitor.cpu_counters();
    let cpu_percent = cpu
        .zip(handle.previous_cpu)
        .and_then(|((busy, total), (old_busy, old_total))| {
            let total_delta = total.saturating_sub(old_total);
            (total_delta > 0).then_some(
                (busy.saturating_sub(old_busy) as f64 / total_delta as f64 * 100.0)
                    .clamp(0.0, 100.0),
            )
        })
        .unwrap_or(0.0);

    let disk = handle.monitor.disk_counters();
    let (disk_read_bytes_per_sec, disk_write_bytes_per_sec) = disk
        .zip(handle.previous_disk)
        .map(|(current, previous)| {
            (
                (current.read_bytes.saturating_sub(previous.read_bytes) as f64 / elapsed) as u64,
                (current.write_bytes.saturating_sub(previous.write_bytes) as f64 / elapsed) as u64,
            )
        })
        .unwrap_or_default();

    *out = PerfmonSnapshot {
        cpu_percent,
        memory_percent: handle.monitor.memory_used_percent().unwrap_or(0.0),
        swap_percent: handle.monitor.swap_used_percent().unwrap_or(0.0),
        rx_bytes_per_sec,
        tx_bytes_per_sec,
        disk_read_bytes_per_sec,
        disk_write_bytes_per_sec,
        uptime_seconds: handle.monitor.host_uptime_seconds().unwrap_or(0.0),
        valid: 1,
    };

    handle.previous_network = networks;
    handle.previous_cpu = cpu;
    handle.previous_disk = disk;
    handle.previous_at = now;
    1
}

/// Destroy a monitor created by `perfmon_create`.
///
/// # Safety
///
/// `handle` must be null or a pointer returned by `perfmon_create` that has not
/// already been destroyed.
#[no_mangle]
pub unsafe extern "C" fn perfmon_destroy(handle: *mut PerfmonHandle) {
    if !handle.is_null() {
        drop(Box::from_raw(handle));
    }
}
