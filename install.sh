#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SERVICE_NAME="pseti_daq_startup"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SYSTEMD_USER_DIR/${SERVICE_NAME}.service"
RUNNER_SCRIPT="$SCRIPT_DIR/scripts/run_daq_tools.sh"
UV_BIN_DIR="$HOME/.local/bin"

log() { echo "[install.sh] $*"; }

# 1. Install uv (skip if already installed)
install_uv() {
  if command -v uv >/dev/null 2>&1; then
    log "uv already installed: $(command -v uv)"
    return
  fi
  log "Installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$UV_BIN_DIR:$PATH"
}

# 2. Enable linger for the current user, so systemd --user services can
#    auto-start at boot even without an active login session
enable_linger() {
  log "Enabling linger for user $USER..."
  loginctl enable-linger "$USER"
}

# 3. Clone all submodules
clone_submodules() {
  log "Initializing and updating submodules..."
  git -C "$SCRIPT_DIR" submodule update --init --recursive
}

# 4. Enter each submodule and install its CLI tool
install_submodule_tools() {
  log "Installing CLI tools from submodules..."
  git -C "$SCRIPT_DIR" submodule foreach --quiet '
    echo "  -> Installing tool from submodule: $name"
    uv tool install . || echo "  !! Failed to install tool from $name, skipping"
  '
}

# 5. Create the pseti_daq_startup systemd --user service (skip if it already exists)
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

  if [ -f "$SERVICE_FILE" ]; then
    log "Service file $SERVICE_FILE already exists, skipping creation."
    return
  fi

  log "Creating systemd user service: $SERVICE_FILE"
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=PANOSETI DAQ startup - launches all installed CLI tools
After=network.target

[Service]
Type=simple
ExecStart=$RUNNER_SCRIPT
Restart=on-failure
RestartSec=5
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable "${SERVICE_NAME}.service"
  log "Service ${SERVICE_NAME}.service created and enabled."
}

# Start (or restart) the systemd --user service right now
start_systemd_service() {
  log "Starting ${SERVICE_NAME}.service..."
  systemctl --user start "${SERVICE_NAME}.service"
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
  linger_service   Create (if missing) and start the ${SERVICE_NAME} systemd --user
                   service, which runs every installed CLI tool with --profile palomar
                   after boot
  -h, --help       Show this help message

Examples:
  $(basename "$0") all
  $(basename "$0") uv
  $(basename "$0") linger_service
EOF
}

main() {
  local cmd="${1:-}"

  case "$cmd" in
    all)
      install_uv
      enable_linger
      clone_submodules
      install_submodule_tools
      create_systemd_service
      start_systemd_service
      log "Done. '${SERVICE_NAME}' will auto-run all installed CLI tools with --profile palomar after boot."
      ;;
    uv)
      install_uv
      ;;
    enable_linger)
      enable_linger
      ;;
    submodule)
      clone_submodules
      ;;
    tools)
      install_submodule_tools
      ;;
    linger_service)
      create_systemd_service
      start_systemd_service
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
