use std::path::{Path, PathBuf};
use std::sync::OnceLock;

pub const APP_PREFIX: &str = "bunnylol";

static BREW_PREFIX: OnceLock<Option<PathBuf>> = OnceLock::new();

const BREW_CANDIDATES: &[&str] = &["/opt/homebrew", "/usr/local", "/home/linuxbrew/.linuxbrew"];

fn detect_brew_prefix() -> Option<PathBuf> {
    BREW_PREFIX
        .get_or_init(|| {
            BREW_CANDIDATES
                .iter()
                .map(Path::new)
                .find(|p| p.join("bin/brew").is_file())
                .map(PathBuf::from)
        })
        .clone()
}

pub fn brew_plugin_dir() -> Option<PathBuf> {
    detect_brew_prefix().map(|p| p.join("share").join(APP_PREFIX).join("commands"))
}

pub fn user_plugin_dir() -> Option<PathBuf> {
    let xdg = xdg::BaseDirectories::with_prefix(APP_PREFIX);
    let path = xdg.get_data_home()?.join("commands");
    if !path.exists() {
        std::fs::create_dir_all(&path).ok()?;
    }
    Some(path)
}

pub fn plugin_dirs() -> Vec<PathBuf> {
    [user_plugin_dir(), brew_plugin_dir()]
        .into_iter()
        .flatten()
        .filter(|d| d.exists())
        .collect()
}
