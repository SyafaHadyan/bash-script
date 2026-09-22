#!/bin/bash
#
# mac_mini_setup.sh - unattended Mac Mini lab provisioning
#
# Usage (run on the target Mac Mini, logged into the pre-existing
# "Lab Pembelajaran N" account, in Terminal):
#
#   sudo bash mac_mini_setup.sh install
#
# That copies itself to /usr/local/mac-setup, registers a LaunchDaemon that
# fires on every boot, and runs the first step immediately. From then on the
# script resumes itself automatically across every reboot/login until done,
# then removes its own LaunchDaemon.
#
# Steps performed, in order, each skipped if already done:
#   1. Detect the existing "Lab Pembelajaran N" account, set dark mode,
#      max mouse tracking speed, and non-inverted scrolling for it.
#   2. Create an admin account "General" (password 123456789), disable
#      FileVault (required for auto-login to work at all), configure
#      auto-login as General.
#   3. Apply the same appearance/mouse prefs to General.
#   4. Print a large completion banner.
#   5. Wait for internet, then upgrade macOS to the latest available major
#      version (falls back to ordinary updates if already current),
#      restarting automatically as part of that.
#   6. Set "start up automatically when power is restored" (pmset autorestart)
#      - the closest real equivalent Mac Mini exposes to "power on when AC
#      connected"; there is no literal laptop-style AC-power-on toggle.
#
# Other subcommands:
#   status     print current state + recent log lines
#   reset      forget all progress, so a re-run starts from step 1 again
#              (use this when re-purposing the script for a *new* Mac Mini)
#   uninstall  remove the LaunchDaemon without touching recorded progress
#   run        (used internally by the LaunchDaemon) run one pass
#
# Known limitations, read before relying on this unattended:
#   - Auto-login is set via the legacy /etc/kcpassword + autoLoginUser
#     mechanism. Apple has progressively locked this down since Big Sur and
#     there is no fully supported CLI/API replacement outside of MDM. If the
#     Mac still shows a login screen after the first restart, log in as
#     General manually once and re-run this script (it will skip everything
#     already done and continue from where it left off).
#   - Disabling FileVault removes disk encryption. That's an explicit,
#     deliberate tradeoff here to make auto-login possible - reconsider if
#     these machines handle sensitive data.
#   - The macOS upgrade step can take a long time (large download + install)
#     and will reboot the machine on its own; do not expect it to finish
#     quickly.

set -uo pipefail

STATE_DIR="/var/db/macsetup"
STATE_FILE="$STATE_DIR/state"
LOCK_DIR="$STATE_DIR/run.lock"
LOG_FILE="/var/log/mac-mini-setup.log"
SCRIPT_INSTALL_PATH="/usr/local/mac-setup/mac_mini_setup.sh"
LABEL="com.labsetup.macsetup"
PLIST_PATH="/Library/LaunchDaemons/$LABEL.plist"

GENERAL_USER="General"
GENERAL_PASS="123456789"

STATES=(NEW LAB_PREFS_DONE GENERAL_CREATED GENERAL_PREFS_DONE BANNER_SHOWN OS_UPDATED POWER_CONFIGURED DONE)

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "must be run as root, e.g.: sudo bash $0 $*" >&2
    exit 1
  fi
}

get_state() {
  cat "$STATE_FILE" 2>/dev/null || echo "NEW"
}

set_state() {
  mkdir -p "$STATE_DIR"
  echo "$1" > "$STATE_FILE"
  log "state -> $1"
}

state_index() {
  local target="$1" i
  for i in "${!STATES[@]}"; do
    [ "${STATES[$i]}" = "$target" ] && { echo "$i"; return; }
  done
  echo -1
}

at_least() {
  local cur tgt
  cur=$(state_index "$(get_state)")
  tgt=$(state_index "$1")
  [ "$cur" -ge "$tgt" ]
}

find_lab_user() {
  dscl . -list /Users 2>/dev/null | grep -E '^Lab Pembelajaran [0-9]+$' | head -1
}

set_dark_mode() {
  sudo -u "$1" defaults write NSGlobalDomain AppleInterfaceStyle -string "Dark"
}

set_mouse_sensitivity_max() {
  sudo -u "$1" defaults write NSGlobalDomain com.apple.mouse.scaling -float 3.0
}

set_mouse_not_inverted() {
  # "natural scrolling" is the only inversion toggle macOS exposes for
  # pointing devices; false = traditional/non-inverted direction.
  sudo -u "$1" defaults write NSGlobalDomain com.apple.swipescrolldirection -bool false
}

apply_user_prefs() {
  local user="$1"
  log "applying appearance/mouse prefs to $user"
  set_dark_mode "$user"
  set_mouse_sensitivity_max "$user"
  set_mouse_not_inverted "$user"
  if [ "$(stat -f%Su /dev/console)" = "$user" ]; then
    sudo -u "$user" killall Dock >/dev/null 2>&1
    sudo -u "$user" killall SystemUIServer >/dev/null 2>&1
  fi
}

create_general_account() {
  if dscl . -list /Users 2>/dev/null | grep -qx "$GENERAL_USER"; then
    log "$GENERAL_USER account already exists, skipping creation"
    return
  fi
  log "creating admin account $GENERAL_USER"
  sysadminctl -addUser "$GENERAL_USER" -fullName "$GENERAL_USER" -password "$GENERAL_PASS" -admin 2>&1 | tee -a "$LOG_FILE"
}

disable_filevault_if_needed() {
  if fdesetup status | grep -q "FileVault is On"; then
    log "FileVault is on, disabling (required for auto-login)"
    fdesetup disable 2>&1 | tee -a "$LOG_FILE"
    if fdesetup status | grep -q "FileVault is On"; then
      log "WARNING: fdesetup disable did not take effect, may need an interactive admin password"
    fi
  else
    log "FileVault already off"
  fi
}

write_kcpassword() {
  local pass="$1" out="/etc/kcpassword"
  local key=(125 137 82 35 210 188 221 234 163 185 31)
  local i len byte kbyte xbyte
  len=${#pass}
  : > "$out"
  for ((i = 0; i <= len; i++)); do
    if [ "$i" -lt "$len" ]; then
      byte=$(printf '%d' "'${pass:$i:1}")
    else
      byte=0
    fi
    kbyte=${key[$((i % ${#key[@]}))]}
    xbyte=$((byte ^ kbyte))
    printf "\\$(printf '%03o' "$xbyte")" >> "$out"
  done
  chmod 600 "$out"
}

configure_autologin() {
  local user="$1" pass="$2"
  log "configuring auto-login for $user (legacy mechanism, verify manually if it doesn't take effect)"
  defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser -string "$user"
  write_kcpassword "$pass"
}

banner() {
  local msg="CORE SETUP STEPS COMPLETE"
  {
    printf '\n'
    printf '#%.0s' $(seq 1 70); printf '\n'
    printf '\n'
    printf '     %s\n' "$msg"
    printf '\n'
    printf '#%.0s' $(seq 1 70); printf '\n\n'
  } | tee -a "$LOG_FILE"

  local console_user
  console_user=$(stat -f%Su /dev/console 2>/dev/null || echo "")
  if [ -n "$console_user" ] && [ "$console_user" != "root" ] && [ "$console_user" != "loginwindow" ]; then
    sudo -u "$console_user" osascript -e \
      "display alert \"$msg\" message \"Lab and General accounts are configured. Now checking for macOS updates.\" as informational giving up after 15" \
      >/dev/null 2>&1
  fi
}

wait_for_internet() {
  log "waiting for internet connectivity..."
  local n=0
  until curl -fsS --max-time 5 https://captive.apple.com/hotspot-detect.html >/dev/null 2>&1; do
    n=$((n + 1))
    [ $((n % 20)) -eq 0 ] && log "still waiting for internet connectivity ($n checks so far)"
    sleep 15
  done
  log "internet connectivity confirmed"
}

upgrade_macos() {
  wait_for_internet

  local current_major latest_version latest_major
  current_major=$(sw_vers -productVersion | cut -d. -f1)
  latest_version=$(softwareupdate --list-full-installers 2>/dev/null \
    | grep -o 'Version: [0-9.]*' | sed 's/Version: //' \
    | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
  latest_major=$(echo "$latest_version" | cut -d. -f1)

  if [ -n "$latest_major" ] && [ "$latest_major" -gt "$current_major" ]; then
    log "newer major macOS version available ($latest_version), fetching full installer"
    softwareupdate --fetch-full-installer --full-installer-version "$latest_version" 2>&1 | tee -a "$LOG_FILE"
    local installer_app
    installer_app=$(ls -d "/Applications/Install macOS"*.app 2>/dev/null | head -1)
    if [ -n "$installer_app" ]; then
      set_state OS_UPDATED
      log "starting macOS upgrade install, machine will restart automatically when ready"
      "$installer_app/Contents/Resources/startosinstall" --agreetolicense --nointeraction --restart 2>&1 | tee -a "$LOG_FILE"
      exit 0
    fi
    log "WARNING: full installer app not found after fetch, falling back to incremental updates"
  fi

  log "applying available incremental updates"
  local out
  out=$(softwareupdate -ia --restart 2>&1)
  echo "$out" | tee -a "$LOG_FILE"
  set_state OS_UPDATED
  if ! echo "$out" | grep -qi "No updates are available"; then
    # softwareupdate's own --restart will reboot the machine shortly.
    exit 0
  fi
}

configure_power_on_ac() {
  log "enabling automatic startup after power is restored (closest Mac equivalent to power-on-when-AC-connected)"
  pmset -a autorestart 1
}

uninstall_daemon() {
  launchctl bootout system "$PLIST_PATH" >/dev/null 2>&1 || launchctl unload "$PLIST_PATH" >/dev/null 2>&1
  rm -f "$PLIST_PATH"
}

acquire_lock() {
  mkdir -p "$STATE_DIR"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_DIR/pid"
    return 0
  fi
  local existing_pid
  existing_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
  if [ -n "$existing_pid" ] && ! kill -0 "$existing_pid" 2>/dev/null; then
    log "reclaiming stale lock left by dead pid $existing_pid"
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null && echo $$ > "$LOCK_DIR/pid" && return 0
  fi
  return 1
}

release_lock() {
  rm -rf "$LOCK_DIR"
}

run_steps() {
  mkdir -p "$STATE_DIR"
  touch "$LOG_FILE"
  if ! acquire_lock; then
    log "another run is already in progress (pid $(cat "$LOCK_DIR/pid" 2>/dev/null)), exiting without doing anything"
    exit 0
  fi
  trap release_lock EXIT
  log "=== run started, current state: $(get_state) ==="

  if ! at_least LAB_PREFS_DONE; then
    local labuser
    labuser=$(find_lab_user)
    if [ -z "$labuser" ]; then
      log "ERROR: no 'Lab Pembelajaran N' account found, cannot continue"
      exit 1
    fi
    apply_user_prefs "$labuser"
    set_state LAB_PREFS_DONE
  fi

  if ! at_least GENERAL_CREATED; then
    create_general_account
    disable_filevault_if_needed
    configure_autologin "$GENERAL_USER" "$GENERAL_PASS"
    set_state GENERAL_CREATED
  fi

  if ! at_least GENERAL_PREFS_DONE; then
    apply_user_prefs "$GENERAL_USER"
    set_state GENERAL_PREFS_DONE
  fi

  if ! at_least BANNER_SHOWN; then
    banner
    set_state BANNER_SHOWN
  fi

  if ! at_least OS_UPDATED; then
    upgrade_macos
  fi

  if ! at_least POWER_CONFIGURED; then
    configure_power_on_ac
    set_state POWER_CONFIGURED
  fi

  if ! at_least DONE; then
    set_state DONE
    log "all steps complete, removing scheduled daemon"
    uninstall_daemon
  fi

  log "=== run finished, state: $(get_state) ==="
}

install() {
  need_root
  mkdir -p "$(dirname "$SCRIPT_INSTALL_PATH")"
  cp "$0" "$SCRIPT_INSTALL_PATH"
  chmod 755 "$SCRIPT_INSTALL_PATH"
  mkdir -p "$STATE_DIR"
  [ -f "$STATE_FILE" ] || set_state NEW

  cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$SCRIPT_INSTALL_PATH</string>
    <string>run</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOG_FILE</string>
  <key>StandardErrorPath</key><string>$LOG_FILE</string>
</dict>
</plist>
PLIST
  chmod 644 "$PLIST_PATH"

  launchctl bootstrap system "$PLIST_PATH" 2>/dev/null || launchctl load -w "$PLIST_PATH"
  launchctl kickstart -k "system/$LABEL" 2>/dev/null || true
  log "installed at $SCRIPT_INSTALL_PATH, daemon registered and started"
}

usage() {
  cat <<EOF
Usage: sudo bash $0 <command>
  install    copy self, register LaunchDaemon, start provisioning
  run        run one pass of the state machine (used by the daemon)
  status     show current state and recent log output
  reset      clear recorded progress (start over, e.g. for a new Mac Mini)
  uninstall  remove the LaunchDaemon (progress state is left untouched)
EOF
}

case "${1:-}" in
  install) install ;;
  run) need_root; run_steps ;;
  status)
    echo "state: $(get_state)"
    echo "---- last 40 log lines ----"
    tail -n 40 "$LOG_FILE" 2>/dev/null
    ;;
  reset)
    need_root
    rm -f "$STATE_FILE"
    echo "progress reset, next 'install' or daemon run starts from step 1"
    ;;
  uninstall)
    need_root
    uninstall_daemon
    echo "daemon removed, recorded progress left in place"
    ;;
  *) usage; exit 1 ;;
esac
