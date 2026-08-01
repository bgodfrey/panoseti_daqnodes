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

# 3. Clone all submodules
clone_submodules() {
  log "Initializing and updating submodules..."
  git -C "$SCRIPT_DIR" submodule update --init --recursive

  log "Status: submodule commits"
  git -C "$SCRIPT_DIR" submodule status
}

# 4. Enter each submodule and install its CLI tool. If the tool is already
#    installed, force a reinstall so the latest local version is picked up.
install_submodule_tools() {
  log "Installing CLI tools from submodules..."
  git -C "$SCRIPT_DIR" submodule foreach --quiet '
    echo "  -> Installing tool from submodule: $name"
    pkg_name=$(grep "^name" pyproject.toml | head -n1 | cut -d\" -f2)
    if [ -n "$pkg_name" ] && uv tool list 2>/dev/null | grep -qE "^${pkg_name}[[:space:]]"; then
      echo "     $pkg_name is already installed, reinstalling to get the latest version..."
      uv tool install -q --reinstall . || echo "  !! Failed to reinstall tool from $name, skipping"
    else
      uv tool install -q . || echo "  !! Failed to install tool from $name, skipping"
    fi
  '

  log "Status: installed uv tools"
  uv tool list
}

# 5. Create (or update) the pseti_daq_startup systemd --user service.
#    Always (re)writes the service file with the current config, even if
#    one already exists.
create_systemd_service() {
  mkdir -p "$SYSTEMD_USER_DIR"
  mkdir -p "$(dirname "$RUNNER_SCRIPT")"

  # 6. Generate the runner script that starts all installed uv tools in
  #    parallel after boot, each with --profile palomar
  cat > "$RUNNER_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"

mapfile -t TOOLS < <(uv tool list 2>/dev/null | awk '/^- /{print $2}')

if [ "${#TOOLS[@]}" -eq 0 ]; then
  echo "No uv tools installed, nothing to start."
  exit 0
fi

pids=()
for tool in "${TOOLS[@]}"; do
  echo "Starting $tool --profile palomar"
  "$tool" --profile palomar &
  pids+=("$!")
done

# Wait for all tool processes in parallel; one exiting doesn't affect the others
wait "${pids[@]}"
EOF
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

# Uninstall every CLI tool that was installed via "uv tool install"
uninstall_tools() {
  log "Uninstalling uv-installed CLI tools..."
  if ! command -v uv >/dev/null 2>&1; then
    log "Status: uv is not installed, nothing to uninstall."
    return
  fi

  local packages
  mapfile -t packages < <(uv tool list 2>/dev/null | awk '!/^- /{print $1}')

  if [ "${#packages[@]}" -eq 0 ]; then
    log "Status: no uv tools installed."
    return
  fi

  for pkg in "${packages[@]}"; do
    log "Uninstalling $pkg..."
    uv tool uninstall -q "$pkg" || log "  !! Failed to uninstall $pkg"
  done

  log "Status: remaining uv tools"
  uv tool list
}

print_help() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  all              Run every step below, in order
  uv               Install uv (skipped if already installed)
  enable_linger    Enable linger for the current user (loginctl enable-linger)
  submodule        Clone/update all git submodules
  tools            Install the CLI tool from each submodule (uv tool install .)
  linger_service   Create/update and start the ${SERVICE_NAME} systemd --user
                   service, which runs every installed CLI tool with
                   --profile palomar after boot. Always overwrites the
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
      run_step "Clone submodules" clone_submodules
      run_step "Install submodule CLI tools" install_submodule_tools
      run_step "Create/update systemd service" create_systemd_service
      run_step "Start systemd service" start_systemd_service
      log "All steps completed. '${SERVICE_NAME}' will auto-run all installed CLI tools with --profile palomar after boot."
      ;;
    uv)
      run_step "Install uv" install_uv
      ;;
    enable_linger)
      run_step "Enable linger" enable_linger
      ;;
    submodule)
      run_step "Clone submodules" clone_submodules
      ;;
    tools)
      run_step "Install submodule CLI tools" install_submodule_tools
      ;;
    linger_service)
      run_step "Create/update systemd service" create_systemd_service
      run_step "Start systemd service" start_systemd_service
      ;;
    clean)
      run_step "Uninstall uv tools" uninstall_tools
      run_step "Remove systemd service" remove_systemd_service
      run_step "Disable linger" disable_linger
      log "Clean complete: uv tools uninstalled, ${SERVICE_NAME}.service removed, linger disabled."
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
