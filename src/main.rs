/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use clap::{Parser, Subcommand};

#[cfg(feature = "cli")]
use clap::CommandFactory;

use bunnylol::BunnylolConfig;

#[cfg(feature = "cli")]
use bunnylol::{History, plugins, utils};
#[cfg(feature = "cli")]
use clap_complete::generate;
#[cfg(feature = "cli")]
use tabled::{
    Table, Tabled,
    settings::{Color, Modify, Style, Width, object::Columns},
};

#[derive(Parser)]
#[command(name = "bunnylol")]
#[command(
    about = "Smart bookmark server and CLI - URL shortcuts for your browser's search bar and terminal"
)]
#[command(version)]
#[command(override_usage = "bunnylol [OPTIONS] [BINDING] [ARGS]")]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,

    /// Print URL without opening browser (for command execution mode)
    #[arg(short = 'n', long, global = true)]
    dry_run: bool,

    /// List all available commands
    #[arg(short, long, global = true)]
    list: bool,
}

#[derive(Subcommand)]
enum Commands {
    /// Run the bunnylol web server
    #[cfg(feature = "server")]
    Serve {
        /// Port to bind the server to (overrides config file)
        #[arg(short, long)]
        port: Option<u16>,

        /// Address to bind to (overrides config file)
        #[arg(short, long)]
        address: Option<String>,
    },

    /// List all available command bindings
    #[cfg(feature = "cli")]
    Bindings,

    /// Generate shell completion scripts
    #[cfg(feature = "cli")]
    Completion {
        /// Shell to generate completions for
        #[arg(value_enum)]
        shell: clap_complete::Shell,
    },

    /// Execute a bunnylol command
    #[cfg(feature = "cli")]
    #[command(external_subcommand)]
    Command(Vec<String>),
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let cli = Cli::parse();

    let config = match BunnylolConfig::load() {
        Ok(cfg) => cfg,
        Err(e) => {
            eprintln!("Warning: {}", e);
            eprintln!("Continuing with default configuration...");
            BunnylolConfig::default()
        }
    };

    #[cfg(feature = "cli")]
    if cli.list {
        print_commands();
        return Ok(());
    }

    match cli.command {
        #[cfg(feature = "server")]
        Some(Commands::Serve { port, address }) => {
            let mut server_config = config.clone();
            if let Some(p) = port {
                server_config.server.port = p;
            }
            if let Some(a) = address {
                server_config.server.address = a;
            }
            bunnylol::server::launch(server_config).await?;
            Ok(())
        }

        #[cfg(feature = "cli")]
        Some(Commands::Bindings) => {
            print_commands();
            Ok(())
        }

        #[cfg(feature = "cli")]
        Some(Commands::Completion { shell }) => {
            let mut cmd = Cli::command();
            generate(shell, &mut cmd, "bunnylol", &mut std::io::stdout());
            Ok(())
        }

        #[cfg(feature = "cli")]
        Some(Commands::Command(args)) => {
            execute_command(args, &config, cli.dry_run)?;
            Ok(())
        }

        #[cfg(feature = "cli")]
        None => {
            let args: Vec<String> = std::env::args()
                .skip(1)
                .filter(|arg| !arg.starts_with('-') && arg != "bunnylol")
                .collect();

            if args.is_empty() {
                Cli::command().print_help().unwrap();
                println!();
                std::process::exit(0);
            }

            execute_command(args, &config, cli.dry_run)?;
            Ok(())
        }

        #[cfg(not(feature = "cli"))]
        None => {
            eprintln!("Error: No command provided. This binary was built without CLI support.");
            eprintln!("Use 'bunnylol serve' to run the server, or rebuild with --features cli");
            std::process::exit(1);
        }
    }
}

#[cfg(feature = "cli")]
fn execute_command(
    args: Vec<String>,
    config: &BunnylolConfig,
    dry_run: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    if args.first().map(|s| s.as_str()) == Some("list") {
        print_commands();
        return Ok(());
    }

    let full_args = args.join(" ");
    let resolved_args = config.resolve_command(&full_args);
    let command = utils::get_command_from_query_string(&resolved_args);
    let url = plugins::process_command_with_fallback(command, &resolved_args, Some(config));

    println!("{}", url);

    if config.history.enabled
        && let Some(history) = History::new(config)
    {
        let username = whoami::username();
        if let Err(e) = history.add(&full_args, &username) {
            eprintln!("Warning: Failed to save command to history: {}", e);
        }
    }

    if !dry_run {
        open_url(&url, config)?;
    }

    Ok(())
}

#[cfg(feature = "cli")]
fn open_url(url: &str, config: &BunnylolConfig) -> Result<(), Box<dyn std::error::Error>> {
    if let Some(browser) = &config.browser {
        open::with(url, browser).map_err(|e| {
            format!(
                "Failed to open browser '{}': {}. URL printed above.",
                browser, e
            )
        })?;
    } else {
        open::that(url)
            .map_err(|e| format!("Failed to open browser: {}. URL printed above.", e))?;
    }
    Ok(())
}

#[cfg(feature = "cli")]
#[derive(Tabled)]
struct CommandRow {
    #[tabled(rename = "Command")]
    command: String,
    #[tabled(rename = "Aliases")]
    aliases: String,
    #[tabled(rename = "Description")]
    description: String,
    #[tabled(rename = "Example")]
    example: String,
}

#[cfg(feature = "cli")]
fn print_commands() {
    let mut commands = plugins::get_all_commands();
    commands.sort_by(|a, b| {
        a.bindings[0]
            .to_lowercase()
            .cmp(&b.bindings[0].to_lowercase())
    });

    let rows: Vec<CommandRow> = commands
        .into_iter()
        .map(|cmd| {
            let primary = cmd.bindings.first().unwrap_or(&String::new()).clone();
            let aliases = if cmd.bindings.len() > 1 {
                cmd.bindings[1..].join(", ")
            } else {
                String::from("—")
            };

            CommandRow {
                command: primary,
                aliases,
                description: cmd.description,
                example: cmd.example,
            }
        })
        .collect();

    let term_width = terminal_size::terminal_size()
        .map(|(w, _)| w.0 as usize)
        .unwrap_or(120);

    let available_width = term_width.saturating_sub(2);
    let command_width = 15;
    let example_width = (available_width as f32 * 0.25).max(20.0) as usize;
    let description_width = (available_width as f32 * 0.45).max(30.0) as usize;
    let aliases_width = available_width
        .saturating_sub(command_width)
        .saturating_sub(description_width)
        .saturating_sub(example_width);

    let mut table = Table::new(rows);
    table
        .with(Style::rounded())
        .with(Modify::new(Columns::new(0..=0)).with(Color::FG_BRIGHT_CYAN))
        .with(
            Modify::new(Columns::new(1..=1))
                .with(Color::FG_YELLOW)
                .with(Width::wrap(aliases_width)),
        )
        .with(
            Modify::new(Columns::new(2..=2))
                .with(Color::FG_WHITE)
                .with(Width::wrap(description_width)),
        )
        .with(
            Modify::new(Columns::new(3..=3))
                .with(Color::FG_BRIGHT_GREEN)
                .with(Width::wrap(example_width)),
        );

    println!("\n{}\n", table);
    println!("💡 Tip: Use 'bunnylol <command>' to open URLs in your browser");
    println!("   Example: bunnylol ig reels");
    println!("   Use --dry-run to preview the URL without opening it\n");
}
