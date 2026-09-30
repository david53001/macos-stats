# MacStats

A small menu-bar system monitor for macOS: CPU, memory, network and battery at a glance,
and which apps are using them.

## Install and update

Paste this into Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/david53001/macos-stats/main/install.sh | bash
```

It installs MacStats to `~/Applications` and opens it. Run the same command again to update;
your settings are kept.

Requires macOS 14 or newer on an Apple Silicon Mac. You can also download
`MacStats.app.zip` from the [latest release](https://github.com/david53001/macos-stats/releases/latest).
The app isn't notarized, so if you install it by hand, run
`xattr -dr com.apple.quarantine ~/Applications/MacStats.app` once before opening it.

## What it shows

Click the graph icon in the menu bar to open the panel.

- **CPU**: usage, a 60-second graph and chip temperature
- **Memory**: used / total and memory pressure
- **Network**: download and upload speed
- **Battery**: charge, and either the time left or the time until full. The time left uses
  your average power use rather than the last minute, so it doesn't swing between 3 and 13 hours.
- **Trash**: size, with an Empty button

Click CPU, Memory or Battery to see which apps use the most. Right-click an app to quit it.
The Battery screen also shows power draw, battery health, cycle count and temperature.

MacStats starts at login (turn it off in System Settings > General > Login Items). It sends
a notification when the CPU stays very busy or memory runs low. It does almost no work
while the panel is closed.

On first use, macOS asks for permission to show notifications and, for the Trash
button, to control Finder.

## Build from source

Needs Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/david53001/macos-stats && cd macos-stats
./Scripts/bundle.sh release && open ~/Applications/MacStats.app
./Scripts/test.sh    # tests
```

## License

[PolyForm Strict 1.0.0](LICENSE). You may use MacStats and read the code. You may not
redistribute it, modify it or sell it.
