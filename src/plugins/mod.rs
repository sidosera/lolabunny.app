/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use mlua::{Function, Lua, Result as LuaResult, Table};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::sync::OnceLock;

static REGISTRY: OnceLock<PluginRegistry> = OnceLock::new();

#[derive(Clone, serde::Serialize)]
pub struct CommandInfo {
    pub bindings: Vec<String>,
    pub description: String,
    pub example: String,
}

#[derive(Debug)]
struct LuaPlugin {
    bindings: Vec<String>,
    description: String,
    example: String,
    source: String,
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
        }
    }
}

struct PluginRegistry {
    plugins: HashMap<String, LuaPlugin>,
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
        let dirs = [
            Self::user_plugins_dir(),
            Some(PathBuf::from("/opt/homebrew/etc/bunnylol/commands")),
            Some(PathBuf::from("/usr/local/etc/bunnylol/commands")),
        ];

        for dir in dirs.into_iter().flatten() {
            if !dir.exists() {
                continue;
            }
            let Ok(entries) = fs::read_dir(&dir) else {
                continue;
            };
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().is_some_and(|ext| ext == "lua") {
                    if let Some(plugin) = Self::load_plugin(&path) {
                        for binding in &plugin.bindings {
                            self.plugins.insert(
                                binding.clone(),
                                LuaPlugin {
                                    bindings: plugin.bindings.clone(),
                                    description: plugin.description.clone(),
                                    example: plugin.example.clone(),
                                    source: plugin.source.clone(),
                                },
                            );
                        }
                    }
                }
            }
        }
    }

    fn user_plugins_dir() -> Option<PathBuf> {
        let xdg = xdg::BaseDirectories::with_prefix("bunnylol");
        let path = xdg.get_data_home()?.join("commands");
        if !path.exists() {
            fs::create_dir_all(&path).ok()?;
        }
        Some(path)
    }

    fn load_plugin(path: &PathBuf) -> Option<LuaPlugin> {
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

fn registry() -> &'static PluginRegistry {
    REGISTRY.get_or_init(PluginRegistry::new)
}

pub fn process_command_with_fallback(
    command: &str,
    full_args: &str,
    config: Option<&crate::config::BunnylolConfig>,
) -> String {
    if let Some(plugin) = registry().plugins.get(command) {
        if let Some(url) = plugin.execute(full_args) {
            return url;
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
    registry().unique_plugins().iter().map(|p| p.info()).collect()
}
