<p align="center">
  <img src="bunny.png" alt="Bunnylol" width="128" height="128">
</p>

<h3 align="center">Bunnylol</h3>
<p align="center">
Turn your browser location bar into a command line.
</p>


Bunnylol is a lightweight local command router that lets you navigate apps, tools, and internal resources directly from your browser address bar.

Inspired by [bunnylol.rs](https://github.com/facebook/bunnylol.rs), Aaron Lichtman and Joe Previte’s port of [Facebook’s original tool](https://www.quora.com/profile/Charlie-Cheever), with an emphasis on simplicity and zero-friction setup.


## Install

### Apple Silicon

Download from [Releases](https://github.com/sidosera/lolabunny.app/releases)

Or using Homebrew


```sh
brew tap sidosera/lolacore
brew install --cask bunnylol
brew install lola-core
```

Or build from source

```sh
git clone https://github.com/sidosera/lolabunny.app.git && cd lolabunny.app
cargo xtask bundle && cp -r target/Bunnylol.app /Applications/
```


## Setup

one. Launch Bunnylol
two. Enable **Launch at Login**
three. Set your browser search engine to:

```
http://localhost:8085/?cmd=%s
```


## Plugins

Commands or plugins are Lua scripts located in:

```
~/.local/share/bunnylol/commands/
```

Example:

```lua
function info()
    return {
        bindings = {"gh", "github"},
        description = "Open GitHub repositories",
        example = "gh facebook/react"
    }
end

function process(full_args)
    local args = get_args(full_args, "gh")
    if args == "" then
        return "https://github.com"
    end
    return "https://github.com/" .. url_encode_path(args)
end
```

Install core commands:

```sh
brew install lola-core
```


## Config

```
~/.config/bunnylol/config.toml
```

```toml
default_search = "google"

[server]
port = 8085
```


## License

MIT

