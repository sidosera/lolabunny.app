use base64::{Engine, engine::general_purpose::STANDARD};
use minijinja::{Environment, context};
use rocket::data::{Data, ToByteUnit};
use rocket::request::{self, FromRequest, Request};
use rocket::response::Redirect;
use rocket::response::content::{RawHtml, RawText};
use rocket::{State, catch, catchers, get, post, routes};

use crate::{BunnylolConfig, History, Vault, plugins, utils};

const LOGO_PNG: &[u8] = include_bytes!("../../bunny.png");
const VERSION: &str = include_str!("../../.version");
const HTML_404: &str = "<html><body><h1>404 Not Found</h1></body></html>";

fn create_template_env() -> Environment<'static> {
    let mut env = Environment::new();
    env.add_template("base.j2", include_str!("../../templates/base.j2")).expect("invalid base template");
    env.add_template("bindings.j2", include_str!("../../templates/bindings.j2")).expect("invalid bindings template");
    env.add_template("blob.j2", include_str!("../../templates/blob.j2")).expect("invalid blob template");
    env
}

struct ClientIP(String);

#[rocket::async_trait]
impl<'r> FromRequest<'r> for ClientIP {
    type Error = ();

    async fn from_request(req: &'r Request<'_>) -> request::Outcome<Self, Self::Error> {
        let ip = req
            .client_ip()
            .map_or_else(|| "unknown".into(), |a| a.to_string());
        request::Outcome::Success(Self(ip))
    }
}

#[get("/?<cmd>")]
fn search(
    cmd: Option<&str>,
    config: &State<BunnylolConfig>,
    client_ip: ClientIP,
) -> Result<Redirect, RawHtml<String>> {
    let Some(query) = cmd else {
        return Err(RawHtml(entrypoint_html()));
    };

    let command = utils::get_command_from_query_string(query);
    let url = plugins::process_command_with_fallback(command, query, Some(config.inner()));

    if config.history.enabled
        && let Some(history) = History::new(config.inner())
        && let Err(e) = history.add(query, &client_ip.0)
    {
        eprintln!("Warning: Failed to save history: {e}");
    }

    Ok(Redirect::to(url))
}

#[get("/health")]
fn health() -> &'static str {
    VERSION.trim()
}

#[get("/blob/<id>?<redirect_url>")]
fn blob_view(id: &str, redirect_url: Option<&str>) -> Result<Redirect, RawHtml<String>> {
    let content = blob_content(id).map_err(|e| RawHtml(format!("error: {e}")))?;

    if let Some(url) = redirect_url {
        return Ok(Redirect::to(url.to_string()));
    }

    let display = match String::from_utf8(content.clone()) {
        Ok(text) => text
            .replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;"),
        Err(_) => hexdump(&content),
    };

    let logo = STANDARD.encode(LOGO_PNG);
    let version = VERSION.trim();
    let size = format_size(content.len());
    let env = create_template_env();
    let tmpl = env.get_template("blob.j2").expect("blob template missing");
    let html = tmpl.render(context! { logo, version, id, content => display, size })
        .unwrap_or_else(|e| format!("template error: {e}"));
    Err(RawHtml(html))
}

fn format_size(bytes: usize) -> String {
    if bytes < 1024 {
        format!("{bytes} B")
    } else if bytes < 1024 * 1024 {
        format!("{:.1} KB", bytes as f64 / 1024.0)
    } else {
        format!("{:.1} MB", bytes as f64 / (1024.0 * 1024.0))
    }
}

#[post("/blob", data = "<body>")]
async fn blob_create(body: Data<'_>, config: &State<BunnylolConfig>) -> Result<String, String> {
    let bytes = body
        .open(10.mebibytes())
        .into_bytes()
        .await
        .map_err(|e| format!("read error: {e}"))?;
    if !bytes.is_complete() {
        return Err("payload too large (max 10 MB)".into());
    }
    let content = bytes.into_inner();
    if content.is_empty() {
        return Err("empty body".into());
    }
    let v = Vault::from_config()?;
    let id = v.put("blob", &content)?;
    let url = format!("{}/blob/{id}", config.server.get_display_url());
    Ok(format!("{id}\t{}\t{url}", content.len()))
}

fn hexdump(data: &[u8]) -> String {
    let mut out = String::new();
    for (i, chunk) in data.chunks(16).enumerate() {
        let offset = i * 16;
        out.push_str(&format!("{offset:08x}  "));
        for (j, byte) in chunk.iter().enumerate() {
            if j == 8 {
                out.push(' ');
            }
            out.push_str(&format!("{byte:02x} "));
        }
        for _ in chunk.len()..16 {
            out.push_str("   ");
        }
        if chunk.len() <= 8 {
            out.push(' ');
        }
        out.push_str(" |");
        for &b in chunk {
            out.push(if b.is_ascii_graphic() || b == b' ' {
                b as char
            } else {
                '.'
            });
        }
        out.push_str("|\n");
    }
    out
}

#[get("/blob/<id>/raw")]
fn blob_raw(id: &str) -> Result<RawText<String>, RawText<String>> {
    let content = blob_content(id).map_err(|e| RawText(format!("error: {e}")))?;
    let text = String::from_utf8(content)
        .map_err(|_| RawText("error: blob contains non-UTF-8 data".into()))?;
    Ok(RawText(text))
}

fn blob_content(id: &str) -> Result<Vec<u8>, String> {
    Vault::get("blob", id)
}

#[catch(404)]
fn not_found(req: &Request) -> RawHtml<String> {
    match req.rocket().state::<BunnylolConfig>() {
        Some(_) => RawHtml(entrypoint_html()),
        None => RawHtml(HTML_404.into()),
    }
}

pub async fn launch(config: BunnylolConfig) -> Result<(), Box<rocket::Error>> {
    println!(
        "Bunnylol listening on {}:{}",
        config.server.address, config.server.port
    );

    write_pid_file();

    let figment = rocket::Config::figment()
        .merge(("address", config.server.address.clone()))
        .merge(("port", config.server.port))
        .merge(("log_level", config.server.log_level.clone()))
        .merge(("ident", format!("Bunnylol/{}", env!("CARGO_PKG_VERSION"))));

    let result = rocket::custom(figment)
        .manage(config)
        .mount("/", routes![search, health, blob_view, blob_raw, blob_create])
        .register("/", catchers![not_found])
        .launch()
        .await;

    remove_pid_file();
    result?;

    Ok(())
}

fn write_pid_file() {
    if let Some(path) = crate::paths::pid_file() {
        let pid = std::process::id();
        if let Err(e) = std::fs::write(&path, pid.to_string()) {
            eprintln!("Warning: failed to write PID file: {e}");
        }
    }
}

fn remove_pid_file() {
    if let Some(path) = crate::paths::pid_file() {
        let _ = std::fs::remove_file(path);
    }
}

fn entrypoint_html() -> String {
    let logo = STANDARD.encode(LOGO_PNG);

    let mut commands = plugins::get_all_commands();
    commands.sort_by(|a, b| {
        a.bindings
            .first()
            .map(|s| s.to_lowercase())
            .cmp(&b.bindings.first().map(|s| s.to_lowercase()))
    });

    let view: Vec<_> = commands
        .iter()
        .map(|cmd| {
            let binding = cmd.bindings.first().cloned().unwrap_or_default();
            let aliases = cmd
                .bindings
                .iter()
                .skip(1)
                .cloned()
                .collect::<Vec<_>>()
                .join(", ");
            let search = cmd
                .bindings
                .iter()
                .map(|s| s.to_lowercase())
                .collect::<Vec<_>>()
                .join(" ")
                + " "
                + &cmd.description.to_lowercase();
            context! { binding, description => cmd.description, aliases, search }
        })
        .collect();

    let env = create_template_env();
    let tmpl = env.get_template("bindings.j2").expect("bindings template missing");
    let version = VERSION.trim();
    tmpl.render(context! { logo, commands => view, version })
        .expect("template render failed")
}
