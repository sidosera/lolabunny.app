use base64::{Engine, engine::general_purpose::STANDARD};
use minijinja::context;
use rocket::request::{self, FromRequest, Request};
use rocket::response::Redirect;
use rocket::response::content::RawHtml;
use rocket::{State, catch, catchers, get, routes};

use crate::{BunnylolConfig, History, plugins, utils};

const LOGO_PNG: &[u8] = include_bytes!("../../bunny.png");
const ENTRYPOINT_TEMPLATE: &str = include_str!("../../entrypoint.j2");
const VERSION: &str = include_str!("../../.version");
const HTML_404: &str = "<html><body><h1>404 Not Found</h1></body></html>";

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
    "ok"
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

    let figment = rocket::Config::figment()
        .merge(("address", config.server.address.clone()))
        .merge(("port", config.server.port))
        .merge(("log_level", config.server.log_level.clone()))
        .merge(("ident", format!("Bunnylol/{}", env!("CARGO_PKG_VERSION"))));

    rocket::custom(figment)
        .manage(config)
        .mount("/", routes![search, health])
        .register("/", catchers![not_found])
        .launch()
        .await?;

    Ok(())
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

    let env = minijinja::Environment::new();
    let tmpl = env
        .template_from_str(ENTRYPOINT_TEMPLATE)
        .expect("invalid template");
    let version = VERSION.trim();
    tmpl.render(context! { logo, commands => view, version })
        .expect("template render failed")
}
