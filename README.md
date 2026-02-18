<p align="center">
  <img src="bunnylol.png" alt="Bunnylol" width="128" height="128">
</p>

# Bunnylol

Command Line for Your Browser Location Bar


## Han, why do I need another bookmark manager?

This idea is not new. It comes from an internal tool created at Facebook in 2007 by Charlie Cheever called bunny. It was built to solve a very practical problem: navigating a large, private, constantly growing internal ecosystem where public search engines do not work. 

Charlie Cheever described it as something that is hard to explain but painful to live without once adopted. Over time, it became muscle memory for many engineers and a shared layer on top of internal tools.


## Installation

### Homebrew

```sh
brew tap sidosera/lolabunny
brew install --cask bunnylol
brew install lola-core  # core plugins
```

### Mac

Download from [Releases](https://github.com/sidosera/lolabunny.app/releases).

### Build from source

```sh
git clone https://github.com/sidosera/lolabunny.app.git
cd lolabunny.app
cargo xtask bundle
cp -r macos-app/build/Bunnylol.app /Applications/
```

## Setup

1. Open Bunnylol
2. Enable "Launch at Login"
3. Set your browser's search engine to `http://localhost:8000/?cmd=%s`

## Plugins

Commands are Lua scripts in `~/.local/share/bunnylol/commands/`:

```lua
-- ~/.local/share/bunnylol/commands/gh.lua
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

Install core plugins: `brew install lola-core`


## Configuration

Config file: `~/.config/bunnylol/config.toml`

```toml
# Default search engine when command not found
default_search = "google"  # or "ddg", "bing"

# Command aliases
[aliases]
work = "gh mycompany"

# Server settings
[server]
port = 8000
```

## License

MIT
