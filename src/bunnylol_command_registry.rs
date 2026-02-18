use crate::commands::bunnylol_command::BunnylolCommandInfo;
use crate::plugins;

/// Bunnylol Command Registry
///
/// All commands are implemented as Lua plugins.
/// Plugins are loaded from:
/// - ~/.config/bunnylol/commands/ (user plugins)
/// - /opt/homebrew/etc/bunnylol/commands/ (Homebrew on Apple Silicon)
/// - /usr/local/etc/bunnylol/commands/ (Homebrew on Intel)
pub struct BunnylolCommandRegistry;

impl BunnylolCommandRegistry {
    /// Process a command string and return the appropriate URL
    pub fn process_command(command: &str, full_args: &str) -> String {
        Self::process_command_with_config(command, full_args, None)
    }

    /// Process a command string with optional config for custom search engine
    pub fn process_command_with_config(
        command: &str,
        full_args: &str,
        config: Option<&crate::config::BunnylolConfig>,
    ) -> String {
        // Check Lua plugins
        if let Some(url) = plugins::process_plugin_command(command, full_args) {
            return url;
        }

        // Fall back to search engine (default: Google)
        if let Some(cfg) = config {
            cfg.get_search_url(full_args)
        } else {
            format!(
                "https://www.google.com/search?q={}",
                percent_encoding::utf8_percent_encode(
                    full_args,
                    percent_encoding::NON_ALPHANUMERIC
                )
            )
        }
    }

    /// Get all commands (from Lua plugins)
    pub fn get_all_commands_with_plugins() -> Vec<BunnylolCommandInfo> {
        plugins::get_plugin_commands()
    }
}
