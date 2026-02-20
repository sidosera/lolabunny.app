use mlua::{Function, Lua, Result as LuaResult, Table};
use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::sync::{OnceLock, RwLock};

static REGISTRY: OnceLock<RwLock<PluginRegistry>> = OnceLock::new();

#[derive(Clone, serde::Serialize)]
pub struct CommandInfo {
    pub bindings: Vec<String>,
    pub description: String,
    pub example: String,
    pub origin: String,
}

#[derive(Debug)]
struct LuaPlugin {
    bindings: Vec<String>,
    description: String,
    example: String,
    source: String,
    origin: String,
}

impl LuaPlugin {
    fn execute(&self, args: &str) -> Option<String> {
        let lua = Lua::new();
        register_helpers(&lua).ok()?;
        lua.load(&self.source).exec().ok()?;
        let process: Function = lua.globals().get("process").ok()?;
        process.call(args).ok()
    }

    fn info(&self) -> CommandInfo {
        CommandInfo {
            bindings: self.bindings.clone(),
            description: self.description.clone(),
            example: self.example.clone(),
            origin: self.origin.clone(),
        }
    }
}

struct PluginRegistry {
    plugins: HashMap<String, LuaPlugin>,
}

fn plugin_dirs() -> Vec<PathBuf> {
    crate::paths::plugin_dirs()
}

impl PluginRegistry {
    fn new() -> Self {
        let mut registry = Self {
            plugins: HashMap::new(),
        };
        registry.scan_dirs();
        registry
    }

    fn scan_dirs(&mut self) {
        self.plugins.clear();
        for dir in plugin_dirs() {
            self.scan_dir(&dir);
        }
    }

    fn scan_dir(&mut self, dir: &PathBuf) {
        let Ok(entries) = fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                self.scan_dir(&path);
            } else if path.extension().is_some_and(|ext| ext == "lua") {
                self.register_plugin(&path);
            }
        }
    }

    fn register_plugin(&mut self, path: &PathBuf) {
        let origin = path
            .parent()
            .and_then(|p| p.file_name())
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default();
        let origin = if origin == "commands" {
            "user".to_string()
        } else {
            origin
        };

        if let Some(plugin) = Self::load_plugin(path, &origin) {
            for binding in &plugin.bindings {
                self.plugins.insert(
                    binding.clone(),
                    LuaPlugin {
                        bindings: plugin.bindings.clone(),
                        description: plugin.description.clone(),
                        example: plugin.example.clone(),
                        source: plugin.source.clone(),
                        origin: plugin.origin.clone(),
                    },
                );
            }
        }
    }

    fn load_plugin(path: &PathBuf, origin: &str) -> Option<LuaPlugin> {
        let source = fs::read_to_string(path).ok()?;
        let lua = Lua::new();
        register_helpers(&lua).ok()?;
        lua.load(&source).exec().ok()?;

        let info_fn: Function = lua.globals().get("info").ok()?;
        let info_table: Table = info_fn.call(()).ok()?;

        let bindings_table: Table = info_table.get("bindings").ok()?;
        let bindings: Vec<String> = bindings_table
            .sequence_values::<String>()
            .filter_map(|v| v.ok())
            .collect();

        Some(LuaPlugin {
            bindings,
            description: info_table.get("description").ok()?,
            example: info_table.get("example").ok()?,
            source,
            origin: origin.to_string(),
        })
    }

    fn unique_plugins(&self) -> Vec<&LuaPlugin> {
        let mut seen = std::collections::HashSet::new();
        self.plugins
            .values()
            .filter(|p| {
                let key = p.bindings.first().map(|s| s.as_str()).unwrap_or("");
                seen.insert(key)
            })
            .collect()
    }
}

fn register_helpers(lua: &Lua) -> LuaResult<()> {
    let g = lua.globals();

    g.set(
        "url_encode",
        lua.create_function(|_, s: String| {
            Ok(
                percent_encoding::utf8_percent_encode(&s, percent_encoding::NON_ALPHANUMERIC)
                    .to_string(),
            )
        })?,
    )?;

    g.set(
        "url_encode_path",
        lua.create_function(|_, s: String| {
            use percent_encoding::{AsciiSet, CONTROLS};
            const PATH_SET: &AsciiSet = &CONTROLS
                .add(b' ')
                .add(b'"')
                .add(b'#')
                .add(b'<')
                .add(b'>')
                .add(b'?')
                .add(b'`')
                .add(b'{')
                .add(b'}');
            Ok(percent_encoding::utf8_percent_encode(&s, PATH_SET).to_string())
        })?,
    )?;

    g.set(
        "get_args",
        lua.create_function(|_, (full_args, binding): (String, String)| {
            let args = full_args.strip_prefix(&binding).unwrap_or(&full_args);
            Ok(args.trim_start().to_string())
        })?,
    )?;

    g.set(
        "trim",
        lua.create_function(|_, s: String| Ok(s.trim().to_string()))?,
    )?;
    g.set(
        "split",
        lua.create_function(|lua, (s, delim): (String, String)| {
            lua.create_sequence_from(s.split(&delim).map(|p| p.to_string()).collect::<Vec<_>>())
        })?,
    )?;
    g.set(
        "starts_with",
        lua.create_function(|_, (s, p): (String, String)| Ok(s.starts_with(&p)))?,
    )?;
    g.set(
        "ends_with",
        lua.create_function(|_, (s, p): (String, String)| Ok(s.ends_with(&p)))?,
    )?;
    g.set(
        "contains",
        lua.create_function(|_, (s, p): (String, String)| Ok(s.contains(&p)))?,
    )?;
    g.set(
        "upper",
        lua.create_function(|_, s: String| Ok(s.to_uppercase()))?,
    )?;
    g.set(
        "lower",
        lua.create_function(|_, s: String| Ok(s.to_lowercase()))?,
    )?;

    Ok(())
}

fn registry() -> &'static RwLock<PluginRegistry> {
    REGISTRY.get_or_init(|| {
        let reg = RwLock::new(PluginRegistry::new());
        spawn_watcher();
        reg
    })
}

fn spawn_watcher() {
    std::thread::spawn(|| {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut watcher: RecommendedWatcher = match Watcher::new(tx, notify::Config::default()) {
            Ok(w) => w,
            Err(e) => {
                eprintln!("plugin watcher failed to start: {e}");
                return;
            }
        };

        for dir in plugin_dirs() {
            let _ = watcher.watch(&dir, RecursiveMode::Recursive);
        }

        eprintln!("plugin watcher active");
        while let Ok(event) = rx.recv() {
            let Ok(event) = event else { continue };
            let dominated = matches!(
                event.kind,
                EventKind::Create(_) | EventKind::Modify(_) | EventKind::Remove(_)
            );
            let lua_involved = event.paths.iter().any(|p| {
                p.extension().is_some_and(|e| e == "lua")
            });
            if dominated && lua_involved {
                eprintln!("plugins changed, reloading...");
                if let Some(lock) = REGISTRY.get() {
                    if let Ok(mut reg) = lock.write() {
                        reg.scan_dirs();
                        eprintln!("plugins reloaded ({} bindings)", reg.plugins.len());
                    }
                }
            }
        }
    });
}

pub fn process_command_with_fallback(
    command: &str,
    full_args: &str,
    config: Option<&crate::config::BunnylolConfig>,
) -> String {
    if let Ok(reg) = registry().read() {
        if let Some(plugin) = reg.plugins.get(command) {
            if let Some(url) = plugin.execute(full_args) {
                return url;
            }
        }
    }

    match config {
        Some(cfg) => cfg.get_search_url(full_args),
        None => format!(
            "https://www.google.com/search?q={}",
            percent_encoding::utf8_percent_encode(full_args, percent_encoding::NON_ALPHANUMERIC)
        ),
    }
}

pub fn get_all_commands() -> Vec<CommandInfo> {
    registry()
        .read()
        .map(|reg| reg.unique_plugins().iter().map(|p| p.info()).collect())
        .unwrap_or_default()
}
