# panoseti_daqnodes

Provisioning for a PANOSETI DAQ node: installs [`uv`](https://docs.astral.sh/uv/),
enables systemd user linger, installs the node's CLI tools, and sets up two
systemd `--user` services so those tools start automatically on boot.

## Quick start

```bash
./install.sh all
```

This runs every step in order: install `uv`, enable linger, install the CLI
tools listed in `pseti-tools.toml`, create the configured log directory, and
create/update the two systemd services below. At the end it asks whether to
start the services immediately.

Re-running `install.sh all` (or any individual step) is always safe: it
overwrites generated files (runner scripts, service units) with the latest
config rather than skipping because something already exists.

## Commands

```
install.sh <command>
```

| Command          | Description |
|-------------------|-------------|
| `all`             | Run every step below, in order |
| `uv`              | Install `uv` (skipped if already installed) |
| `enable_linger`   | Enable linger for the current user (`loginctl enable-linger`) |
| `tools`           | Install every tool listed in `pseti-tools.toml` |
| `log_dir`         | Create the `[logs].dir` directory from `pseti-tools.toml` |
| `linger_service`  | Create/update both systemd services, then ask whether to start them |
| `clean`           | Restore the system to its pre-install state |
| `-h`, `--help`    | Show help |

Running with no command, an unrecognized command, or `-h`/`--help` prints the
same help text.

## Configuring tools: `pseti-tools.toml`

Each tool to install and run is declared under a `[tools.<name>]` section:

```toml
[tools.panoseti-grpc]
source = "public"
cmd = "pseti-grpc server --profile daq_node"
mode = "daemon"

[tools.gnss-lbe]
source = "https://github.com/liuweiseu/lbe1420_panoseti.git"
branch = "feature/profile"
cmd = "gnss-lbe --profile palomar"

[logs]
dir = "/var/log/panoseti"
```

Per-tool fields:

- **`source`** — either the literal `"public"`, which installs the tool by
  name from PyPI (`uv tool install <name>`), or a GitHub clone URL. A GitHub
  URL is cloned into `.tool-sources/<name>` (or updated, if already cloned)
  and installed from source with `uv tool install .`.
- **`branch`** — required when `source` is a GitHub URL; the branch to
  clone/pull.
- **`cmd`** — the command line used to start this tool. Added to the
  generated runner script (see below).
- **`mode`** — `"oneshot"` (default, if omitted): the command runs once and
  exits, e.g. a one-off configuration step. `"daemon"`: the command runs
  forever, e.g. a long-running server.

If a tool is already installed, `install.sh tools` reinstalls it so the
latest version is always picked up.

The `[logs]` section's `dir` key is the directory `install.sh log_dir`
creates for tools to write logs into. If creating it with a plain `mkdir`
fails (e.g. it's under `/var/log` and needs root), `install.sh` falls back to
`sudo mkdir` + `sudo chown`, which will prompt for a password.

## systemd services

`install.sh linger_service` (and `all`) generates two runner scripts from
`pseti-tools.toml` and installs two systemd `--user` services on top of them:

- **`pseti_daq_startup.service`** (`Type=oneshot`, `RemainAfterExit=yes`) —
  runs every tool whose `mode` is not `"daemon"` once, and waits for all of
  them to finish.
- **`pseti_daq_daemons.service`** (`Type=simple`, `Restart=on-failure`) —
  runs every tool with `mode = "daemon"`. If any one of them exits, the
  whole group is stopped and systemd restarts them together.

The generated runner scripts (`scripts/run_daq_tools.sh` and
`scripts/run_daq_daemons.sh`) are also deployed to `~/.local/bin`, and the
services `ExecStart` from there — so the services keep working even if this
repo checkout is later moved or deleted. Re-running `install.sh` always
regenerates and redeploys both scripts and both service files from the
current `pseti-tools.toml`.

Both services are enabled (`systemctl --user enable`) so they start
automatically after the next boot, as long as linger is enabled for the
user. `install.sh linger_service` asks whether to also start them right now;
if you say no, start them manually with:

```bash
systemctl --user start pseti_daq_startup.service
systemctl --user start pseti_daq_daemons.service
```

## Cleaning up

```bash
./install.sh clean
```

Uninstalls every `uv`-installed CLI tool, removes cached GitHub checkouts
under `.tool-sources/`, stops/disables/removes both systemd services (and
their deployed runner scripts in `~/.local/bin`), and disables linger —
restoring the system to its pre-install state.

## Requirements

- A Linux host running systemd, with `systemctl --user` and `loginctl`
  available.
- Network access to install `uv` and clone/install tools.
- `sudo` access if `[logs].dir` is not writable by the current user.
