use crate::core::{HistoryEntry, Settings};
use serde::{de::DeserializeOwned, Serialize};
use std::{fs, path::Path};
pub fn load<T: DeserializeOwned + Default>(path: &Path) -> Result<T, String> {
    if !path.exists() {
        return Ok(T::default());
    }
    let bytes = fs::read(path).map_err(|_| "无法读取本地配置")?;
    serde_json::from_slice(&bytes).map_err(|_| {
        format!(
            "{} 损坏，原文件已保留",
            path.file_name().unwrap_or_default().to_string_lossy()
        )
    })
}
pub fn write<T: Serialize>(path: &Path, value: &T) -> Result<(), String> {
    use std::io::Write;
    let parent = path.parent().ok_or("无效的数据路径")?;
    fs::create_dir_all(parent).map_err(|_| "无法创建数据目录")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(parent, fs::Permissions::from_mode(0o700))
            .map_err(|_| "无法保护数据目录")?;
    }
    let tmp = path.with_extension("json.tmp");
    let mut options = fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&tmp).map_err(|_| "无法保存配置")?;
    file.write_all(&serde_json::to_vec_pretty(value).map_err(|_| "配置编码错误")?)
        .map_err(|_| "配置写入失败")?;
    file.sync_all().map_err(|_| "配置同步失败")?;
    drop(file);
    fs::rename(tmp, path).map_err(|_| "配置替换失败，旧文件已保留".into())
}
pub fn initialize(dir: &Path) -> Result<(Settings, Vec<HistoryEntry>), String> {
    let settings: Settings = load(&dir.join("settings.json"))?;
    settings.validate()?;
    let history = if settings.remember_history {
        load(&dir.join("history.json"))?
    } else {
        Vec::new()
    };
    Ok((settings, history))
}
