//! Atomic persistence for generated sing-box configurations.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Component, Path};

fn validate_file_name(file_name: &str) -> Result<(), String> {
    let mut components = Path::new(file_name).components();
    match (components.next(), components.next()) {
        (Some(Component::Normal(_)), None) if file_name.ends_with(".json") => Ok(()),
        _ => Err("configuration file name must be a single .json file name".into()),
    }
}

pub(crate) fn write_atomically(dir: &Path, file_name: &str, data: &[u8]) -> Result<(), String> {
    validate_file_name(file_name)?;
    fs::create_dir_all(dir).map_err(|e| format!("create config directory: {e}"))?;

    let target = dir.join(file_name);
    let temp = dir.join(format!(".{file_name}.{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| -> Result<(), String> {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options
            .open(&temp)
            .map_err(|e| format!("create temporary config: {e}"))?;
        file.write_all(data)
            .map_err(|e| format!("write temporary config: {e}"))?;
        file.sync_all()
            .map_err(|e| format!("sync temporary config: {e}"))?;
        drop(file);
        fs::rename(&temp, &target).map_err(|e| format!("replace config: {e}"))?;
        if let Ok(dir_file) = OpenOptions::new().read(true).open(dir) {
            let _ = dir_file.sync_all();
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::write_atomically;

    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn replaces_config_without_leaving_a_temp_file() {
        let dir = tempfile::tempdir().unwrap();
        write_atomically(dir.path(), "config.json", br#"{"version":1}"#).unwrap();
        write_atomically(dir.path(), "config.json", br#"{"version":2}"#).unwrap();
        assert_eq!(
            std::fs::read(dir.path().join("config.json")).unwrap(),
            br#"{"version":2}"#
        );
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 1);
    }

    #[test]
    fn rejects_path_traversal() {
        let dir = tempfile::tempdir().unwrap();
        assert!(write_atomically(dir.path(), "../config.json", b"{}").is_err());
    }

    #[cfg(unix)]
    #[test]
    fn generated_config_is_private_to_the_current_user() {
        let dir = tempfile::tempdir().unwrap();
        write_atomically(dir.path(), "config.json", br#"{"secret":"token"}"#).unwrap();
        let mode = std::fs::metadata(dir.path().join("config.json"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o600);
    }
}
