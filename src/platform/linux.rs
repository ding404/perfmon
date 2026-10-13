//! Linux implementation backed by procfs, sysfs and statvfs.

use super::{DiskCounter, DiskSpace, InterfaceCounter, PlatformMonitor};
use std::collections::{HashMap, HashSet};
use std::ffi::CString;
use std::fs;
use std::io;

pub struct LinuxMonitor;

impl PlatformMonitor for LinuxMonitor {
    fn default_interface(&self) -> io::Result<String> {
        let content = fs::read_to_string("/proc/net/route")?;
        for line in content.lines().skip(1) {
            let fields: Vec<&str> = line.split_whitespace().collect();
            if fields.len() >= 8 && fields[1] == "00000000" && fields[7] == "00000000" {
                return Ok(fields[0].to_string());
            }
        }
        self.interfaces()?.into_iter().next().ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                "no non-loopback network interface found",
            )
        })
    }

    fn interfaces(&self) -> io::Result<Vec<String>> {
        let content = fs::read_to_string("/proc/net/dev")?;
        let names: Vec<String> = content
            .lines()
            .skip(2)
            .filter_map(|line| line.trim().split_once(':').map(|(name, _)| name.trim()))
            .filter(|name| !name.is_empty() && *name != "lo")
            .map(str::to_string)
            .collect();
        if names.is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "no non-loopback network interface found",
            ));
        }
        Ok(names)
    }

    fn network_counters(&self) -> io::Result<HashMap<String, InterfaceCounter>> {
        let content = fs::read_to_string("/proc/net/dev")?;
        let mut counters = HashMap::new();
        for line in content.lines().skip(2) {
            let line = line.trim();
            let Some((name, rest)) = line.split_once(':') else {
                continue;
            };
            let fields: Vec<&str> = rest.split_whitespace().collect();
            if fields.len() < 9 {
                continue;
            }
            let (Ok(rx_bytes), Ok(tx_bytes)) = (fields[0].parse(), fields[8].parse()) else {
                continue;
            };
            counters.insert(
                name.trim().to_string(),
                InterfaceCounter { rx_bytes, tx_bytes },
            );
        }
        Ok(counters)
    }

    fn host_uptime_seconds(&self) -> Option<f64> {
        fs::read_to_string("/proc/uptime")
            .ok()?
            .split_whitespace()
            .next()?
            .parse()
            .ok()
    }

    fn cpu_counters(&self) -> Option<(u64, u64)> {
        let content = fs::read_to_string("/proc/stat").ok()?;
        let fields: Vec<u64> = content
            .lines()
            .find(|line| line.starts_with("cpu "))?
            .split_whitespace()
            .skip(1)
            .filter_map(|field| field.parse().ok())
            .collect();
        if fields.len() < 4 {
            return None;
        }
        let total = fields.iter().take(8).sum();
        let idle = fields[3] + fields.get(4).copied().unwrap_or(0);
        Some((total.saturating_sub(idle), total))
    }

    fn memory_used_percent(&self) -> Option<f64> {
        let content = fs::read_to_string("/proc/meminfo").ok()?;
        let mut total = None;
        let mut available = None;
        for line in content.lines() {
            if line.starts_with("MemTotal:") {
                total = line.split_whitespace().nth(1).and_then(|v| v.parse().ok());
            } else if line.starts_with("MemAvailable:") {
                available = line.split_whitespace().nth(1).and_then(|v| v.parse().ok());
            }
        }
        let (total, available) = (total?, available?);
        (total > 0).then_some(total.saturating_sub(available) as f64 / total as f64 * 100.0)
    }

    fn swap_used_percent(&self) -> Option<f64> {
        let content = fs::read_to_string("/proc/meminfo").ok()?;
        let mut total = None;
        let mut free = None;
        for line in content.lines() {
            if line.starts_with("SwapTotal:") {
                total = line.split_whitespace().nth(1).and_then(|v| v.parse().ok());
            } else if line.starts_with("SwapFree:") {
                free = line.split_whitespace().nth(1).and_then(|v| v.parse().ok());
            }
        }
        let total: u64 = total?;
        let free: u64 = free?;
        if total == 0 {
            Some(0.0)
        } else {
            Some(total.saturating_sub(free) as f64 / total as f64 * 100.0)
        }
    }

    fn disk_space(&self) -> Option<DiskSpace> {
        let mounts = fs::read_to_string("/proc/mounts").ok()?;
        let mut seen = HashSet::new();
        let mut best = None;
        for line in mounts.lines() {
            let fields: Vec<&str> = line.split_whitespace().collect();
            if fields.len() < 2 || !fields[0].starts_with("/dev/") {
                continue;
            }
            let path = CString::new(fields[1]).ok()?;
            let mut stat = unsafe { std::mem::zeroed::<libc::stat>() };
            if unsafe { libc::stat(path.as_ptr(), &mut stat) } != 0 || !seen.insert(stat.st_dev) {
                continue;
            }
            let Some((total, used, available)) = statvfs_usage(&path) else {
                continue;
            };
            if best
                .as_ref()
                .is_none_or(|(best_total, _, _, _)| total > *best_total)
            {
                best = Some((total, used, available, fields[0].to_string()));
            }
        }
        let (total, used, available, device) = best.or_else(|| {
            let path = CString::new("/").ok()?;
            let (total, used, available) = statvfs_usage(&path)?;
            Some((total, used, available, "rootfs".to_string()))
        })?;
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
            device,
        })
    }

    fn disk_counters(&self) -> Option<DiskCounter> {
        let devices: HashSet<String> = fs::read_dir("/sys/block")
            .ok()?
            .flatten()
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .collect();
        let content = fs::read_to_string("/proc/diskstats").ok()?;
        let mut read_sectors = 0u64;
        let mut write_sectors = 0u64;
        for line in content.lines() {
            let fields: Vec<&str> = line.split_whitespace().collect();
            if fields.len() < 10 || !devices.contains(fields[2]) {
                continue;
            }
            read_sectors = read_sectors.saturating_add(fields[5].parse().unwrap_or(0));
            write_sectors = write_sectors.saturating_add(fields[9].parse().unwrap_or(0));
        }
        Some(DiskCounter {
            read_bytes: read_sectors.saturating_mul(512),
            write_bytes: write_sectors.saturating_mul(512),
        })
    }
}

fn statvfs_usage(path: &CString) -> Option<(u64, u64, u64)> {
    let mut statvfs = unsafe { std::mem::zeroed::<libc::statvfs>() };
    if unsafe { libc::statvfs(path.as_ptr(), &mut statvfs) } != 0 {
        return None;
    }
    let fragment = if statvfs.f_frsize > 0 {
        statvfs.f_frsize
    } else {
        statvfs.f_bsize
    } as u64;
    let total = (statvfs.f_blocks as u64).saturating_mul(fragment);
    if total == 0 {
        return None;
    }
    let free_total = (statvfs.f_bfree as u64).saturating_mul(fragment);
    let available = (statvfs.f_bavail as u64).saturating_mul(fragment);
    Some((total, total.saturating_sub(free_total), available))
}
