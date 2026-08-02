#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SERVICE_NAME="pseti_daq_startup"
DAEMON_SERVICE_NAME="pseti_daq_daemons"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SYSTEMD_USER_DIR/${SERVICE_NAME}.service"
DAEMON_SERVICE_FILE="$SYSTEMD_USER_DIR/${DAEMON_SERVICE_NAME}.service"
RUNNER_SCRIPT="$SCRIPT_DIR/scripts/run_daq_tools.sh"
DAEMON_RUNNER_SCRIPT="$SCRIPT_DIR/scripts/run_daq_daemons.sh"
UV_BIN_DIR="$HOME/.local/bin"
DEPLOYED_RUNNER_SCRIPT="$UV_BIN_DIR/run_daq_tools.sh"
DEPLOYED_DAEMON_RUNNER_SCRIPT="$UV_BIN_DIR/run_daq_daemons.sh"
TOOLS_TOML="$SCRIPT_DIR/pseti-tools.toml"
TOOL_SOURCES_DIR="$SCRIPT_DIR/.tool-sources"
SEP_WIDTH=68
SEP="$(printf '%*s' "$SEP_WIDTH" '' | tr ' ' '-')"

log() { echo "[install.sh] $*"; }
# Like log(), but without a trailing newline, so a later plain "echo" can
# finish the line (used for "Cloning ....Done"-style progress messages).
logn() { printf '[install.sh] %s' "$*"; }
# Prefix every line of stdin with "[install.sh] ", so piped command output
# (e.g. "uv tool list") lines up with our own log() lines.
log_lines() {
  local line
  while IFS= read -r line; do
    log "$line"
  done
}

# Center `text` within `width`, padding both sides with `padchar`.
center_line() {
  local text="$1" width="$2" padchar="$3"
  local total_pad=$(( width - ${#text} ))
  if [ "$total_pad" -lt 0 ]; then total_pad=0; fi
  local left=$(( total_pad / 2 ))
  local right=$(( total_pad - left ))
  printf '%s' "$(printf '%*s' "$left" '' | tr ' ' "$padchar")"
  printf '%s' "$text"
  printf '%s' "$(printf '%*s' "$right" '' | tr ' ' "$padchar")"
}

# Run one step wrapped in clear separators, so multi-step output (e.g. "all")
# doesn't run together and each step's completion is obvious.
run_step() {
  local desc="$1"
  shift
  log "$SEP"
  log "$(center_line " STEP: $desc " "$SEP_WIDTH" '*')"
  log "$SEP"
  "$@"
  log "$SEP"
  log "$(center_line " DONE: $desc " "$SEP_WIDTH" '*')"
  log "$SEP"
  echo ""
}

# 1. Install uv (skip if already installed)
install_uv() {
  if command -v uv >/dev/null 2>&1; then
    log "uv already installed: $(command -v uv)"
  else
    log "Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$UV_BIN_DIR:$PATH"
  fi
  log "Status: uv version $(uv --version)"
}

# 2. Enable linger for the current user, so systemd --user services can
#    auto-start at boot even without an active login session
enable_linger() {
  log "Enabling linger for user $USER..."
  loginctl enable-linger "$USER"

  local linger_status
  linger_status="$(loginctl show-user "$USER" --property=Linger --value)"
  log "Status: linger for $USER = $linger_status"
}

# Parse $TOOLS_TOML into the parallel arrays
# TOOL_NAMES/TOOL_SOURCES/TOOL_BRANCHES/TOOL_CMDS/TOOL_MODES, plus LOGS_DIR.
# The format has one [tools.<name>] section per tool, each with "source",
# "branch", "cmd", and "mode" keys (quoted or unquoted), and a sibling
# [logs] section with a "dir" key; comments start with #.
parse_tools_toml() {
  TOOL_NAMES=()
  TOOL_SOURCES=()
  TOOL_BRANCHES=()
  TOOL_CMDS=()
  TOOL_MODES=()
  LOGS_DIR=""

  local section="" current_name="" current_source="" current_branch="" current_cmd="" current_mode=""
  local line key val

  flush_tool() {
    if [ -n "$current_name" ]; then
      TOOL_NAMES+=("$current_name")
      TOOL_SOURCES+=("$current_source")
      TOOL_BRANCHES+=("$current_branch")
      TOOL_CMDS+=("$current_cmd")
      TOOL_MODES+=("$current_mode")
    fi
  }

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue

    if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
      flush_tool
      section="${BASH_REMATCH[1]}"
      if [[ "$section" == tools.* ]]; then
        current_name="${section#tools.}"
      else
        current_name=""
      fi
      current_source=""
      current_branch=""
      current_cmd=""
      current_mode=""
    elif [[ "$line" =~ ^([A-Za-z0-9_.-]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      val="${val%\"}"
      val="${val#\"}"
      if [[ "$section" == tools.* ]]; then
        case "$key" in
          source) current_source="$val" ;;
          branch) current_branch="$val" ;;
          cmd) current_cmd="$val" ;;
          mode) current_mode="$val" ;;
        esac
      elif [ "$section" = "logs" ]; then
        case "$key" in
          dir) LOGS_DIR="$val" ;;
        esac
      fi
    fi
  done < "$TOOLS_TOML"
  flush_tool
}

# Clone (or update an existing clone of) a tool's github source at the
# given branch into $TOOL_SOURCES_DIR/<name>, and print the resulting path.
fetch_github_source() {
  local name="$1" url="$2" branch="$3" dest
  dest="$TOOL_SOURCES_DIR/$name"

  mkdir -p "$TOOL_SOURCES_DIR"

  if [ -d "$dest/.git" ]; then
    logn "     Updating $url ($branch)...." >&2
    if git -C "$dest" fetch --quiet origin "$branch" \
      && git -C "$dest" checkout --quiet "$branch" \
      && git -C "$dest" reset --quiet --hard "origin/$branch"; then
      echo "Done" >&2
    else
      echo "Failed" >&2
      log "  !! Failed to update $url ($branch), skipping" >&2
      return 1
    fi
  else
    logn "     Cloning $url ($branch)...." >&2
    if git clone --quiet --branch "$branch" "$url" "$dest"; then
      echo "Done" >&2
    else
      echo "Failed" >&2
      log "  !! Failed to clone $url ($branch), skipping" >&2
      return 1
    fi
  fi

  echo "$dest"
}

# 3. Install every tool listed in $TOOLS_TOML. For a github "source" URL
#    (which requires a "branch"), clone/update it under $TOOL_SOURCES_DIR
#    and run "uv tool install ." from the checkout; for source = "public",
#    install the tool by name from PyPI. If the tool is already installed,
#    force a reinstall so the latest version is picked up.
install_tools() {
  log "Installing CLI tools from $TOOLS_TOML..."
  if [ ! -f "$TOOLS_TOML" ]; then
    log "Status: $TOOLS_TOML not found, nothing to install."
    return
  fi

  parse_tools_toml

  local i name source branch src_dir pkg_name
  for ((i = 0; i < ${#TOOL_NAMES[@]}; i++)); do
    name="${TOOL_NAMES[$i]}"
    source="${TOOL_SOURCES[$i]}"
    branch="${TOOL_BRANCHES[$i]}"

    if [ "$source" = "public" ]; then
      log "  -> Installing '$name' from PyPI"
      if uv tool list 2>/dev/null | grep -qE "^${name}[[:space:]]"; then
        log "     $name is already installed, reinstalling to get the latest version..."
        uv tool install -q --reinstall "$name" || log "  !! Failed to reinstall $name, skipping"
      else
        uv tool install -q "$name" || log "  !! Failed to install $name, skipping"
      fi
      continue
    fi

    case "$source" in
      http://*|https://*|git@*|*.git)
        if [ -z "$branch" ]; then
          log "  !! '$name' has a github source but no 'branch' field, skipping"
          continue
        fi
        log "  -> Installing '$name' from $source (branch $branch)"
        src_dir="$(fetch_github_source "$name" "$source" "$branch")" || continue
        ;;
      *)
        log "  !! Unknown source '$source' for '$name' (expected a github URL or \"public\"), skipping"
        continue
        ;;
    esac

    pkg_name="$(grep "^name" "$src_dir/pyproject.toml" 2>/dev/null | head -n1 | cut -d\" -f2)"
    [ -z "$pkg_name" ] && pkg_name="$name"

    if uv tool list 2>/dev/null | grep -qE "^${pkg_name}[[:space:]]"; then
      log "     $pkg_name is already installed, reinstalling to get the latest version..."
      (cd "$src_dir" && uv tool install -q --reinstall .) || log "  !! Failed to reinstall '$name', skipping"
    else
      (cd "$src_dir" && uv tool install -q .) || log "  !! Failed to install '$name', skipping"
    fi
  done

  log "Status: installed uv tools"
  uv tool list | log_lines
}

# 4. Create the log directory tools write to ([logs].dir in $TOOLS_TOML).
#    Tries a plain mkdir first; if that fails (e.g. dir under /var/log
#    requires root), falls back to sudo, which will prompt for a password.
#    The directory is then chowned to the current user so the pseti_daq
#    services (which run as this user, not root) can write into it.
create_log_dir() {
  parse_tools_toml

  if [ -z "$LOGS_DIR" ]; then
    log "Status: no [logs].dir configured in $TOOLS_TOML, skipping."
    return
  fi

  if [ -d "$LOGS_DIR" ]; then
    log "Status: $LOGS_DIR already exists."
    return
  fi

  log "Creating log directory: $LOGS_DIR"
  if mkdir -p "$LOGS_DIR" 2>/dev/null; then
    log "Status: created $LOGS_DIR"
    return
  fi

  log "Need elevated privileges to create $LOGS_DIR, requesting sudo..."
  sudo mkdir -p "$LOGS_DIR"
  sudo chown "$USER" "$LOGS_DIR"
  log "Status: created $LOGS_DIR (owned by $USER)"
}

# Generate a runner script at `out` from the tools in $TOOLS_TOML whose
# mode matches `want_mode` ("oneshot" tools have no mode set, or mode !=
# "daemon"). Every matching tool is started in the background and its pid
# collected; how those pids are used afterward depends on `want_mode`:
#   oneshot: wait for all of them, so the script (and the oneshot systemd
#            unit running it) finishes once every tool has exited
#   daemon:  exit as soon as any one of them exits (crash or otherwise) and
#            kill the rest, so systemd (Restart=on-failure) restarts the
#            whole group together
generate_runner_script() {
  local out="$1" want_mode="$2"
  mkdir -p "$(dirname "$out")"

  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    echo 'export PATH="$HOME/.local/bin:$PATH"'
    echo ''
    echo 'pids=()'
    echo 'started=0'
    echo ''
    local i cmd mode is_daemon
    for ((i = 0; i < ${#TOOL_NAMES[@]}; i++)); do
      mode="${TOOL_MODES[$i]}"
      [ "$mode" = "daemon" ] && is_daemon=1 || is_daemon=0
      if [ "$want_mode" = "daemon" ] && [ "$is_daemon" -ne 1 ]; then continue; fi
      if [ "$want_mode" = "oneshot" ] && [ "$is_daemon" -eq 1 ]; then continue; fi

      cmd="${TOOL_CMDS[$i]}"
      [ -z "$cmd" ] && continue
      printf 'echo "Starting: %s"\n' "$cmd"
      printf '%s &\n' "$cmd"
      echo 'started=$((started + 1))'
      echo 'pids+=("$!")'
      echo ''
    done
    echo 'if [ "$started" -eq 0 ]; then'
    echo "  echo \"No $want_mode tools configured in pseti-tools.toml, nothing to start.\""
    echo '  exit 0'
    echo 'fi'
    echo ''
    if [ "$want_mode" = "daemon" ]; then
      echo '# Exit as soon as any one tool exits, and stop the rest, so systemd'
      echo '# restarts the whole group together.'
      echo 'wait -n "${pids[@]}"'
      echo 'code=$?'
      echo 'kill "${pids[@]}" 2>/dev/null || true'
      echo 'exit "$code"'
    else
      echo 'wait "${pids[@]}"'
    fi
  } > "$out"
  chmod +x "$out"
}

# Deploy `src` to `dest` (in ~/.local/bin) so the service keeps working even
# if this repo checkout is later moved or deleted.
deploy_runner_script() {
  local src="$1" dest="$2"
  mkdir -p "$UV_BIN_DIR"
  cp "$src" "$dest"
  chmod +x "$dest"
  log "Deployed runner script to $dest"
}

# 5. Create (or update) both systemd --user services:
#      pseti_daq_startup  (oneshot)  - runs every non-daemon tool once
#      pseti_daq_daemons  (simple)   - runs every daemon tool, restarted on
#                                      crash
#    Always (re)writes both service files with the current config, even if
#    they already exist.
create_systemd_services() {
  mkdir -p "$SYSTEMD_USER_DIR"

  # 6. Generate the two runner scripts from $TOOLS_TOML: one for the
  #    default "oneshot" tools, one for tools with mode = "daemon".
  parse_tools_toml
  generate_runner_script "$RUNNER_SCRIPT" oneshot
  generate_runner_script "$DAEMON_RUNNER_SCRIPT" daemon

  deploy_runner_script "$RUNNER_SCRIPT" "$DEPLOYED_RUNNER_SCRIPT"
  deploy_runner_script "$DAEMON_RUNNER_SCRIPT" "$DEPLOYED_DAEMON_RUNNER_SCRIPT"

  log "Creating/updating systemd user service: $SERVICE_FILE"
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=PANOSETI DAQ startup - runs each oneshot tool once
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$DEPLOYED_RUNNER_SCRIPT
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
EOF

  log "Creating/updating systemd user service: $DAEMON_SERVICE_FILE"
  cat > "$DAEMON_SERVICE_FILE" <<EOF
[Unit]
Description=PANOSETI DAQ daemons - runs each daemon tool, restarted on crash
After=network.target

[Service]
Type=simple
ExecStart=$DEPLOYED_DAEMON_RUNNER_SCRIPT
Restart=on-failure
RestartSec=5
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable --quiet "${SERVICE_NAME}.service"
  systemctl --user enable --quiet "${DAEMON_SERVICE_NAME}.service"

  local enabled_status daemon_enabled_status
  enabled_status="$(systemctl --user is-enabled "${SERVICE_NAME}.service" 2>&1 || true)"
  daemon_enabled_status="$(systemctl --user is-enabled "${DAEMON_SERVICE_NAME}.service" 2>&1 || true)"
  log "Status: ${SERVICE_NAME}.service enabled = $enabled_status"
  log "Status: ${DAEMON_SERVICE_NAME}.service enabled = $daemon_enabled_status"
}

# Start (or restart) both systemd --user services right now
start_systemd_services() {
  log "Starting ${SERVICE_NAME}.service..."
  systemctl --user start "${SERVICE_NAME}.service"
  log "Starting ${DAEMON_SERVICE_NAME}.service..."
  systemctl --user start "${DAEMON_SERVICE_NAME}.service"

  local active_status daemon_active_status
  active_status="$(systemctl --user is-active "${SERVICE_NAME}.service" 2>&1 || true)"
  daemon_active_status="$(systemctl --user is-active "${DAEMON_SERVICE_NAME}.service" 2>&1 || true)"
  log "Status: ${SERVICE_NAME}.service active = $active_status"
  log "Status: ${DAEMON_SERVICE_NAME}.service active = $daemon_active_status"
}

# Ask whether to start both services now; start them if the user agrees,
# otherwise leave them enabled-but-stopped and print how to start them later.
confirm_and_start_services() {
  local answer
  read -r -p "Start ${SERVICE_NAME}.service and ${DAEMON_SERVICE_NAME}.service now? [y/N] " answer

  case "$answer" in
    y|Y|yes|Yes|YES)
      start_systemd_services
      ;;
    *)
      log "Not starting the services now."
      log "To start them later, run:"
      log "  systemctl --user start ${SERVICE_NAME}.service"
      log "  systemctl --user start ${DAEMON_SERVICE_NAME}.service"
      ;;
  esac
}

# Stop, disable, and remove both pseti_daq systemd --user services
remove_systemd_services() {
  local svc
  for svc in "$SERVICE_NAME" "$DAEMON_SERVICE_NAME"; do
    log "Stopping and disabling ${svc}.service..."
    systemctl --user stop "${svc}.service" 2>/dev/null || true
    systemctl --user disable --quiet "${svc}.service" 2>/dev/null || true
  done

  local f
  for f in "$SERVICE_FILE" "$DAEMON_SERVICE_FILE" "$RUNNER_SCRIPT" "$DAEMON_RUNNER_SCRIPT" \
           "$DEPLOYED_RUNNER_SCRIPT" "$DEPLOYED_DAEMON_RUNNER_SCRIPT"; do
    if [ -f "$f" ]; then
      rm -f "$f"
      log "Removed $f"
    fi
  done

  systemctl --user daemon-reload

  local enabled_status daemon_enabled_status
  enabled_status="$(systemctl --user is-enabled "${SERVICE_NAME}.service" 2>&1 || true)"
  daemon_enabled_status="$(systemctl --user is-enabled "${DAEMON_SERVICE_NAME}.service" 2>&1 || true)"
  log "Status: ${SERVICE_NAME}.service = $enabled_status"
  log "Status: ${DAEMON_SERVICE_NAME}.service = $daemon_enabled_status"
}

# Disable linger for the current user
disable_linger() {
  log "Disabling linger for user $USER..."
  loginctl disable-linger "$USER"

  local linger_status
  linger_status="$(loginctl show-user "$USER" --property=Linger --value)"
  log "Status: linger for $USER = $linger_status"
}

# Uninstall every CLI tool that was installed via "uv tool install", and
# remove the cached github checkouts under $TOOL_SOURCES_DIR
uninstall_tools() {
  log "Uninstalling uv-installed CLI tools..."
  if command -v uv >/dev/null 2>&1; then
    local packages
    mapfile -t packages < <(uv tool list 2>/dev/null | awk '!/^- /{print $1}')

    if [ "${#packages[@]}" -eq 0 ]; then
      log "Status: no uv tools installed."
    else
      for pkg in "${packages[@]}"; do
        log "Uninstalling $pkg..."
        uv tool uninstall -q "$pkg" || log "  !! Failed to uninstall $pkg"
      done
    fi
  else
    log "Status: uv is not installed, nothing to uninstall."
  fi

  if [ -d "$TOOL_SOURCES_DIR" ]; then
    rm -rf "$TOOL_SOURCES_DIR"
    log "Removed $TOOL_SOURCES_DIR"
  fi

  if command -v uv >/dev/null 2>&1; then
    log "Status: remaining uv tools"
    uv tool list | log_lines
  fi
}

print_help() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  all              Run every step below, in order
  uv               Install uv (skipped if already installed)
  enable_linger    Enable linger for the current user (loginctl enable-linger)
  tools            Install every tool listed in pseti-tools.toml: for a
                   github URL source (requires "branch"), clone/update it
                   under .tool-sources/<name> and "uv tool install ." from
                   there; for source = "public", "uv tool install <name>"
                   from PyPI
  log_dir          Create the [logs].dir directory from pseti-tools.toml
                   (skipped if it already exists). Falls back to sudo (and
                   will prompt for a password) if a plain mkdir fails, then
                   chowns the directory to the current user.
  linger_service   Create/update both systemd --user services: ${SERVICE_NAME}
                   (oneshot; runs each non-daemon tool's "cmd" once after
                   boot) and ${DAEMON_SERVICE_NAME} (restarted on crash;
                   runs each tool with mode = "daemon"). Always overwrites
                   both service files with the current config, then asks
                   whether to start them now.
  clean            Restore the system to its pre-install state: uninstall all
                   uv-installed CLI tools, stop/disable/remove both
                   pseti_daq services, and disable linger
  -h, --help       Show this help message

Examples:
  $(basename "$0") all
  $(basename "$0") uv
  $(basename "$0") linger_service
  $(basename "$0") clean
EOF
}

main() {
  local cmd="${1:-}"

  case "$cmd" in
    all)
      run_step "Install uv" install_uv
      run_step "Enable linger" enable_linger
      run_step "Install CLI tools" install_tools
      run_step "Create log directory" create_log_dir
      run_step "Create/update systemd services" create_systemd_services
      run_step "Start systemd services" confirm_and_start_services
      log "All steps completed."
      ;;
    uv)
      run_step "Install uv" install_uv
      ;;
    enable_linger)
      run_step "Enable linger" enable_linger
      ;;
    tools)
      run_step "Install CLI tools" install_tools
      ;;
    log_dir)
      run_step "Create log directory" create_log_dir
      ;;
    linger_service)
      run_step "Create/update systemd services" create_systemd_services
      run_step "Start systemd services" confirm_and_start_services
      ;;
    clean)
      run_step "Uninstall uv tools" uninstall_tools
      run_step "Remove systemd services" remove_systemd_services
      run_step "Disable linger" disable_linger
      log "Clean complete."
      ;;
    -h|--help)
      print_help
      ;;
    *)
      print_help
      exit 1
      ;;
  esac
}

main "$@"
