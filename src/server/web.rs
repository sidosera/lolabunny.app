/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use std::sync::OnceLock;

use crate::{BunnylolConfig, plugins};

static LANDING_PAGE_HTML_CACHE: OnceLock<String> = OnceLock::new();
const LOGO_PNG: &[u8] = include_bytes!("../../bunny.png");

pub fn render_landing_page_html(config: &BunnylolConfig) -> String {
    LANDING_PAGE_HTML_CACHE
        .get_or_init(|| {
            let logo = base64_encode(LOGO_PNG);
            let display_url = html_escape(&config.server.get_display_url());

            let mut commands = plugins::get_all_commands();
            commands.sort_by(|a, b| {
                let a_key = a.bindings.first().map(|s| s.to_lowercase()).unwrap_or_default();
                let b_key = b.bindings.first().map(|s| s.to_lowercase()).unwrap_or_default();
                a_key.cmp(&b_key)
            });

            let mut rows = String::new();
            for cmd in &commands {
                let name = cmd
                    .bindings
                    .first()
                    .map(|s| s.as_str())
                    .unwrap_or("(default)");
                rows.push_str(&format!(
                    "<tr>\
                        <td class=\"cmd\">{}</td>\
                        <td>{}</td>\
                        <td class=\"example\">{}</td>\
                    </tr>\n",
                    html_escape(name),
                    html_escape(&cmd.description),
                    html_escape(&cmd.example),
                ));
            }

            format!(
                r#"<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>bunnylol</title>
<link rel="icon" href="data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 100 100%22><text y=%22.9em%22 font-size=%2290%22>🐰</text></svg>">
<style>
*{{margin:0;padding:0;box-sizing:border-box}}
body{{font-family:-apple-system,BlinkMacSystemFont,'Helvetica Neue',sans-serif;color:#333;max-width:900px;margin:0 auto;padding:48px 24px}}
header{{text-align:center;margin-bottom:48px}}
header img{{width:80px;height:80px;margin-bottom:12px}}
header h1{{font-size:1.4em;font-weight:600;margin-bottom:4px}}
header p{{color:#999;font-size:.8em;font-family:'SF Mono',Menlo,Consolas,monospace}}
table{{width:100%;border-collapse:collapse;font-size:.88em}}
th{{text-align:left;padding:6px 12px;border-bottom:2px solid #e0e0e0;font-weight:600;color:#666;font-size:.75em;text-transform:uppercase;letter-spacing:.05em}}
td{{padding:7px 12px;border-bottom:1px solid #f0f0f0;vertical-align:top}}
tr:hover{{background:#fafafa}}
.cmd{{font-family:'SF Mono',Menlo,Consolas,monospace;font-weight:600;white-space:nowrap}}
.example{{font-family:'SF Mono',Menlo,Consolas,monospace;color:#999;font-size:.9em}}
</style>
</head>
<body>
<header>
<img src="data:image/png;base64,{logo}" alt="bunnylol">
<h1>bunnylol</h1>
<p>{display_url}</p>
</header>
<table>
<thead><tr><th>Command</th><th>Description</th><th>Example</th></tr></thead>
<tbody>
{rows}</tbody>
</table>
</body>
</html>"#
            )
        })
        .clone()
}

fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

fn base64_encode(data: &[u8]) -> String {
    const ALPHABET: &[u8; 64] =
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    let mut out = String::with_capacity((data.len() + 2) / 3 * 4);
    for chunk in data.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = chunk.get(1).copied().unwrap_or(0) as u32;
        let b2 = chunk.get(2).copied().unwrap_or(0) as u32;
        let triple = (b0 << 16) | (b1 << 8) | b2;

        out.push(ALPHABET[((triple >> 18) & 0x3F) as usize] as char);
        out.push(ALPHABET[((triple >> 12) & 0x3F) as usize] as char);
        out.push(if chunk.len() > 1 {
            ALPHABET[((triple >> 6) & 0x3F) as usize] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            ALPHABET[(triple & 0x3F) as usize] as char
        } else {
            '='
        });
    }
    out
}
