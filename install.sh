#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SERVICE_NAME="pseti_daq_startup"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SYSTEMD_USER_DIR/${SERVICE_NAME}.service"
RUNNER_SCRIPT="$SCRIPT_DIR/scripts/run_daq_tools.sh"
UV_BIN_DIR="$HOME/.local/bin"
DEPLOYED_RUNNER_SCRIPT="$UV_BIN_DIR/run_daq_tools.sh"
TOOLS_TOML="$SCRIPT_DIR/pseti-tools.toml"
TOOL_SOURCES_DIR="$SCRIPT_DIR/.tool-sources"
SEP_WIDTH=68
SEP="$(printf '%*s' "$SEP_WIDTH" '' | tr ' ' '-')"

log() { echo "[install.sh] $*"; }

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
  echo ""
  log "$SEP"
  log "$(center_line " STEP: $desc " "$SEP_WIDTH" '*')"
  log "$SEP"
  "$@"
  log "$SEP"
  log "$(center_line " DONE: $desc " "$SEP_WIDTH" '*')"
  log "$SEP"
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
# TOOL_NAMES/TOOL_SOURCES/TOOL_BRANCHES/TOOL_CMDS. The format is a flat set
# of [name] sections, each with "source", "branch", and "cmd" keys (quoted
# or unquoted); comments start with #.
parse_tools_toml() {
  TOOL_NAMES=()
  TOOL_SOURCES=()
  TOOL_BRANCHES=()
  TOOL_CMDS=()

  local current_name="" current_source="" current_branch="" current_cmd=""
  local line key val

  flush_tool() {
    if [ -n "$current_name" ]; then
      TOOL_NAMES+=("$current_name")
      TOOL_SOURCES+=("$current_source")
      TOOL_BRANCHES+=("$current_branch")
      TOOL_CMDS+=("$current_cmd")
    fi
  }

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue

    if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
      flush_tool
      current_name="${BASH_REMATCH[1]}"
      current_source=""
      current_branch=""
      current_cmd=""
    elif [[ "$line" =~ ^([A-Za-z0-9_.-]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      val="${val%\"}"
      val="${val#\"}"
      case "$key" in
        source) current_source="$val" ;;
        branch) current_branch="$val" ;;
        cmd) current_cmd="$val" ;;
      esac
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
    echo "     Updating cached clone of $url ($branch)..." >&2
    git -C "$dest" fetch --quiet origin "$branch" \
      && git -C "$dest" checkout --quiet "$branch" \
      && git -C "$dest" reset --quiet --hard "origin/$branch" \
      || { echo "  !! Failed to update $url ($branch), skipping" >&2; return 1; }
  else
    echo "     Cloning $url ($branch)..." >&2
    git clone --quiet --branch "$branch" "$url" "$dest" \
      || { echo "  !! Failed to clone $url ($branch), skipping" >&2; return 1; }
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
      echo "  -> Installing '$name' from PyPI"
      if uv tool list 2>/dev/null | grep -qE "^${name}[[:space:]]"; then
        echo "     $name is already installed, reinstalling to get the latest version..."
        uv tool install -q --reinstall "$name" || echo "  !! Failed to reinstall $name, skipping"
      else
        uv tool install -q "$name" || echo "  !! Failed to install $name, skipping"
      fi
      continue
    fi

    case "$source" in
      http://*|https://*|git@*|*.git)
        if [ -z "$branch" ]; then
          echo "  !! '$name' has a github source but no 'branch' field, skipping"
          continue
        fi
        echo "  -> Installing '$name' from $source (branch $branch)"
        src_dir="$(fetch_github_source "$name" "$source" "$branch")" || continue
        ;;
      *)
        echo "  !! Unknown source '$source' for '$name' (expected a github URL or \"public\"), skipping"
        continue
        ;;
    esac

    pkg_name="$(grep "^name" "$src_dir/pyproject.toml" 2>/dev/null | head -n1 | cut -d\" -f2)"
    [ -z "$pkg_name" ] && pkg_name="$name"

    if uv tool list 2>/dev/null | grep -qE "^${pkg_name}[[:space:]]"; then
      echo "     $pkg_name is already installed, reinstalling to get the latest version..."
      (cd "$src_dir" && uv tool install -q --reinstall .) || echo "  !! Failed to reinstall '$name', skipping"
    else
      (cd "$src_dir" && uv tool install -q .) || echo "  !! Failed to install '$name', skipping"
    fi
  done

  log "Status: installed uv tools"
  uv tool list
}

# 4. Create (or update) the pseti_daq_startup systemd --user service.
#    Always (re)writes the service file with the current config, even if
#    one already exists.
create_systemd_service() {
  mkdir -p "$SYSTEMD_USER_DIR"
  mkdir -p "$(dirname "$RUNNER_SCRIPT")"

  # 5. Generate the runner script that starts every tool's "cmd" from
  #    $TOOLS_TOML in parallel after boot
  parse_tools_toml
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    echo 'export PATH="$HOME/.local/bin:$PATH"'
    echo ''
    echo 'pids=()'
    echo ''
    local i cmd
    for ((i = 0; i < ${#TOOL_NAMES[@]}; i++)); do
      cmd="${TOOL_CMDS[$i]}"
      [ -z "$cmd" ] && continue
      printf 'echo "Starting: %s"\n' "$cmd"
      printf '%s &\n' "$cmd"
      echo 'pids+=("$!")'
      echo ''
    done
    echo 'if [ "${#pids[@]}" -eq 0 ]; then'
    echo '  echo "No tools configured in pseti-tools.toml, nothing to start."'
    echo '  exit 0'
    echo 'fi'
    echo ''
    echo '# Wait for all tool processes in parallel; one exiting does not affect the others'
    echo 'wait "${pids[@]}"'
  } > "$RUNNER_SCRIPT"
  chmod +x "$RUNNER_SCRIPT"

  # Deploy a copy to ~/.local/bin so the service keeps working even if this
  # repo checkout is later moved or deleted.
  mkdir -p "$UV_BIN_DIR"
  cp "$RUNNER_SCRIPT" "$DEPLOYED_RUNNER_SCRIPT"
  chmod +x "$DEPLOYED_RUNNER_SCRIPT"
  log "Deployed runner script to $DEPLOYED_RUNNER_SCRIPT"

  log "Creating/updating systemd user service: $SERVICE_FILE"
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=PANOSETI DAQ startup - launches all installed CLI tools
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$DEPLOYED_RUNNER_SCRIPT
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable "${SERVICE_NAME}.service"

  local enabled_status
  enabled_status="$(systemctl --user is-enabled "${SERVICE_NAME}.service" 2>&1 || true)"
  log "Status: ${SERVICE_NAME}.service enabled = $enabled_status"
}

# Start (or restart) the systemd --user service right now
start_systemd_service() {
  log "Starting ${SERVICE_NAME}.service..."
  systemctl --user start "${SERVICE_NAME}.service"

  local active_status
  active_status="$(systemctl --user is-active "${SERVICE_NAME}.service" 2>&1 || true)"
  log "Status: ${SERVICE_NAME}.service active = $active_status"
}

# Stop, disable, and remove the pseti_daq_startup systemd --user service
remove_systemd_service() {
  log "Stopping and disabling ${SERVICE_NAME}.service..."
  systemctl --user stop "${SERVICE_NAME}.service" 2>/dev/null || true
  systemctl --user disable "${SERVICE_NAME}.service" 2>/dev/null || true

  if [ -f "$SERVICE_FILE" ]; then
    rm -f "$SERVICE_FILE"
    log "Removed $SERVICE_FILE"
  fi
  if [ -f "$RUNNER_SCRIPT" ]; then
    rm -f "$RUNNER_SCRIPT"
    log "Removed $RUNNER_SCRIPT"
  fi
  if [ -f "$DEPLOYED_RUNNER_SCRIPT" ]; then
    rm -f "$DEPLOYED_RUNNER_SCRIPT"
    log "Removed $DEPLOYED_RUNNER_SCRIPT"
  fi

  systemctl --user daemon-reload

  local enabled_status
  enabled_status="$(systemctl --user is-enabled "${SERVICE_NAME}.service" 2>&1 || true)"
  log "Status: ${SERVICE_NAME}.service = $enabled_status"
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
    uv tool list
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
  linger_service   Create/update and start the ${SERVICE_NAME} systemd --user
                   service. The service runs each tool's "cmd" from
                   pseti-tools.toml after boot. Always overwrites the
                   service file with the current config.
  clean            Restore the system to its pre-install state: uninstall all
                   uv-installed CLI tools, stop/disable/remove the
                   ${SERVICE_NAME} service, and disable linger
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
      run_step "Create/update systemd service" create_systemd_service
      run_step "Start systemd service" start_systemd_service
      log "All steps completed. '${SERVICE_NAME}' will auto-run every tool from pseti-tools.toml after boot."
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
    linger_service)
      run_step "Create/update systemd service" create_systemd_service
      run_step "Start systemd service" start_systemd_service
      ;;
    clean)
      run_step "Uninstall uv tools" uninstall_tools
      run_step "Remove systemd service" remove_systemd_service
      run_step "Disable linger" disable_linger
      log "Clean complete: uv tools uninstalled, cached tool sources removed, ${SERVICE_NAME}.service removed, linger disabled."
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
