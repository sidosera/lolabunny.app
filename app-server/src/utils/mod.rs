/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

pub fn get_command_from_query_string(query_string: &str) -> &str {
    match query_string.find(' ') {
        Some(i) => &query_string[..i],
        None => query_string,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_only() {
        assert_eq!(get_command_from_query_string("tw"), "tw");
    }

    #[test]
    fn command_with_args() {
        assert_eq!(get_command_from_query_string("tw @fbOpenSource"), "tw");
    }
}
