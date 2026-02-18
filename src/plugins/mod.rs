use mlua::{Function, Lua, Result as LuaResult, Table};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::sync::OnceLock;

use crate::commands::bunnylol_command::BunnylolCommandInfo;

static PLUGIN_REGISTRY: OnceLock<PluginRegistry> = OnceLock::new();

#[derive(Debug)]
pub struct LuaPlugin {
    pub bindings: Vec<String>,
    pub description: String,
    pub example: String,
    source: String,
}

impl LuaPlugin {
    pub fn process(&self, args: &str) -> Option<String> {
        let lua = Lua::new();
        register_helpers(&lua).ok()?;

        lua.load(&self.source).exec().ok()?;

        let process: Function = lua.globals().get("process").ok()?;
        let result: String = process.call(args).ok()?;
        Some(result)
    }

    pub fn get_info(&self) -> BunnylolCommandInfo {
        BunnylolCommandInfo::new(
            &self.bindings.iter().map(|s| s.as_str()).collect::<Vec<_>>(),
            &self.description,
            &self.example,
        )
    }
}

pub struct PluginRegistry {
    plugins: HashMap<String, LuaPlugin>,
}

impl PluginRegistry {
    fn new() -> Self {
        let mut registry = Self {
            plugins: HashMap::new(),
        };
        registry.load_plugins();
        registry
    }

    fn get_plugins_dir() -> Option<PathBuf> {
        let xdg_dirs = xdg::BaseDirectories::with_prefix("bunnylol");
        if let Ok(path) = xdg_dirs.create_config_directory("commands") {
            return Some(path);
        }

        let home = std::env::var("HOME").ok()?;
        let path = PathBuf::from(home).join(".bunnylol").join("commands");
        if !path.exists() {
            fs::create_dir_all(&path).ok()?;
        }
        Some(path)
    }

    fn load_plugins(&mut self) {
        let mut plugin_dirs: Vec<PathBuf> = Vec::new();

        if let Some(dir) = Self::get_plugins_dir() {
            plugin_dirs.push(dir);
        }

        let homebrew_dir = PathBuf::from("/usr/local/etc/bunnylol/commands");
        if homebrew_dir.exists() {
            plugin_dirs.push(homebrew_dir);
        }

        let homebrew_arm_dir = PathBuf::from("/opt/homebrew/etc/bunnylol/commands");
        if homebrew_arm_dir.exists() {
            plugin_dirs.push(homebrew_arm_dir);
        }

        for plugins_dir in plugin_dirs {
            let Ok(entries) = fs::read_dir(&plugins_dir) else {
                continue;
            };

            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().map_or(false, |ext| ext == "lua") {
                    if let Some(plugin) = self.load_plugin(&path) {
                        for binding in &plugin.bindings {
                            self.plugins.insert(binding.clone(), LuaPlugin {
                                bindings: plugin.bindings.clone(),
                                description: plugin.description.clone(),
                                example: plugin.example.clone(),
                                source: plugin.source.clone(),
                            });
                        }
                    }
                }
            }
        }
    }

    fn load_plugin(&self, path: &PathBuf) -> Option<LuaPlugin> {
        let source = fs::read_to_string(path).ok()?;
        let lua = Lua::new();

        register_helpers(&lua).ok()?;
        lua.load(&source).exec().ok()?;

        let info_fn: Function = lua.globals().get("info").ok()?;
        let info_table: Table = info_fn.call(()).ok()?;

        let bindings: Vec<String> = {
            let bindings_table: Table = info_table.get("bindings").ok()?;
            bindings_table
                .sequence_values::<String>()
                .filter_map(|v| v.ok())
                .collect()
        };

        let description: String = info_table.get("description").ok()?;
        let example: String = info_table.get("example").ok()?;

        Some(LuaPlugin {
            bindings,
            description,
            example,
            source,
        })
    }

    pub fn get_plugin(&self, command: &str) -> Option<&LuaPlugin> {
        self.plugins.get(command)
    }

    pub fn get_all_plugins(&self) -> Vec<&LuaPlugin> {
        let mut seen = std::collections::HashSet::new();
        self.plugins
            .values()
            .filter(|p| {
                let key = p.bindings.first().map(|s| s.as_str()).unwrap_or("");
                seen.insert(key)
            })
            .collect()
    }

    pub fn process_command(&self, command: &str, full_args: &str) -> Option<String> {
        let plugin = self.plugins.get(command)?;
        plugin.process(full_args)
    }
}

fn register_helpers(lua: &Lua) -> LuaResult<()> {
    let globals = lua.globals();

    let url_encode = lua.create_function(|_, s: String| {
        Ok(percent_encoding::utf8_percent_encode(
            &s,
            percent_encoding::NON_ALPHANUMERIC,
        )
        .to_string())
    })?;
    globals.set("url_encode", url_encode)?;

    let url_encode_path = lua.create_function(|_, s: String| {
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
    })?;
    globals.set("url_encode_path", url_encode_path)?;

    let trim = lua.create_function(|_, s: String| Ok(s.trim().to_string()))?;
    globals.set("trim", trim)?;

    let split = lua.create_function(|lua, (s, delim): (String, String)| {
        let parts: Vec<String> = s.split(&delim).map(|p| p.to_string()).collect();
        lua.create_sequence_from(parts)
    })?;
    globals.set("split", split)?;

    let starts_with =
        lua.create_function(|_, (s, prefix): (String, String)| Ok(s.starts_with(&prefix)))?;
    globals.set("starts_with", starts_with)?;

    let ends_with =
        lua.create_function(|_, (s, suffix): (String, String)| Ok(s.ends_with(&suffix)))?;
    globals.set("ends_with", ends_with)?;

    let contains =
        lua.create_function(|_, (s, substr): (String, String)| Ok(s.contains(&substr)))?;
    globals.set("contains", contains)?;

    let upper = lua.create_function(|_, s: String| Ok(s.to_uppercase()))?;
    globals.set("upper", upper)?;

    let lower = lua.create_function(|_, s: String| Ok(s.to_lowercase()))?;
    globals.set("lower", lower)?;

    let get_args = lua.create_function(|_, (full_args, binding): (String, String)| {
        let args = full_args.strip_prefix(&binding).unwrap_or(&full_args);
        Ok(args.trim_start().to_string())
    })?;
    globals.set("get_args", get_args)?;

    Ok(())
}

pub fn get_registry() -> &'static PluginRegistry {
    PLUGIN_REGISTRY.get_or_init(PluginRegistry::new)
}

pub fn process_plugin_command(command: &str, full_args: &str) -> Option<String> {
    get_registry().process_command(command, full_args)
}

pub fn get_plugin_commands() -> Vec<BunnylolCommandInfo> {
    get_registry()
        .get_all_plugins()
        .iter()
        .map(|p| p.get_info())
        .collect()
}

pub fn has_plugin(command: &str) -> bool {
    get_registry().get_plugin(command).is_some()
}
