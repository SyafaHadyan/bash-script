#!/bin/bash
#
# setup-mac-mini.sh - unattended Mac Mini lab provisioning
#
# Usage (run on the target Mac Mini, logged into the pre-existing
# "Lab Pembelajaran N" account, in Terminal):
#
#   sudo bash setup-mac-mini.sh install
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
#   7. Enable Remote Login (SSH) and Remote Management/Screen Sharing
#      (access granted to General).
#   8. Install Homebrew (if missing) and Android Studio for General.
#
# Other subcommands:
#   update     re-copy an updated script and (re-)register the daemon;
#              run this after adding/changing steps to apply them to a
#              machine that's already partway done or fully finished -
#              each step's completion is tracked independently (a marker
#              file per step name, not a single furthest-position pointer),
#              so new steps can be inserted or appended anywhere without
#              disturbing steps already completed on that machine
#   status     show which steps are done/pending + recent log lines
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
DONE_DIR="$STATE_DIR/done"
LOCK_DIR="$STATE_DIR/run.lock"
LOG_FILE="/var/log/mac-mini-setup.log"
SCRIPT_INSTALL_PATH="/usr/local/mac-setup/mac_mini_setup.sh"
LABEL="com.labsetup.macsetup"
PLIST_PATH="/Library/LaunchDaemons/$LABEL.plist"

GENERAL_USER="General"
GENERAL_PASS="123456789"

# Every step tracked here, in the order run_steps executes them. Completion
# is tracked per-name (a marker file per step), not by position in this
# list, so a new step can be inserted or appended anywhere later without
# affecting whether already-finished steps re-run.
STEPS=(LAB_PREFS GENERAL_CREATED SETUP_ASSISTANT GENERAL_PREFS BANNER OS_UPDATE POWER_CONFIG SSH_ENABLED REMOTE_DESKTOP HOMEBREW ANDROID_STUDIO)

if [ "$(uname -m)" = "arm64" ]; then
  BREW_PREFIX="/opt/homebrew"
else
  BREW_PREFIX="/usr/local"
fi

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "must be run as root, e.g.: sudo bash $0 $*" >&2
    exit 1
  fi
}

is_done() {
  [ -f "$DONE_DIR/$1" ]
}

mark_done() {
  mkdir -p "$DONE_DIR"
  touch "$DONE_DIR/$1"
  log "marked done: $1"
}

all_done() {
  local s
  for s in "${STEPS[@]}"; do
    is_done "$s" || return 1
  done
  return 0
}

# Guards steps that depend on another step having actually run first
# (e.g. anything touching General's account needs GENERAL_CREATED). Returns
# failure without marking the caller done, so it's retried on a later pass
# instead of being marked complete despite its prerequisite missing -
# matters if the step blocks below ever get reordered in the script.
require_done() {
  if ! is_done "$1"; then
    log "WARNING: prerequisite '$1' not done yet, skipping this step for now"
    return 1
  fi
  return 0
}

find_lab_user() {
  # The account's short (Unix) username usually isn't "Lab Pembelajaran N"
  # verbatim - macOS's Setup Assistant strips spaces/lowercases it when
  # generating the short name from the full name typed at first boot. Match
  # on RealName (the actual full name) and resolve back to the short name.
  local user
  user=$(dscl . -list /Users RealName 2>/dev/null \
    | grep -E '^[^[:space:]]+[[:space:]]+Lab Pembelajaran [0-9]+$' \
    | awk '{print $1}' \
    | head -1)
  if [ -z "$user" ]; then
    user=$(dscl . -list /Users 2>/dev/null | grep -E '^Lab Pembelajaran [0-9]+$' | head -1)
  fi
  echo "$user"
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

suppress_first_login_setup_assistant() {
  local user="$1"
  log "pre-seeding SetupAssistant markers for $user so first-login onboarding screens don't block auto-login"
  local os_version os_build
  os_version=$(sw_vers -productVersion)
  os_build=$(sw_vers -buildVersion)
  sudo -u "$user" defaults write com.apple.SetupAssistant DidSeeCloudSetup -bool true
  sudo -u "$user" defaults write com.apple.SetupAssistant DidSeeSiriSetup -bool true
  sudo -u "$user" defaults write com.apple.SetupAssistant DidSeePrivacy -bool true
  sudo -u "$user" defaults write com.apple.SetupAssistant DidSeePrivacyAppBundle -bool true
  sudo -u "$user" defaults write com.apple.SetupAssistant DidSeeTrueTonePairing -bool true
  sudo -u "$user" defaults write com.apple.SetupAssistant DidSeeAppearanceSetup -bool true
  sudo -u "$user" defaults write com.apple.SetupAssistant LastSeenCloudProductVersion -string "$os_version"
  sudo -u "$user" defaults write com.apple.SetupAssistant LastSeenBuddyBuildVersion -string "$os_build"
  # These exact keys/panes have shifted across macOS releases (same
  # unreliability class as auto-login itself) - if a screen still appears
  # on first login, check what's new for this OS version and add its key.
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

# Live check instead of a trusted flag, deliberately: this step's own
# reboot can kill the script before we can honestly confirm success, so
# "done" must be verified against actual system state every time rather
# than assumed the moment the install/update command was launched.
os_update_pending() {
  local current_major latest_version latest_major
  current_major=$(sw_vers -productVersion | cut -d. -f1)
  latest_version=$(softwareupdate --list-full-installers 2>/dev/null \
    | grep -o 'Version: [0-9.]*' | sed 's/Version: //' \
    | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
  latest_major=$(echo "$latest_version" | cut -d. -f1)
  if [ -n "$latest_major" ] && [ "$latest_major" -gt "$current_major" ]; then
    return 0
  fi
  if softwareupdate -l 2>&1 | grep -qi "no new software available"; then
    return 1
  fi
  return 0
}

upgrade_macos() {
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
  if ! echo "$out" | grep -qi "No updates are available"; then
    # softwareupdate's own --restart will reboot the machine shortly.
    exit 0
  fi
}

install_homebrew_for_user() {
  local user="$1"
  if sudo -u "$user" test -x "$BREW_PREFIX/bin/brew"; then
    log "Homebrew already installed for $user"
    return
  fi
  log "installing Homebrew for $user"
  # Homebrew refuses to run as root, and its installer needs the prefix dir
  # to already be writable by the target user to avoid its own sudo prompts.
  mkdir -p "$BREW_PREFIX"
  chown -R "$user:admin" "$BREW_PREFIX"
  sudo -u "$user" /bin/bash -c \
    "NONINTERACTIVE=1 $(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
    2>&1 | tee -a "$LOG_FILE"
}

configure_brew_shellenv_for_user() {
  local user="$1" home line profile
  home=$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
  [ -z "$home" ] && home="/Users/$user"
  profile="$home/.zprofile"
  line="eval \"\$($BREW_PREFIX/bin/brew shellenv)\""
  # brew's installer only prints this as a suggested next step, it never
  # touches shell config itself - without it, `brew`/anything it installs
  # is invisible to a Terminal the user actually opens.
  if [ -f "$profile" ] && grep -qF "$line" "$profile"; then
    log "Homebrew shellenv already configured for $user"
    return
  fi
  log "adding Homebrew shellenv to $profile"
  sudo -u "$user" /usr/bin/env bash -c "printf '%s\n' '$line' >> '$profile'"
}

install_android_studio_for_user() {
  local user="$1"
  if sudo -u "$user" test -d "/Applications/Android Studio.app"; then
    log "Android Studio already installed"
    return
  fi
  log "installing Android Studio via Homebrew cask for $user"
  sudo -u "$user" "$BREW_PREFIX/bin/brew" install --cask android-studio 2>&1 | tee -a "$LOG_FILE"
}

configure_power_on_ac() {
  log "enabling automatic startup after power is restored (closest Mac equivalent to power-on-when-AC-connected)"
  pmset -a autorestart 1
}

enable_remote_login() {
  log "enabling Remote Login (SSH)"
  systemsetup -setremotelogin on 2>&1 | tee -a "$LOG_FILE"
}

enable_remote_management() {
  local user="$1"
  log "enabling Remote Management (Screen Sharing) for $user"
  /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
    -activate -configure -access -on \
    -privs -all \
    -users "$user" \
    -restart -agent -menu 2>&1 | tee -a "$LOG_FILE"
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
  log "=== run started ==="

  if ! is_done LAB_PREFS; then
    local labuser
    labuser=$(find_lab_user)
    if [ -z "$labuser" ]; then
      log "ERROR: no 'Lab Pembelajaran N' account found, cannot continue"
      exit 1
    fi
    apply_user_prefs "$labuser"
    mark_done LAB_PREFS
  fi

  if ! is_done GENERAL_CREATED; then
    create_general_account
    disable_filevault_if_needed
    configure_autologin "$GENERAL_USER" "$GENERAL_PASS"
    mark_done GENERAL_CREATED
  fi

  if ! is_done SETUP_ASSISTANT; then
    if require_done GENERAL_CREATED; then
      suppress_first_login_setup_assistant "$GENERAL_USER"
      mark_done SETUP_ASSISTANT
    fi
  fi

  if ! is_done GENERAL_PREFS; then
    if require_done GENERAL_CREATED; then
      apply_user_prefs "$GENERAL_USER"
      mark_done GENERAL_PREFS
    fi
  fi

  if ! is_done BANNER; then
    banner
    mark_done BANNER
  fi

  if ! is_done OS_UPDATE; then
    wait_for_internet
    if os_update_pending; then
      upgrade_macos
      # only reaches here if upgrade_macos didn't need to trigger its own
      # reboot (e.g. it found nothing left to do after all); re-check below
      # rather than assuming that means success.
    fi
    if os_update_pending; then
      log "WARNING: macOS update still appears pending, will retry on next run"
    else
      mark_done OS_UPDATE
    fi
  fi

  if ! is_done POWER_CONFIG; then
    configure_power_on_ac
    mark_done POWER_CONFIG
  fi

  if ! is_done SSH_ENABLED; then
    enable_remote_login
    mark_done SSH_ENABLED
  fi

  if ! is_done REMOTE_DESKTOP; then
    if require_done GENERAL_CREATED; then
      enable_remote_management "$GENERAL_USER"
      mark_done REMOTE_DESKTOP
    fi
  fi

  if ! is_done HOMEBREW; then
    if require_done GENERAL_CREATED; then
      install_homebrew_for_user "$GENERAL_USER"
      configure_brew_shellenv_for_user "$GENERAL_USER"
      mark_done HOMEBREW
    fi
  fi

  if ! is_done ANDROID_STUDIO; then
    if require_done HOMEBREW; then
      install_android_studio_for_user "$GENERAL_USER"
      mark_done ANDROID_STUDIO
    fi
  fi

  if all_done; then
    log "all currently defined steps complete, removing scheduled daemon"
    uninstall_daemon
  fi

  log "=== run finished ==="
}

install() {
  need_root
  mkdir -p "$(dirname "$SCRIPT_INSTALL_PATH")"
  cp "$0" "$SCRIPT_INSTALL_PATH"
  chmod 755 "$SCRIPT_INSTALL_PATH"
  mkdir -p "$DONE_DIR"

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

# Same as install(): re-copies the (possibly updated) script and makes sure
# the daemon is registered and running. Safe to call on an already-finished
# machine - existing step markers under $DONE_DIR are untouched, so this
# only picks up steps that don't have a marker yet (e.g. newly added ones).
update() {
  install
}

usage() {
  cat <<EOF
Usage: sudo bash $0 <command>
  install    copy self, register LaunchDaemon, start provisioning
  update     re-copy an updated script and (re-)register the daemon; use
             this after adding/changing steps in the script on a machine
             that's already partway through or fully finished
  run        run one pass of the state machine (used by the daemon)
  status     show which steps are done/pending and recent log output
  reset      forget all progress (start over, e.g. for a new Mac Mini)
  uninstall  remove the LaunchDaemon (progress markers are left untouched)
EOF
}

case "${1:-}" in
  install) need_root; install ;;
  update) need_root; update ;;
  run) need_root; run_steps ;;
  status)
    echo "steps:"
    for s in "${STEPS[@]}"; do
      if is_done "$s"; then echo "  [x] $s"; else echo "  [ ] $s"; fi
    done
    echo "---- last 40 log lines ----"
    tail -n 40 "$LOG_FILE" 2>/dev/null
    ;;
  reset)
    need_root
    rm -rf "$DONE_DIR"
    echo "progress reset, next 'install'/'update' or daemon run starts from step 1"
    ;;
  uninstall)
    need_root
    uninstall_daemon
    echo "daemon removed, recorded progress left in place"
    ;;
  *) usage; exit 1 ;;
esac
