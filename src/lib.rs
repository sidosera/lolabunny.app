/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

pub mod config;
pub mod history;
pub mod paths;
pub mod plugins;
pub mod utils;

#[cfg(feature = "server")]
pub mod server;

pub use config::BunnylolConfig;
pub use history::{History, HistoryEntry};
pub use plugins::CommandInfo;

/// C FFI entry point for embedding the server in a native host (e.g. macOS app).
/// Blocks the calling thread. Intended to be called from a background thread.
#[cfg(feature = "server")]
#[unsafe(no_mangle)]
pub extern "C" fn bunnylol_serve(port: u16) -> i32 {
    let mut config = match BunnylolConfig::load() {
        Ok(cfg) => cfg,
        Err(_) => BunnylolConfig::default(),
    };
    config.server.port = port;
    config.server.log_level = "off".to_string();

    let rt = match tokio::runtime::Runtime::new() {
        Ok(rt) => rt,
        Err(_) => return 1,
    };

    match rt.block_on(server::launch(config)) {
        Ok(()) => 0,
        Err(_) => 1,
    }
}
