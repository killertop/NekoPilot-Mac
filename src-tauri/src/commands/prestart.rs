use serde::Serialize;
use std::fmt;
use std::process::Command;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Manager};

pub const PORT_OCCUPIED_CANNOT_START: &str = "PORT_OCCUPIED_CANNOT_START";

#[derive(Serialize)]
pub struct PrestartCheckResult {
    pub port_occupied: bool,
    pub orphan_pids: Vec<u32>,
    pub foreign_pids: Vec<u32>,
}

#[derive(Serialize)]
pub struct KillOrphansResult {
    pub success: bool,
    pub killed_pids: Vec<u32>,
    pub port_released: bool,
    pub message: String,
}

pub(crate) struct PortCleanupResult {
    pub killed_pids: Vec<u32>,
    pub port_released: bool,
}

#[derive(Debug)]
pub(crate) enum PortCleanupError {
    NoKillableProcess {
        port: u16,
    },
    PortStillOccupied {
        port: u16,
        pids: Vec<u32>,
        killed_pids: Vec<u32>,
        kill_errors: Vec<String>,
    },
    ForeignProcesses {
        port: u16,
        pids: Vec<u32>,
    },
}

impl PortCleanupError {
    pub(crate) fn start_error(&self) -> String {
        format!(
            "{}:{}: port is occupied and NekoPilot could not stop the process",
            PORT_OCCUPIED_CANNOT_START,
            self.port()
        )
    }

    fn port(&self) -> u16 {
        match self {
            Self::NoKillableProcess { port } => *port,
            Self::PortStillOccupied { port, .. } => *port,
            Self::ForeignProcesses { port, .. } => *port,
        }
    }
}

impl fmt::Display for PortCleanupError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NoKillableProcess { port } => {
                write!(f, "port {port} is occupied but no killable listener PID was found")
            }
            Self::PortStillOccupied {
                port,
                pids,
                killed_pids,
                kill_errors,
            } => write!(
                f,
                "port {port} is still occupied after cleanup; pids={pids:?}, killed={killed_pids:?}, errors={kill_errors:?}"
            ),
            Self::ForeignProcesses { port, pids } => {
                write!(f, "port {port} is occupied by a process not owned by NekoPilot: {pids:?}")
            }
        }
    }
}

fn find_pids_on_port(port: u16) -> Vec<u32> {
    #[cfg(target_os = "windows")]
    {
        find_pids_windows(port)
    }
    #[cfg(target_os = "macos")]
    {
        find_pids_macos(port)
    }
    #[cfg(target_os = "linux")]
    {
        find_pids_linux(port)
    }
}

#[cfg(target_os = "windows")]
fn find_pids_windows(port: u16) -> Vec<u32> {
    let Ok(output) = Command::new("netstat").args(["-ano"]).output() else {
        return vec![];
    };

    let text = String::from_utf8_lossy(&output.stdout);
    let mut pids = Vec::new();
    let port_str = port.to_string();

    for line in text.lines() {
        if !line.to_uppercase().contains("LISTENING") {
            continue;
        }
        let parts: Vec<&str> = line.split_whitespace().collect();
        let Some(local_addr) = parts.get(1) else {
            continue;
        };
        if local_addr.rsplit(':').next() != Some(port_str.as_str()) {
            continue;
        }
        if let Some(pid_str) = parts.last() {
            if let Ok(pid) = pid_str.parse::<u32>() {
                if pid != 0 && !pids.contains(&pid) {
                    pids.push(pid);
                }
            }
        }
    }
    pids
}

#[cfg(target_os = "macos")]
fn find_pids_macos(port: u16) -> Vec<u32> {
    let port_arg = format!("TCP:{port}");
    let output = Command::new("lsof")
        .args(["-ti", &port_arg, "-sTCP:LISTEN"])
        .output();

    match output {
        Ok(out) => {
            let text = String::from_utf8_lossy(&out.stdout);
            text.lines()
                .filter_map(|l| l.trim().parse::<u32>().ok())
                .collect()
        }
        Err(_) => vec![],
    }
}

#[cfg(target_os = "linux")]
fn find_pids_linux(port: u16) -> Vec<u32> {
    let port_arg = format!("{port}/tcp");
    let output = Command::new("fuser").arg(port_arg).output();

    match output {
        Ok(out) => {
            let text = String::from_utf8_lossy(&out.stdout);
            let stderr_text = String::from_utf8_lossy(&out.stderr);
            let combined = format!("{}{}", text, stderr_text);
            combined
                .split_whitespace()
                .filter_map(|s| s.parse::<u32>().ok())
                .collect()
        }
        Err(_) => vec![],
    }
}

#[cfg(unix)]
fn process_command(pid: u32, field: &str) -> Option<String> {
    let output = Command::new("ps")
        .args(["-p", &pid.to_string(), "-o", field])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let command = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    (!command.is_empty()).then_some(command)
}

#[cfg(unix)]
fn is_singbox_executable(executable: &str) -> bool {
    let Some(name) = std::path::Path::new(executable.trim())
        .file_name()
        .and_then(|name| name.to_str())
    else {
        return false;
    };
    name == "sing-box" || name.starts_with("sing-box-")
}

#[cfg(unix)]
fn is_owned_singbox_process(executable: &str, command: &str, config_path: &str) -> bool {
    is_singbox_executable(executable)
        && ["-c", "--config"].iter().any(|option| {
            let argument = format!("{option} {config_path}");
            let has_valid_end = |end: usize| {
                end == command.len()
                    || command[end..]
                        .chars()
                        .next()
                        .is_some_and(char::is_whitespace)
            };
            (command.starts_with(&argument) && has_valid_end(argument.len())) || {
                let pattern = format!(" {argument}");
                command.match_indices(&pattern).any(|(start, _)| {
                    let end = start + pattern.len();
                    has_valid_end(end)
                })
            }
        })
}

fn owned_pids(app: &AppHandle, pids: &[u32]) -> Vec<u32> {
    // The old Windows path attempted to invoke Unix `ps`, then treated every
    // failure as "not ours". Keep that fail-closed behavior explicit until a
    // native executable-path + argument query is implemented.
    #[cfg(windows)]
    {
        let _ = (app, pids);
        return Vec::new();
    }

    #[cfg(unix)]
    {
        let Ok(config_dir) = app.path().app_config_dir() else {
            return Vec::new();
        };
        let config_path = config_dir.join("config.json").to_string_lossy().to_string();
        pids.iter()
            .copied()
            .filter(|pid| {
                let executable = process_command(*pid, "comm=");
                let command = process_command(*pid, "command=");
                executable
                    .zip(command)
                    .is_some_and(|(executable, command)| {
                        is_owned_singbox_process(&executable, &command, &config_path)
                    })
            })
            .collect()
    }
}

fn terminate_owned_pid(pid: u32) -> Result<(), String> {
    #[cfg(target_os = "windows")]
    {
        let output = Command::new("taskkill")
            .args(["/PID", &pid.to_string()])
            .output()
            .map_err(|e| e.to_string())?;
        if output.status.success() {
            Ok(())
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
            Err(if stderr.is_empty() { stdout } else { stderr })
        }
    }
    #[cfg(unix)]
    {
        let ret = unsafe { libc::kill(pid as i32, libc::SIGTERM) };
        if ret == 0 {
            Ok(())
        } else {
            Err(std::io::Error::last_os_error().to_string())
        }
    }
}

pub(crate) fn ensure_owned_port_available(
    app: &AppHandle,
    port: u16,
) -> Result<PortCleanupResult, PortCleanupError> {
    if !crate::core::probe_port_listening(port) {
        return Ok(PortCleanupResult {
            killed_pids: vec![],
            port_released: true,
        });
    }

    let pids = find_pids_on_port(port);
    if pids.is_empty() {
        return Err(PortCleanupError::NoKillableProcess { port });
    }

    let owned = owned_pids(app, &pids);
    if owned.len() != pids.len() {
        return Err(PortCleanupError::ForeignProcesses { port, pids });
    }

    let mut killed_pids = Vec::new();
    let mut kill_errors = Vec::new();
    for pid in &owned {
        // Revalidate immediately before signaling to narrow the PID-reuse
        // window between the listener scan and cleanup.
        if !owned_pids(app, &[*pid]).contains(pid) {
            kill_errors.push(format!("pid {}: ownership changed before termination", pid));
            continue;
        }
        match terminate_owned_pid(*pid) {
            Ok(()) => killed_pids.push(*pid),
            Err(e) => kill_errors.push(format!("pid {}: {}", pid, e)),
        }
    }

    let deadline = Instant::now() + Duration::from_secs(3);
    let port_released = loop {
        if !crate::core::probe_port_listening(port) {
            break true;
        }
        if Instant::now() >= deadline {
            break false;
        }
        std::thread::sleep(Duration::from_millis(200));
    };

    if port_released {
        Ok(PortCleanupResult {
            killed_pids,
            port_released,
        })
    } else {
        Err(PortCleanupError::PortStillOccupied {
            port,
            pids,
            killed_pids,
            kill_errors,
        })
    }
}

#[tauri::command]
pub fn prestart_check(app: tauri::AppHandle, port: Option<u16>) -> PrestartCheckResult {
    let port = port.unwrap_or_else(|| crate::core::mixed_proxy_port(&app));
    let port_occupied = crate::core::probe_port_listening(port);
    let all_pids = if port_occupied {
        find_pids_on_port(port)
    } else {
        vec![]
    };
    let orphan_pids = owned_pids(&app, &all_pids);
    let foreign_pids = all_pids
        .iter()
        .copied()
        .filter(|pid| !orphan_pids.contains(pid))
        .collect();
    log::info!(
        "[prestart] check: port={} port_occupied={} owned_pids={:?} foreign_pids={:?}",
        port,
        port_occupied,
        orphan_pids,
        foreign_pids
    );
    PrestartCheckResult {
        port_occupied,
        orphan_pids,
        foreign_pids,
    }
}

#[tauri::command]
pub fn kill_orphans(app: tauri::AppHandle, port: Option<u16>) -> KillOrphansResult {
    let port = port.unwrap_or_else(|| crate::core::mixed_proxy_port(&app));
    let check = prestart_check(app.clone(), Some(port));

    if !check.port_occupied {
        return KillOrphansResult {
            success: true,
            killed_pids: vec![],
            port_released: true,
            message: String::from("no orphans found"),
        };
    }

    if check.orphan_pids.is_empty() {
        let error = PortCleanupError::NoKillableProcess { port };
        return KillOrphansResult {
            success: false,
            killed_pids: vec![],
            port_released: false,
            message: error.start_error(),
        };
    }

    if !check.foreign_pids.is_empty() {
        return KillOrphansResult {
            success: false,
            killed_pids: vec![],
            port_released: false,
            message: format!(
                "{}:{}: port is occupied by another application ({:?})",
                PORT_OCCUPIED_CANNOT_START, port, check.foreign_pids
            ),
        };
    }

    let cleanup = ensure_owned_port_available(&app, port);
    let (killed_pids, port_released, error_message) = match cleanup {
        Ok(result) => (result.killed_pids, result.port_released, None),
        Err(e) => {
            log::warn!("[prestart] kill_orphans failed: {}", e);
            let killed_pids = match &e {
                PortCleanupError::PortStillOccupied { killed_pids, .. } => killed_pids.clone(),
                PortCleanupError::NoKillableProcess { .. }
                | PortCleanupError::ForeignProcesses { .. } => Vec::new(),
            };
            (killed_pids, false, Some(e.start_error()))
        }
    };

    let message = if port_released {
        format!("killed {:?}, port released", killed_pids)
    } else if let Some(error_message) = error_message {
        error_message
    } else {
        format!("killed {:?}, port still occupied", killed_pids)
    };

    log::info!(
        "[prestart] kill_orphans: killed={:?} port_released={}",
        killed_pids,
        port_released
    );

    KillOrphansResult {
        success: port_released,
        killed_pids,
        port_released,
        message,
    }
}

#[cfg(test)]
mod tests {
    #[cfg(unix)]
    use super::is_owned_singbox_process;

    /// A port nobody listens on must be reported free without killing
    /// anything — the idempotent no-op path the start guard depends on.
    #[test]
    #[cfg(unix)]
    fn only_the_own_singbox_command_is_repairable() {
        let config = "/Users/test/Library/Application Support/dev.nekopilot.desktop/config.json";
        assert!(is_owned_singbox_process(
            "/Applications/NekoPilot.app/Contents/MacOS/sing-box",
            "/Applications/NekoPilot.app/Contents/MacOS/sing-box run -c /Users/test/Library/Application Support/dev.nekopilot.desktop/config.json",
            config,
        ));
        assert!(!is_owned_singbox_process(
            "/Applications/OneBox.app/Contents/MacOS/sing-box",
            "/Applications/OneBox.app/Contents/MacOS/sing-box run -c /Users/test/Library/Application Support/cloud.oneoh.onebox/config.json",
            config,
        ));
        assert!(!is_owned_singbox_process(
            "/usr/bin/python",
            "/usr/bin/python -m http.server 6789 --note sing-box --config /Users/test/Library/Application Support/dev.nekopilot.desktop/config.json",
            config
        ));
        assert!(!is_owned_singbox_process(
            "/Applications/NekoPilot.app/Contents/MacOS/sing-box",
            "/Applications/NekoPilot.app/Contents/MacOS/sing-box run -c /Users/test/Library/Application Support/dev.nekopilot.desktop/config.json.bak",
            config,
        ));
        assert!(!is_owned_singbox_process(
            "/tmp/my-sing-box-wrapper",
            "/tmp/my-sing-box-wrapper run -c /Users/test/Library/Application Support/dev.nekopilot.desktop/config.json",
            config
        ));
    }
}
