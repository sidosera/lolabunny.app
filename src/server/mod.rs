/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

pub mod web;

use rocket::State;
use rocket::request::{self, FromRequest, Request};
use rocket::response::Redirect;

use crate::{BunnylolConfig, History, plugins, utils};

struct ClientIP(String);

#[rocket::async_trait]
impl<'r> FromRequest<'r> for ClientIP {
    type Error = ();

    async fn from_request(req: &'r Request<'_>) -> request::Outcome<Self, Self::Error> {
        let ip = req
            .client_ip()
            .map(|addr| addr.to_string())
            .unwrap_or_else(|| "unknown".to_string());
        request::Outcome::Success(ClientIP(ip))
    }
}

#[rocket::get("/?<cmd>")]
fn search(
    cmd: Option<&str>,
    config: &State<BunnylolConfig>,
    client_ip: ClientIP,
) -> Result<Redirect, rocket::response::content::RawHtml<String>> {
    match cmd {
        Some(cmd_str) => {
            let command = utils::get_command_from_query_string(cmd_str);
            let redirect_url =
                plugins::process_command_with_fallback(command, cmd_str, Some(config.inner()));

            if config.history.enabled
                && let Some(history) = History::new(config.inner())
                && let Err(e) = history.add(cmd_str, &client_ip.0)
            {
                eprintln!("Warning: Failed to save history: {}", e);
            }

            Ok(Redirect::to(redirect_url))
        }
        None => Err(rocket::response::content::RawHtml(
            web::render_landing_page_html(config.inner()),
        )),
    }
}

#[rocket::get("/health")]
fn health() -> &'static str {
    "ok"
}

#[rocket::catch(404)]
fn not_found(req: &rocket::Request) -> rocket::response::content::RawHtml<String> {
    if let Some(config) = req.rocket().state::<BunnylolConfig>() {
        rocket::response::content::RawHtml(web::render_landing_page_html(config))
    } else {
        rocket::response::content::RawHtml(
            "<html><body><h1>404 Not Found</h1></body></html>".to_string(),
        )
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
        .mount("/", rocket::routes![search, health])
        .register("/", rocket::catchers![not_found])
        .launch()
        .await?;
    Ok(())
}
