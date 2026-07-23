<p align="center">
  <img src="bunny.png" alt="Bunnylol" width="128" height="128">
</p>

<h3 align="center">Lolabunny</h3>

Lightweight fully local command router that let you navigate apps, tools, and internal resources directly from your browser address bar. Type `gh` foo to jump to GitHub issues, `ticket 2500` to open that ticket, or `wiki How to ...` to search your internal wiki. It just issues HTTP redirects, no browser extension, no cloud, no account. 


## Uhh, why not just use bookmarks?

I tried options like native browser bookmarks and tools like Yubnub, but nothing really fit my workflow and after years of using a [similar system](https://www.quora.com/What-is-Facebooks-bunnylol) internally at Facebook, I couldn’t imagine working without it. So I built Lolabunny, inspired by [bunnylol.rs](https://github.com/facebook/bunnylol.rs) by Aaron Lichtman and Joe Previte, with a focus on simplicity and zero-friction setup.

## Installation

Lolabunny ships as a macOS menu-bar app with the local HTTP server embedded in-process. The same server is also available as a standalone `lolabunny-server` executable.

See [releases](https://github.com/sidosera/lolabunny.app/releases) for installation options.

## Development

Run the macOS app from SwiftPM:

```sh
swift run lolabunny-macos-app
```

Run the standalone server when you do not want the macOS app:

```sh
swift run lolabunny-server -- serve
```

App logs are written to `~/Library/Logs/Lolabunny.log`.

## Extensions

You can extend Lolabunny with Lua. For example, the standard extension package [sidosera/lolacore](https://github.com/sidosera/homebrew-lolacore) is just a handful of Lua files.

The default package is `sidosera/lolacore` which includes basic commands. 

You can create your own command e.g. `~/.lolabunny/my-custom-command.lua` and point lolabunny at it. 


## For macOS users

I don't have Apple Developer account so I can't distribute a notarized app. By default apps installed from outside of AppStore go to quarantine. To fix it:


```sh
xattr -cr /Applications/Lolabunny.app
```

Toggle `Launch at Login` and allow the app to be added to startup folder and set your browser search engine to: `http://localhost:18085/?cmd=%s` (e.g. guide for [Google Chrome](https://support.google.com/chrome/answer/95426)).

<p align="center">
  <img src="launch-at-login.png" alt="Bunnylol" width="1096" height="358">
</p>

## License

It is free. 

MIT
