//! macOS implementation backed by Darwin sysctl, getifaddrs and statfs APIs.
//!
//! Disk I/O counters are read directly from the macOS IOKit registry.

use super::{DiskCounter, DiskSpace, InterfaceCounter, PlatformMonitor};
use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::io;
use std::mem::size_of;
use std::ptr;
use std::time::{SystemTime, UNIX_EPOCH};

const MAC_PROCESS_NAME_MAX: usize = 64;
const MAC_ENDPOINT_MAX: usize = 128;

#[repr(C)]
#[derive(Clone, Copy)]
struct MacConnectionRaw {
    pid: i32,
    uid: u32,
    protocol: u8,
    state: u8,
    reserved: u16,
    socket_id: u64,
    comm: [libc::c_char; MAC_PROCESS_NAME_MAX],
    local: [libc::c_char; MAC_ENDPOINT_MAX],
    remote: [libc::c_char; MAC_ENDPOINT_MAX],
}

extern "C" {
    fn perfmon_macos_disk_counters(read_bytes: *mut u64, write_bytes: *mut u64) -> i32;
    fn perfmon_macos_list_connections(
        output: *mut MacConnectionRaw,
        capacity: i32,
    ) -> i32;
}

#[derive(Clone, Debug)]
pub struct ProcessConnection {
    pub pid: u32,
    pub uid: u32,
    pub protocol: String,
    pub comm: String,
    pub local: String,
    pub remote: String,
}

pub struct MacOsMonitor;

impl PlatformMonitor for MacOsMonitor {
    fn default_interface(&self) -> io::Result<String> {
        let interfaces = self.interfaces()?;
        interfaces
            .iter()
            .find(|name| name.as_str() == "en0" || name.as_str() == "en1")
            .cloned()
            .or_else(|| interfaces.into_iter().next())
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::NotFound,
                    "no non-loopback network interface found",
                )
            })
    }

    fn interfaces(&self) -> io::Result<Vec<String>> {
        Ok(self
            .network_counters()?
            .into_keys()
            .filter(|name| name != "lo0")
            .collect())
    }

    fn network_counters(&self) -> io::Result<HashMap<String, InterfaceCounter>> {
        let mut result = HashMap::new();
        let mut first: *mut libc::ifaddrs = ptr::null_mut();
        if unsafe { libc::getifaddrs(&mut first) } != 0 {
            return Err(io::Error::last_os_error());
        }

        let mut current = first;
        while !current.is_null() {
            unsafe {
                let ifa = &*current;
                if !ifa.ifa_name.is_null()
                    && !ifa.ifa_addr.is_null()
                    && (*ifa.ifa_addr).sa_family as i32 == libc::AF_LINK
                    && !ifa.ifa_data.is_null()
                {
                    let name = CStr::from_ptr(ifa.ifa_name).to_string_lossy().into_owned();
                    let data = &*(ifa.ifa_data as *const libc::if_data);
                    result.insert(
                        name,
                        InterfaceCounter {
                            rx_bytes: data.ifi_ibytes as u64,
                            tx_bytes: data.ifi_obytes as u64,
                        },
                    );
                }
                current = ifa.ifa_next;
            }
        }
        unsafe { libc::freeifaddrs(first) };
        Ok(result)
    }

    fn host_uptime_seconds(&self) -> Option<f64> {
        let boot: libc::timeval = sysctl_value("kern.boottime")?;
        let boot_seconds = boot.tv_sec as u64;
        let now = SystemTime::now().duration_since(UNIX_EPOCH).ok()?.as_secs();
        Some(now.saturating_sub(boot_seconds) as f64)
    }

    #[allow(deprecated)]
    fn cpu_counters(&self) -> Option<(u64, u64)> {
        let mut info = unsafe { std::mem::zeroed::<libc::host_cpu_load_info_data_t>() };
        let mut count = libc::HOST_CPU_LOAD_INFO_COUNT;
        let result = unsafe {
            libc::host_statistics64(
                libc::mach_host_self(),
                libc::HOST_CPU_LOAD_INFO,
                &mut info as *mut _ as *mut libc::integer_t,
                &mut count,
            )
        };
        if result != 0 {
            return None;
        }
        let ticks = info.cpu_ticks.map(u64::from);
        let total: u64 = ticks.iter().sum();
        let idle = ticks[libc::CPU_STATE_IDLE as usize];
        Some((total.saturating_sub(idle), total))
    }

    #[allow(deprecated)]
    fn memory_used_percent(&self) -> Option<f64> {
        let total: u64 = sysctl_value("hw.memsize")?;
        let page_size: u64 = sysctl_value("hw.pagesize")?;
        let mut info = unsafe { std::mem::zeroed::<libc::vm_statistics64_data_t>() };
        let mut count = libc::HOST_VM_INFO64_COUNT;
        let result = unsafe {
            libc::host_statistics64(
                libc::mach_host_self(),
                libc::HOST_VM_INFO64,
                &mut info as *mut _ as *mut libc::integer_t,
                &mut count,
            )
        };
        if result != 0 {
            return None;
        }
        let free = u64::from(info.free_count);
        let inactive = u64::from(info.inactive_count);
        let speculative = u64::from(info.speculative_count);
        let available = free
            .saturating_add(inactive)
            .saturating_add(speculative)
            .saturating_mul(page_size);
        (total > 0).then_some(total.saturating_sub(available) as f64 / total as f64 * 100.0)
    }

    fn swap_used_percent(&self) -> Option<f64> {
        let usage: VmSwapUsage = sysctl_value("vm.swapusage")?;
        if usage.total == 0 {
            Some(0.0)
        } else {
            Some(usage.used as f64 / usage.total as f64 * 100.0)
        }
    }

    fn disk_space(&self) -> Option<DiskSpace> {
        let path = CString::new("/").ok()?;
        let mut stats = unsafe { std::mem::zeroed::<libc::statfs>() };
        if unsafe { libc::statfs(path.as_ptr(), &mut stats) } != 0 {
            return None;
        }
        let block_size = stats.f_bsize as u64;
        let total = (stats.f_blocks as u64).saturating_mul(block_size);
        let available = (stats.f_bavail as u64).saturating_mul(block_size);
        let used = total.saturating_sub((stats.f_bfree as u64).saturating_mul(block_size));
        let denominator = used.saturating_add(available);
        Some(DiskSpace {
            used_percent: if denominator == 0 {
                0.0
            } else {
                used as f64 / denominator as f64 * 100.0
            },
            total_bytes: total,
            used_bytes: used,
            available_bytes: available,
            device: "rootfs".to_string(),
        })
    }

    fn disk_counters(&self) -> Option<DiskCounter> {
        let mut read_bytes = 0;
        let mut write_bytes = 0;
        let result = unsafe { perfmon_macos_disk_counters(&mut read_bytes, &mut write_bytes) };
        (result == 0).then_some(DiskCounter {
            read_bytes,
            write_bytes,
        })
    }
}

pub fn process_connections() -> io::Result<Vec<ProcessConnection>> {
    let mut raw = vec![MacConnectionRaw {
        pid: 0,
        uid: 0,
        protocol: 0,
        state: 0,
        reserved: 0,
        socket_id: 0,
        comm: [0; MAC_PROCESS_NAME_MAX],
        local: [0; MAC_ENDPOINT_MAX],
        remote: [0; MAC_ENDPOINT_MAX],
    }; 8192];
    let count = unsafe { perfmon_macos_list_connections(raw.as_mut_ptr(), raw.len() as i32) };
    if count < 0 {
        return Err(io::Error::last_os_error());
    }

    raw.truncate((count as usize).min(raw.len()));
    Ok(raw
        .into_iter()
        .filter_map(|connection| {
            let protocol = match connection.protocol as i32 {
                libc::IPPROTO_TCP => "tcp",
                libc::IPPROTO_UDP => "udp",
                _ => return None,
            };
            Some(ProcessConnection {
                pid: connection.pid as u32,
                uid: connection.uid,
                protocol: protocol.to_string(),
                comm: c_string(&connection.comm),
                local: c_string(&connection.local),
                remote: c_string(&connection.remote),
            })
        })
        .collect())
}

fn c_string(buffer: &[libc::c_char]) -> String {
    unsafe { CStr::from_ptr(buffer.as_ptr()) }
        .to_string_lossy()
        .into_owned()
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct VmSwapUsage {
    total: u64,
    avail: u64,
    used: u64,
    pagesize: u32,
    encrypted: u32,
}

fn sysctl_value<T: Copy>(name: &str) -> Option<T> {
    let name = CString::new(name).ok()?;
    let mut value = unsafe { std::mem::zeroed::<T>() };
    let mut size = size_of::<T>();
    let result = unsafe {
        libc::sysctlbyname(
            name.as_ptr(),
            &mut value as *mut T as *mut libc::c_void,
            &mut size,
            ptr::null_mut(),
            0,
        )
    };
    (result == 0 && size == size_of::<T>()).then_some(value)
}
