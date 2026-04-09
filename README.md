# sshz

A lightweight SSH connection manager with a beautiful TUI, written in Zig.

**~260KB static binary. Zero dependencies. Runs on Raspberry Pi Zero 2W.**

![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)

## Features

- **TUI host list** with real-time connectivity status indicators
- **Background status checks** (3-thread pool with TCP connect)
- **Search & filter** hosts by name, hostname, user, or tags
- **Tag-based organization** with cycling tag filter
- **Sort modes** — by name, recent connection, or tag
- **Add / Edit / Delete** hosts directly from the TUI
- **Port forwarding presets** saved per host (UI for toggle selection; `-L`/`-R`/`-D` flag passing is WIP)
- **Connection history** with relative timestamps ("3m ago", "2d ago")
- **Auto-backup** of `~/.ssh/config` before every write (10 generations)
- **CLI mode** — `sshz myserver` for instant connect without TUI
- **Cross-compiles** to aarch64 for ARM devices

## Screenshot

![sshz main view](screenshots/main-view.png)

## Install

### Install Zig

sshz requires Zig 0.15.0+. Choose one of the following methods:

**Download from ziglang.org (all platforms):**

```bash
# Download the latest master build for your platform from:
# https://ziglang.org/download/
# Extract and add to PATH:
export PATH="$HOME/zig:$PATH"
```

**Package managers:**

```bash
# macOS
brew install zig

# Arch Linux
pacman -S zig

# Nix
nix-shell -p zig

# Windows (scoop)
scoop install zig

# Windows (winget)
winget install zig.zig

# Snap
snap install zig --classic --beta
```

### Build from source

```bash
git clone https://github.com/midasdf/sshz.git
cd sshz
zig build -Doptimize=ReleaseSmall
```

Binary is at `zig-out/bin/sshz`. Copy it to your PATH:

```bash
sudo cp zig-out/bin/sshz /usr/local/bin/
```

### Cross-compile for Raspberry Pi / ARM

```bash
zig build -Doptimize=ReleaseSmall -Dtarget=aarch64-linux-musl
```

## Usage

### TUI mode

```bash
sshz
```

### Direct connect

```bash
sshz myserver              # Connect to host
sshz myserver uptime       # Run remote command
```

### CLI options

```
sshz                       Launch TUI
sshz <host>                Connect to host (records history)
sshz <host> <command...>   Execute remote command
sshz --help                Show help
sshz --version             Show version
```

## Keybindings

| Key | Action |
|-----|--------|
| `j` / `↓` | Move down |
| `k` / `↑` | Move up |
| `Enter` | Connect to selected host |
| `a` | Add new host |
| `e` | Edit selected host |
| `d` | Delete selected host (with confirmation) |
| `/` | Search hosts |
| `t` | Cycle tag filter |
| `s` | Cycle sort mode (name / recent / tag) |
| `r` | Refresh status checks |
| `f` | Port forward settings |
| `?` | Show help |
| `q` | Quit |

In add/edit form:
| Key | Action |
|-----|--------|
| `Tab` / `↓` | Next field |
| `Shift+Tab` / `↑` | Previous field |
| `Enter` | Save |
| `Esc` | Cancel |

## Data Storage

sshz uses two data sources:

### `~/.ssh/config`

Standard SSH config file. sshz reads and writes it directly, preserving comments, blank lines, and formatting.

Supported directives: `Host`, `HostName`, `User`, `Port`, `IdentityFile`, `ProxyJump`, `ProxyCommand`, `LocalForward`, `RemoteForward`, `DynamicForward`.

`Match` blocks and `Include` directives are preserved but not parsed.

### `~/.config/sshz/meta.json`

sshz-specific metadata: tags, connection history, and port forwarding presets.

```json
{
  "version": 1,
  "hosts": {
    "myserver": {
      "tags": ["work", "prod"],
      "last_connected": 1710576600,
      "connect_count": 42,
      "port_forwards": [
        {"type": "local", "bind": "8080", "target": "localhost:80"}
      ]
    }
  }
}
```

### `~/.config/sshz/backups/`

Auto-backups of `~/.ssh/config` created before every write. Keeps the last 10 versions.

## Architecture

```
src/
├── main.zig           Entry point, CLI arg parsing, SSH exec
├── app.zig            ZigZag Model — Elm architecture state machine
├── ssh_config.zig     SSH config parser/writer with format preservation
├── meta.zig           JSON metadata store
├── checker.zig        Background TCP status checker (3-thread pool)
├── utils.zig          Time formatting, string helpers
└── views/
    ├── host_list.zig  Main host list with search/filter/sort
    ├── host_form.zig  Add/edit form with field navigation
    ├── forward.zig    Port forward toggle selection
    └── help.zig       Keybinding reference overlay
```

Built with [ZigZag](https://github.com/meszmate/zigzag) TUI framework.

## Performance

| Metric | Value |
|--------|-------|
| Binary size (x86_64) | ~288 KB |
| Binary size (aarch64) | ~261 KB |
| Dependencies | Zero (static binary) |

## License

[MIT](LICENSE)

## Disclaimer
This project uses AI-generated code (LLM). I do my best to review and test it, but I can't guarantee it's perfect. Please use it at your own risk.\n