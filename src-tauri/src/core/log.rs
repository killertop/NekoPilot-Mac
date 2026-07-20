use flate2::write::GzEncoder;
use flate2::Compression;
use std::io::{BufWriter, Read, Write};
use std::path::Path;
use tauri::{AppHandle, Manager};

const MAX_COMPRESSIBLE_LOG_SIZE: u64 = 10 * 1024 * 1024;
pub(super) const MAX_ACTIVE_SINGBOX_LOG_BYTES: u64 = 50 * 1024 * 1024;
const MAX_SINGBOX_LOG_LINE_BYTES: usize = 256 * 1024;

/// Local civil date used for daily sing-box log filenames.
pub(super) fn today_date_string() -> String {
    chrono::Local::now().format("%Y-%m-%d").to_string()
}

fn compress_singbox_log(log_path: &Path) -> std::io::Result<()> {
    if let Ok(meta) = std::fs::metadata(log_path) {
        if meta.len() > MAX_COMPRESSIBLE_LOG_SIZE {
            let compressed_path = log_path.with_extension("log.gz");
            let mut input_file = std::fs::File::open(log_path)?;
            let mut compressed_options = std::fs::OpenOptions::new();
            compressed_options.write(true).create(true).truncate(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                compressed_options.mode(0o600);
            }
            let compressed_file = compressed_options.open(&compressed_path)?;
            let mut encoder = GzEncoder::new(compressed_file, Compression::default());

            let mut buffer = vec![0; 8192];
            loop {
                let n = input_file.read(&mut buffer)?;
                if n == 0 {
                    break;
                }
                encoder.write_all(&buffer[..n])?;
            }

            encoder.finish()?;
            std::fs::remove_file(log_path)?;
            log::info!("Compressed sing-box log to: {}", compressed_path.display());
        }
    }
    Ok(())
}

#[cfg(test)]
pub(super) fn cleanup_old_singbox_logs(log_dir: &Path, keep_days: u64) {
    let entries = match std::fs::read_dir(log_dir) {
        Ok(e) => e,
        Err(_) => return,
    };

    let cutoff = std::time::SystemTime::now() - std::time::Duration::from_secs(keep_days * 86400);

    for entry in entries.flatten() {
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        let path = entry.path();

        if name_str.starts_with("sing-box-")
            && (name_str.ends_with(".log") || name_str.ends_with(".log.gz"))
        {
            if let Ok(meta) = entry.metadata() {
                let modified = meta.modified().unwrap_or(std::time::SystemTime::now());
                if modified < cutoff {
                    let _ = std::fs::remove_file(&path);
                    log::info!("Removed old sing-box log: {}", name_str);
                }
            }
        }
    }
}

/// Run the daily housekeeping on `log_dir` and return today's sing-box
/// log path. Pure-ish filesystem helper split out of
/// `create_singbox_log_writer` so rotation, compression, and 7-day pruning
/// stay independent from the process launcher.
///
/// In a single directory scan: prunes entries older than 7 days
/// (both `.log` and `.log.gz`), compresses previous days' still-plain
/// logs. Does NOT create or open the returned path — callers do that
/// step.
pub(crate) fn prepare_singbox_log_dir(log_dir: &Path) -> std::io::Result<std::path::PathBuf> {
    std::fs::create_dir_all(log_dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(log_dir, std::fs::Permissions::from_mode(0o700))?;
    }

    let date = today_date_string();
    let log_path = log_dir.join(format!("sing-box-{}.log", date));
    let cutoff = std::time::SystemTime::now() - std::time::Duration::from_secs(7 * 86400);

    if let Ok(entries) = std::fs::read_dir(log_dir) {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name_str = name.to_string_lossy();
            if !name_str.starts_with("sing-box-") {
                continue;
            }

            let is_log = name_str.ends_with(".log");
            let is_gz = name_str.ends_with(".log.gz");
            if !is_log && !is_gz {
                continue;
            }

            #[cfg(unix)]
            if entry.file_type().is_ok_and(|file_type| file_type.is_file()) {
                use std::os::unix::fs::PermissionsExt;
                let _ =
                    std::fs::set_permissions(entry.path(), std::fs::Permissions::from_mode(0o600));
            }

            // Prune old logs (both .log and .log.gz)
            if let Ok(meta) = entry.metadata() {
                let modified = meta.modified().unwrap_or(std::time::SystemTime::now());
                if modified < cutoff {
                    let _ = std::fs::remove_file(entry.path());
                    log::info!("Removed old sing-box log: {}", name_str);
                    continue;
                }
            }

            // Compress previous days' uncompressed logs
            if is_log && !name_str.contains(&date) {
                let _ = compress_singbox_log(&entry.path());
            }
        }
    }

    Ok(log_path)
}

/// Resolve the per-platform app-log dir and hand it to
/// `prepare_singbox_log_dir` for the user-mode sing-box process.
pub(crate) fn resolve_singbox_log_path(app: &AppHandle) -> Option<std::path::PathBuf> {
    let log_dir = app.path().app_log_dir().ok()?;
    prepare_singbox_log_dir(&log_dir)
        .map_err(|e| log::warn!("[sing-box] prepare log dir failed: {}", e))
        .ok()
}

/// Create a daily-rotated log file writer for sing-box output. Used by
/// `spawn_process_monitor` — every supported NekoPilot mode is owned by
/// the user process and writes through this path.
pub(super) struct SingboxLogWriter {
    writer: BufWriter<std::fs::File>,
    bytes_written: u64,
    write_failed: bool,
}

pub(super) fn open_singbox_log_writer(log_path: &Path) -> std::io::Result<SingboxLogWriter> {
    let mut options = std::fs::OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let file = options.open(log_path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    }
    let bytes_written = file.metadata()?.len();
    Ok(SingboxLogWriter {
        writer: BufWriter::new(file),
        bytes_written,
        write_failed: false,
    })
}

pub(super) fn create_singbox_log_writer(app: &AppHandle) -> Option<SingboxLogWriter> {
    let log_path = resolve_singbox_log_path(app)?;
    open_singbox_log_writer(&log_path)
        .map_err(|e| log::error!("Failed to open {}: {}", log_path.display(), e))
        .ok()
}

/// Append a line to the buffered sing-box log file. The buffer avoids a disk
/// syscall for every stdout/stderr chunk; it is flushed on errors and exit.
pub(super) fn write_singbox_log(writer: &mut Option<SingboxLogWriter>, line: &str) {
    let Some(writer) = writer.as_mut() else {
        return;
    };
    if writer.write_failed || writer.bytes_written >= MAX_ACTIVE_SINGBOX_LOG_BYTES {
        return;
    }
    let remaining = (MAX_ACTIVE_SINGBOX_LOG_BYTES - writer.bytes_written) as usize;
    if remaining <= 1 {
        writer.bytes_written = MAX_ACTIVE_SINGBOX_LOG_BYTES;
        return;
    }
    let mut line_len = line
        .len()
        .min(MAX_SINGBOX_LOG_LINE_BYTES)
        .min(remaining - 1);
    while line_len > 0 && !line.is_char_boundary(line_len) {
        line_len -= 1;
    }
    let result = writer
        .writer
        .write_all(&line.as_bytes()[..line_len])
        .and_then(|_| writer.writer.write_all(b"\n"));
    if let Err(error) = result {
        writer.write_failed = true;
        log::warn!("[sing-box] disabling file log after write failure: {error}");
    } else {
        writer.bytes_written += line_len as u64 + 1;
    }
}

pub(super) fn flush_singbox_log(writer: &mut Option<SingboxLogWriter>) {
    if let Some(writer) = writer {
        if let Err(error) = writer.writer.flush() {
            writer.write_failed = true;
            log::warn!("[sing-box] failed to flush file log: {error}");
        }
    }
}

/// Delete rotated NekoPilot app logs older than 7 days, plus legacy OneBox
/// archives left by older builds.
///
/// Companion to the `tauri-plugin-log` configuration in `app::plugins`
/// (`RotationStrategy::KeepAll`). The plugin rotates by size only, so
/// without this sweep rotated files accumulate forever. Files are left
/// uncompressed intentionally — `OneBox.log` is grep-driven triage
/// material and the triage script must be able to read it directly.
///
/// Only rotated archives (`NekoPilot_<timestamp>.log` and legacy
/// `OneBox_<timestamp>.log`) are subject to deletion; live `.log` files are
/// always preserved regardless of mtime — the plugin holds the current file
/// open and deleting it would corrupt the writer. Oneshot: call once at
/// `app_setup`; not re-entered per log write.
pub fn cleanup_old_app_logs(app: &AppHandle) {
    let Ok(log_dir) = app.path().app_log_dir() else {
        return;
    };
    if !log_dir.exists() {
        return;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if let Err(error) =
            std::fs::set_permissions(&log_dir, std::fs::Permissions::from_mode(0o700))
        {
            log::warn!("Failed to secure app log directory: {error}");
        }
    }
    let cutoff = std::time::SystemTime::now() - std::time::Duration::from_secs(7 * 86400);
    sweep_app_logs(&log_dir, cutoff);
}

/// Pure filesystem sweep — split from `cleanup_old_app_logs` so unit
/// tests can exercise it without a real `AppHandle`.
fn sweep_app_logs(log_dir: &Path, cutoff: std::time::SystemTime) {
    let entries = match std::fs::read_dir(log_dir) {
        Ok(e) => e,
        Err(_) => return,
    };

    for entry in entries.flatten() {
        let name = entry.file_name();
        let name_str = name.to_string_lossy();

        #[cfg(unix)]
        if entry.file_type().is_ok_and(|file_type| file_type.is_file()) {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(entry.path(), std::fs::Permissions::from_mode(0o600));
        }

        // Rotated archives only. Active NekoPilot.log / OneBox.log do not
        // contain the underscore and are never touched.
        let rotated = name_str.starts_with("NekoPilot_") || name_str.starts_with("OneBox_");
        if !(rotated && name_str.ends_with(".log")) {
            continue;
        }

        if let Ok(meta) = entry.metadata() {
            let modified = meta.modified().unwrap_or(std::time::SystemTime::now());
            if modified < cutoff {
                if let Err(e) = std::fs::remove_file(entry.path()) {
                    log::warn!("Failed to remove old OneBox log {}: {}", name_str, e);
                } else {
                    log::info!("Removed old OneBox log: {}", name_str);
                }
            }
        }
    }
}

#[cfg(test)]
mod singbox_log_dir_tests {
    use super::{prepare_singbox_log_dir, today_date_string};
    use std::fs::File;
    use std::time::{Duration, SystemTime};

    fn touch(path: &std::path::Path, age_days: u64) {
        File::create(path).expect("create test log");
        let mtime = SystemTime::now() - Duration::from_secs(age_days * 86400);
        filetime::set_file_mtime(path, filetime::FileTime::from_system_time(mtime))
            .expect("set mtime");
    }

    #[test]
    fn returns_todays_log_path_and_runs_housekeeping() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let dir = tmp.path();

        let today = today_date_string();
        let today_log = dir.join(format!("sing-box-{}.log", today));
        let yesterday_log = dir.join("sing-box-1970-01-01.log"); // old uncompressed
        let stale_gz = dir.join("sing-box-1970-01-01.log.gz"); // old compressed
        let recent_gz = dir.join("sing-box-2026-04-20.log.gz"); // 1 day old — keep
        let unrelated = dir.join("other.log");

        touch(&today_log, 0);
        touch(&yesterday_log, 30);
        touch(&stale_gz, 30);
        touch(&recent_gz, 1);
        touch(&unrelated, 30);

        let returned = prepare_singbox_log_dir(dir).expect("resolve");

        assert_eq!(returned, today_log, "must resolve today's path");
        assert!(today_log.exists(), "today's log must be preserved");
        assert!(!stale_gz.exists(), "stale .gz beyond 7d must be pruned");
        assert!(recent_gz.exists(), "recent .gz within 7d must survive");
        assert!(unrelated.exists(), "unrelated files are not touched");
        // The old uncompressed yesterday log is either pruned (age > 7d) OR
        // compressed in place; both outcomes are acceptable and neither leaves
        // the original .log file behind.
        assert!(
            !yesterday_log.exists(),
            "old uncompressed log must not remain"
        );
    }

    #[test]
    fn creates_missing_log_dir() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let nested = tmp.path().join("a").join("b");
        assert!(!nested.exists());
        let returned = prepare_singbox_log_dir(&nested).expect("resolve");
        assert!(nested.is_dir(), "parent dir must be created");
        assert_eq!(returned.parent(), Some(nested.as_path()));
    }
}

#[cfg(test)]
mod app_log_sweep_tests {
    use super::sweep_app_logs;
    use std::fs::File;
    use std::time::{Duration, SystemTime};

    fn touch(path: &std::path::Path, age_days: u64) {
        File::create(path).expect("create test log");
        let mtime = SystemTime::now() - Duration::from_secs(age_days * 86400);
        filetime::set_file_mtime(path, filetime::FileTime::from_system_time(mtime))
            .expect("set mtime");
    }

    #[test]
    fn removes_rotated_logs_older_than_cutoff() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let dir = tmp.path();

        let active = dir.join("NekoPilot.log");
        let legacy_active = dir.join("OneBox.log");
        let recent = dir.join("NekoPilot_2026-04-20_00-00-00.log");
        let stale = dir.join("NekoPilot_2026-04-01_00-00-00.log");
        let legacy_stale = dir.join("OneBox_2026-04-01_00-00-00.log");
        let singbox = dir.join("sing-box-2026-04-01.log");
        let unrelated = dir.join("other.log");

        touch(&active, 30);
        touch(&legacy_active, 30);
        touch(&recent, 1);
        touch(&stale, 30);
        touch(&legacy_stale, 30);
        touch(&singbox, 30);
        touch(&unrelated, 30);

        let cutoff = SystemTime::now() - Duration::from_secs(7 * 86400);
        sweep_app_logs(dir, cutoff);

        assert!(
            active.exists(),
            "active NekoPilot.log must never be deleted"
        );
        assert!(
            legacy_active.exists(),
            "legacy active log must be preserved"
        );
        assert!(recent.exists(), "recent rotated log must survive");
        assert!(!stale.exists(), "stale rotated log must be removed");
        assert!(!legacy_stale.exists(), "legacy stale log must be removed");
        assert!(
            singbox.exists(),
            "sing-box logs are owned by a different sweep"
        );
        assert!(unrelated.exists(), "unrelated files must not be touched");
    }
}
