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
#   1. Detect the existing "Lab Pembelajaran N" account, set dark mode, max
#      mouse tracking speed, non-inverted scrolling, and disable the
#      lock/password screen after sleep or screensaver for it.
#   2. Create an admin account "General" (password 123456789), grant it a
#      Secure Token (via the Lab account's credentials - without this,
#      General can't authorize OS installs at all), disable FileVault
#      (required for auto-login to work at all), configure auto-login as
#      General.
#   3. Apply the same appearance/mouse/lock-screen prefs to General.
#   4. Print a large completion banner.
#   5. Wait for internet, then upgrade macOS to the latest available major
#      version (falls back to ordinary updates if already current),
#      restarting automatically as part of that.
#   6. Set "start up automatically when power is restored" (pmset autorestart)
#      - the closest real equivalent Mac Mini exposes to "power on when AC
#      connected"; there is no literal laptop-style AC-power-on toggle.
#   7. Enable Remote Login (SSH) and Remote Management/Screen Sharing
#      (access granted to General).
#   8. Install Homebrew for General (a general-purpose dependency for future
#      steps). Install Android Studio directly from Google's DMG (not via
#      Homebrew cask, which has had compatibility bugs on very new macOS
#      versions), pre-configured to skip sending usage statistics. The
#      first-run setup wizard itself is not suppressed - a person still
#      clicks through it once at the monitor. Clean up General's Dock down
#      to just Finder/Launchpad/Android Studio/Terminal and remove all
#      widgets/stacks (via dockutil). Install Tailscale (Homebrew cask) last
#      and add it as a login item so it launches automatically - the actual
#      "connect this device" login is deliberately not automated, do that
#      manually at the monitor.
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
PHASE_FILE="$STATE_DIR/phase"
GENERAL_USER_FILE="$STATE_DIR/general_username"
LOG_FILE="/var/log/mac-mini-setup.log"
SCRIPT_INSTALL_PATH="/usr/local/mac-setup/mac_mini_setup.sh"
LABEL="com.labsetup.macsetup"
PLIST_PATH="/Library/LaunchDaemons/$LABEL.plist"

# The account name is chosen interactively once, during install (the one
# point a human is actually at a terminal) and persisted here. Every later
# automatic 'run' (triggered by the daemon, no TTY attached) just reads it
# back instead of prompting - a prompt would hang forever with no input.
if [ -f "$GENERAL_USER_FILE" ]; then
  GENERAL_USER=$(cat "$GENERAL_USER_FILE")
else
  GENERAL_USER="General"
fi
GENERAL_PASS="123456789"
LAB_PASS="12345"

# Every step tracked here, in the order run_steps executes them. Completion
# is tracked per-name (a marker file per step), not by position in this
# list, so a new step can be inserted or appended anywhere later without
# affecting whether already-finished steps re-run.
STEPS=(LAB_PREFS GENERAL_CREATED SECURE_TOKEN SUDO_NOPASSWD SWITCH_TO_GENERAL SETUP_ASSISTANT GENERAL_PREFS BANNER OS_UPDATE POWER_CONFIG SSH_ENABLED REMOTE_DESKTOP HOMEBREW ANDROID_STUDIO DOCK_CLEANUP TAILSCALE)

if [ "$(uname -m)" = "arm64" ]; then
  BREW_PREFIX="/opt/homebrew"
else
  BREW_PREFIX="/usr/local"
fi

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

set_phase() {
  mkdir -p "$STATE_DIR"
  printf '%s' "$1" >"$PHASE_FILE"
  log "phase: $1"
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
  user=$(dscl . -list /Users RealName 2>/dev/null |
    grep -E '^[^[:space:]]+[[:space:]]+Lab Pembelajaran [0-9]+$' |
    awk '{print $1}' |
    head -1)
  if [ -z "$user" ]; then
    user=$(dscl . -list /Users 2>/dev/null | grep -E '^Lab Pembelajaran [0-9]+$' | head -1)
  fi
  echo "$user"
}

set_dark_mode() {
  sudo -u "$1" defaults write NSGlobalDomain AppleInterfaceStyle -string "Dark"
}

set_mouse_sensitivity_max() {
  # The Mouse settings pane actually writes tracking speed to the per-machine
  # ByHost domain (-currentHost), not the plain global domain - writing only
  # the plain domain leaves the value invisible to the pane/HID system until
  # next login. Write both so it's correct regardless of which one is read.
  sudo -u "$1" defaults write NSGlobalDomain com.apple.mouse.scaling -float 3.0
  sudo -u "$1" defaults -currentHost write NSGlobalDomain com.apple.mouse.scaling -float 3.0
}

set_mouse_not_inverted() {
  # "natural scrolling" is the only inversion toggle macOS exposes for
  # pointing devices; false = traditional/non-inverted direction. Same
  # ByHost caveat as tracking speed above.
  sudo -u "$1" defaults write NSGlobalDomain com.apple.swipescrolldirection -bool false
  sudo -u "$1" defaults -currentHost write NSGlobalDomain com.apple.swipescrolldirection -bool false
}

disable_screen_lock() {
  local user="$1"
  # askForPassword governs the lock prompt after both screensaver AND sleep
  # wake (one shared setting for both) - disabling it means even if the
  # screensaver or a sleep cycle happens, the session comes back straight to
  # the desktop instead of a login/unlock screen. idleTime 0 additionally
  # stops the screensaver from ever kicking in at all (ByHost, same as mouse
  # settings above), which also avoids it being visible on the monitor.
  sudo -u "$user" defaults write com.apple.screensaver askForPassword -int 0
  sudo -u "$user" defaults write com.apple.screensaver askForPasswordDelay -int 0
  sudo -u "$user" defaults -currentHost write com.apple.screensaver idleTime -int 0
}

# Nudges an already-running session to actually reflect prefs just written
# to disk. Only meaningful when $user is the currently active console user
# (e.g. Lab, since it's live while this script runs) - a brand new account's
# first-ever login reads these files fresh anyway and needs no nudge.
live_refresh_user_prefs() {
  local user="$1"
  [ "$(stat -f%Su /dev/console 2>/dev/null)" = "$user" ] || return
  sudo -u "$user" osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to true' >/dev/null 2>&1
  sudo -u "$user" killall cfprefsd >/dev/null 2>&1
  sudo -u "$user" killall Dock >/dev/null 2>&1
  sudo -u "$user" killall SystemUIServer >/dev/null 2>&1
  # Mouse tracking speed specifically has no reliable live-refresh hook short
  # of logout/login - this is a platform limitation, not something to trust
  # blindly took effect. Verify manually if it still looks unchanged on screen.
}

apply_user_prefs() {
  local user="$1"
  log "applying appearance/mouse/lock-screen prefs to $user"
  set_dark_mode "$user"
  set_mouse_sensitivity_max "$user"
  set_mouse_not_inverted "$user"
  disable_screen_lock "$user"
  live_refresh_user_prefs "$user"
}

create_general_account() {
  if dscl . -list /Users 2>/dev/null | grep -qx "$GENERAL_USER"; then
    log "$GENERAL_USER account already exists, skipping creation"
    return
  fi
  log "creating admin account $GENERAL_USER"
  sysadminctl -addUser "$GENERAL_USER" -fullName "$GENERAL_USER" -password "$GENERAL_PASS" -admin 2>&1 | tee -a "$LOG_FILE"
}

has_secure_token() {
  sysadminctl -secureTokenStatus "$1" 2>&1 | grep -qi "ENABLED"
}

grant_secure_token() {
  local target_user="$1" target_pass="$2" admin_user="$3" admin_pass="$4"
  # A newly created account has no Secure Token unless granted by an
  # existing Secure Token holder authenticating for it. Without one, macOS
  # refuses to let that account authorize OS installs/updates on the boot
  # volume ("you need to be an owner of this Mac" in the installer GUI).
  if has_secure_token "$target_user"; then
    log "$target_user already has a Secure Token"
    return
  fi
  if [ -z "$admin_user" ]; then
    log "WARNING: no existing Secure Token holder found to grant one to $target_user"
    return
  fi
  log "granting Secure Token to $target_user via $admin_user"
  sysadminctl -secureTokenOn "$target_user" -password "$target_pass" \
    -adminUser "$admin_user" -adminPassword "$admin_pass" 2>&1 | tee -a "$LOG_FILE"
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
  : >"$out"
  for ((i = 0; i <= len; i++)); do
    if [ "$i" -lt "$len" ]; then
      byte=$(printf '%d' "'${pass:$i:1}")
    else
      byte=0
    fi
    kbyte=${key[$((i % ${#key[@]}))]}
    xbyte=$((byte ^ kbyte))
    printf "\\$(printf '%03o' "$xbyte")" >>"$out"
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

# Logs the current session out so auto-login (already configured by this
# point) brings General up right away, instead of waiting for the eventual
# OS-upgrade reboot. Best-effort and one-shot: attempted once regardless of
# outcome, not retried every run - auto-login's own reliability is already a
# known caveat, and repeatedly trying to force a logout every boot would be
# disruptive if it's genuinely not going to take effect.
switch_to_general() {
  local console_user labuser
  console_user=$(stat -f%Su /dev/console 2>/dev/null || echo "")
  if [ "$console_user" = "$GENERAL_USER" ]; then
    log "$GENERAL_USER is already the active session, nothing to switch"
    return
  fi
  labuser=$(find_lab_user)
  if [ -z "$labuser" ] || [ "$console_user" != "$labuser" ]; then
    log "WARNING: current console user ('$console_user') isn't the Lab account, skipping automatic switch to $GENERAL_USER"
    return
  fi
  set_phase "logging out $labuser so auto-login brings up $GENERAL_USER"
  sudo -u "$labuser" osascript -e 'tell application "loginwindow" to «event aevtrlgo»' >/dev/null 2>&1
  local n=0
  while [ "$(stat -f%Su /dev/console 2>/dev/null)" != "$GENERAL_USER" ] && [ "$n" -lt 60 ]; do
    sleep 2
    n=$((n + 1))
  done
  if [ "$(stat -f%Su /dev/console 2>/dev/null)" = "$GENERAL_USER" ]; then
    log "switched to $GENERAL_USER"
  else
    log "WARNING: did not see $GENERAL_USER become the active session after logout, auto-login may not have taken effect - verify manually"
  fi
}

banner() {
  local msg="CORE SETUP STEPS COMPLETE"
  {
    printf '\n'
    printf '#%.0s' $(seq 1 70)
    printf '\n'
    printf '\n'
    printf '     %s\n' "$msg"
    printf '\n'
    printf '#%.0s' $(seq 1 70)
    printf '\n\n'
  } | tee -a "$LOG_FILE"

  local console_user
  console_user=$(stat -f%Su /dev/console 2>/dev/null || echo "")
  if [ -n "$console_user" ] && [ "$console_user" != "root" ] && [ "$console_user" != "loginwindow" ]; then
    sudo -u "$console_user" osascript -e \
      "display alert \"$msg\" message \"Lab and $GENERAL_USER accounts are configured. Now checking for macOS updates.\" as informational giving up after 15" \
      >/dev/null 2>&1
  fi
}

wait_for_internet() {
  set_phase "waiting for internet connectivity"
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
  latest_version=$(softwareupdate --list-full-installers 2>/dev/null |
    grep -o 'Version: [0-9.]*' | sed 's/Version: //' |
    sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
  latest_major=$(echo "$latest_version" | cut -d. -f1)
  if [ -n "$latest_major" ] && [ "$latest_major" -gt "$current_major" ]; then
    return 0
  fi
  # Match on an actual listed update entry (the "* Label: ..." structural
  # format), not a "nothing available" sentence - Apple has changed that
  # sentence's exact wording across releases before, while the structured
  # listing format for real entries has stayed stable for years.
  if softwareupdate -l 2>&1 | grep -qE '^\s*\*\s*Label:'; then
    return 0
  fi
  return 1
}

upgrade_macos() {
  set_phase "checking for available macOS updates"
  if ! has_secure_token "$GENERAL_USER"; then
    # A correct password alone isn't enough here - startosinstall's --user
    # authorizes against the boot volume, which macOS refuses for any
    # account without a Secure Token, and fails with a generic "failed to
    # authenticate" that looks identical to a wrong password. Bail out early
    # rather than let that misleading error surface downstream.
    log "ERROR: $GENERAL_USER lacks a Secure Token, cannot authorize this install yet - will retry once SECURE_TOKEN completes"
    return 1
  fi
  local current_major latest_version latest_major
  current_major=$(sw_vers -productVersion | cut -d. -f1)
  latest_version=$(softwareupdate --list-full-installers 2>/dev/null |
    grep -o 'Version: [0-9.]*' | sed 's/Version: //' |
    sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
  latest_major=$(echo "$latest_version" | cut -d. -f1)

  if [ -n "$latest_major" ] && [ "$latest_major" -gt "$current_major" ]; then
    set_phase "fetching full macOS installer (version $latest_version)"
    softwareupdate --fetch-full-installer --full-installer-version "$latest_version" 2>&1 | tee -a "$LOG_FILE"
    local installer_app
    installer_app=$(ls -d "/Applications/Install macOS"*.app 2>/dev/null | head -1)
    if [ -n "$installer_app" ]; then
      set_phase "installing macOS $latest_version - machine will restart automatically when ready"
      # A Secure Token alone doesn't tell startosinstall which account to
      # authenticate as - without --user/--stdinpass it falls back to an
      # interactive password prompt, which hangs forever with no TTY here.
      # No --restart flag: unlike softwareupdate, startosinstall has no such
      # option (some macOS/startosinstall versions reject it outright) - it
      # reboots into the installer environment automatically once staged,
      # that part was never optional to begin with.
      printf '%s\n' "$GENERAL_PASS" | "$installer_app/Contents/Resources/startosinstall" \
        --agreetolicense --nointeraction \
        --user "$GENERAL_USER" --stdinpass \
        2>&1 | tee -a "$LOG_FILE"
      exit 0
    fi
    log "WARNING: full installer app not found after fetch, falling back to incremental updates"
  fi

  set_phase "applying available incremental macOS updates"
  softwareupdate -ia --restart 2>&1 | tee -a "$LOG_FILE"
  # No text-matching on the output here, deliberately: if something actually
  # needed installing, --restart triggers a real reboot that ends this
  # process on its own regardless of what got printed; if nothing was
  # pending, control just falls through and the caller's os_update_pending
  # re-check (structural, not sentence-matching) decides whether this step
  # is actually done.
}

install_homebrew_for_user() {
  local user="$1"
  if sudo -u "$user" test -x "$BREW_PREFIX/bin/brew"; then
    log "Homebrew already installed for $user"
    return
  fi
  set_phase "installing Homebrew for $user"
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

tailscale_installed() {
  [ -d "/Applications/Tailscale.app" ]
}

install_tailscale_for_user() {
  local user="$1"
  if tailscale_installed; then
    log "Tailscale already installed"
    return 0
  fi
  set_phase "installing Tailscale"
  sudo -u "$user" "$BREW_PREFIX/bin/brew" install --cask tailscale 2>&1 | tee -a "$LOG_FILE"
  if tailscale_installed; then
    log "Tailscale installed"
    return 0
  fi
  log "ERROR: Tailscale.app not found in /Applications after brew install"
  return 1
}

tailscale_login_item_enabled() {
  sudo -u "$1" osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null |
    grep -qi "Tailscale"
}

enable_tailscale_launch_at_login() {
  local user="$1"
  if tailscale_login_item_enabled "$user"; then
    log "Tailscale already set to launch at login for $user"
    return
  fi
  log "adding Tailscale as a login item for $user"
  sudo -u "$user" osascript -e \
    'tell application "System Events" to make login item at end with properties {path:"/Applications/Tailscale.app", hidden:false}' \
    >/dev/null 2>&1
  # Connecting the device itself (tailscale up / signing into an identity
  # provider) needs a human at the GUI regardless - deliberately not
  # automated here, do that manually. macOS may also prompt for a one-time
  # System Settings > Network Extension approval on Tailscale's first
  # launch, same class of manual step as approving any VPN/network
  # extension app for the first time.
}

android_studio_installed() {
  [ -d "/Applications/Android Studio.app" ]
}

install_android_studio() {
  if android_studio_installed; then
    log "Android Studio already installed"
    return 0
  fi
  set_phase "downloading Android Studio installer"

  # Homebrew's cask API is unusable on some very new macOS versions (a bug
  # in Homebrew itself, confirmed via plain `brew info`/`brew search`
  # failing identically with no cask install involved at all) - installing
  # directly from Google's own DMG sidesteps Homebrew entirely.
  local arch_suffix
  if [ "$(uname -m)" = "arm64" ]; then
    arch_suffix='-mac_arm\.dmg'
  else
    arch_suffix='-mac\.dmg'
  fi

  # Google only publishes version-pinned download URLs, no stable/versionless
  # redirect exists - scrape the current version's link fresh each run
  # instead of hardcoding a version that will eventually 404.
  local dmg_url
  dmg_url=$(curl -fsSL https://developer.android.com/studio 2>/dev/null |
    grep -oE "https://edgedl\.me\.gvt1\.com/android/studio/install/[^\"]+${arch_suffix}" |
    head -1)
  if [ -z "$dmg_url" ]; then
    log "ERROR: could not find current Android Studio download URL on developer.android.com/studio"
    return 1
  fi

  local tmp_dmg
  tmp_dmg="$(mktemp -t android-studio).dmg"
  log "downloading Android Studio from $dmg_url"
  if ! curl -fsSL "$dmg_url" -o "$tmp_dmg"; then
    log "ERROR: failed to download Android Studio DMG"
    rm -f "$tmp_dmg"
    return 1
  fi

  set_phase "installing Android Studio"
  local mount_point
  mount_point=$(hdiutil attach -nobrowse "$tmp_dmg" 2>&1 | grep -o '/Volumes/.*' | tail -1)
  if [ -z "$mount_point" ] || [ ! -d "$mount_point" ]; then
    log "ERROR: failed to mount Android Studio DMG"
    rm -f "$tmp_dmg"
    return 1
  fi

  local app_src
  app_src=$(ls -d "$mount_point"/*.app 2>/dev/null | head -1)
  if [ -z "$app_src" ]; then
    log "ERROR: no .app bundle found in mounted Android Studio DMG"
    hdiutil detach -quiet "$mount_point" >/dev/null 2>&1
    rm -f "$tmp_dmg"
    return 1
  fi

  cp -R "$app_src" "/Applications/"
  hdiutil detach -quiet "$mount_point" >/dev/null 2>&1
  rm -f "$tmp_dmg"

  if android_studio_installed; then
    log "Android Studio installed to /Applications"
    return 0
  fi
  log "ERROR: Android Studio.app not found in /Applications after copy"
  return 1
}

android_studio_usage_stats_opted_out() {
  local home
  home=$(dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
  [ -z "$home" ] && home="/Users/$1"
  grep -q "rsch.send.usage.stat:[0-9.]*:0:" "$home/Library/Application Support/Google/consentOptions/accepted" 2>/dev/null
}

configure_android_studio_no_usage_stats() {
  local user="$1" home
  if android_studio_usage_stats_opted_out "$user"; then
    log "Android Studio usage-statistics opt-out already configured for $user"
    return
  fi
  home=$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
  [ -z "$home" ] && home="/Users/$user"
  log "opting $user out of Android Studio usage statistics"
  # JetBrains-platform apps (Android Studio included) store this consent
  # decision as a semicolon-separated ConfirmedConsent list at
  # consentOptions/accepted under the vendor's shared app-config directory
  # ("Google" here, not versioned per-release) - confirmed against
  # JetBrains' own ConsentOptions.java source. "rsch.send.usage.stat" (no
  # trailing s) is the actual consent ID used there; entry format is
  # id:version:accepted(0|1):timestamp-ms. Pre-seeding this file before
  # first launch means the IDE sees a decision already on record and skips
  # asking.
  local consent_dir="$home/Library/Application Support/Google/consentOptions"
  local ts
  ts="$(date +%s)000"
  sudo -u "$user" mkdir -p "$consent_dir"
  sudo -u "$user" /usr/bin/env bash -c "printf '%s' 'rsch.send.usage.stat:1.1:0:$ts' > '$consent_dir/accepted'"
}

dockutil_installed_for_user() {
  sudo -u "$1" test -x "$BREW_PREFIX/bin/dockutil"
}

install_dockutil_for_user() {
  local user="$1"
  if dockutil_installed_for_user "$user"; then
    return 0
  fi
  sudo -u "$user" "$BREW_PREFIX/bin/brew" install dockutil 2>&1 | tee -a "$LOG_FILE"
  dockutil_installed_for_user "$user"
}

# Finder isn't a persistent-apps entry at all (it's a fixed tile dockutil
# doesn't touch), so the kept set here only needs to name the other three.
dock_cleaned_up() {
  local user="$1" names extra
  names=$(sudo -u "$user" "$BREW_PREFIX/bin/dockutil" --list 2>/dev/null | cut -f1)
  [ -z "$names" ] && return 1
  echo "$names" | grep -qx "Launchpad" || return 1
  echo "$names" | grep -qx "Android Studio" || return 1
  echo "$names" | grep -qx "Terminal" || return 1
  extra=$(echo "$names" | grep -vxE 'Launchpad|Android Studio|Terminal')
  [ -z "$extra" ]
}

configure_dock_for_user() {
  local user="$1" dockutil="$BREW_PREFIX/bin/dockutil"
  if ! install_dockutil_for_user "$user"; then
    log "ERROR: failed to install dockutil for $user"
    return 1
  fi
  if dock_cleaned_up "$user"; then
    log "Dock already cleaned up for $user (Finder/Launchpad/Android Studio/Terminal only, no widgets)"
    return 0
  fi
  log "cleaning up Dock for $user: unpinning everything except Finder/Launchpad/Android Studio/Terminal, removing widgets"
  # dockutil's "all" clears the whole dock plist in one go - both the
  # left-side pinned-apps section and the right-side folders/stacks/widgets
  # section - so this single call covers "remove all widgets" too, not just
  # the app icons.
  sudo -u "$user" "$dockutil" --remove all --no-restart
  sudo -u "$user" "$dockutil" --add '/System/Applications/Launchpad.app' --no-restart
  sudo -u "$user" "$dockutil" --add '/Applications/Android Studio.app' --no-restart
  sudo -u "$user" "$dockutil" --add '/System/Applications/Utilities/Terminal.app' --no-restart
  sudo -u "$user" killall Dock >/dev/null 2>&1
  if dock_cleaned_up "$user"; then
    log "Dock cleaned up for $user"
    return 0
  fi
  log "ERROR: Dock cleanup for $user did not verify cleanly"
  return 1
}

configure_power_on_ac() {
  log "enabling automatic startup after power is restored (closest Mac equivalent to power-on-when-AC-connected)"
  pmset -a autorestart 1
}

configure_passwordless_sudo_for_admin() {
  local marker="/etc/sudoers.d/99-admin-nopasswd"
  if admin_nopasswd_present; then
    log "passwordless sudo for admin already configured"
    return 0
  fi
  log "adding passwordless sudo for admin group"
  # visudo -cf was used here originally to validate before installing, but
  # it repeatedly hung indefinitely in this exact context (no TTY, launchd)
  # even with a bounded timeout wrapped around it - most likely a sudoers
  # lock file left behind by an earlier killed attempt, since SIGKILL skips
  # whatever cleanup visudo would normally do on exit. Rather than depend on
  # a tool that's proven unreliable here: this rule is a fixed, hardcoded,
  # known-valid sudoers line, not built from any variable or untrusted
  # input, so there's nothing an external syntax check would actually catch.
  # Write it directly with the permissions sudoers.d requires.
  mkdir -p "$(dirname "$marker")"
  local tmp
  tmp=$(mktemp)
  echo "%admin ALL=(ALL) NOPASSWD: ALL" >"$tmp"
  if ! install -m 0440 -o root -g wheel "$tmp" "$marker"; then
    log "ERROR: failed to write sudoers drop-in at $marker"
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
  # Verify against live content afterward instead of trusting the write
  # unconditionally - a previous version of this function always returned 0
  # here regardless of whether install actually succeeded, which is exactly
  # how this step could get silently marked done despite nothing actually
  # being in place.
  if admin_nopasswd_present; then
    log "passwordless sudo for admin group installed at $marker"
    return 0
  fi
  log "ERROR: wrote $marker but the rule still doesn't verify - check the file's content/permissions, and confirm /etc/sudoers actually has a '#includedir /private/etc/sudoers.d' line on this machine"
  return 1
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

prompt_for_general_username() {
  if [ -f "$GENERAL_USER_FILE" ]; then
    log "using previously chosen admin account name: $GENERAL_USER"
    return
  fi
  local name confirm
  while true; do
    read -rp "Account name for the new admin account [General]: " name
    name="${name:-General}"
    read -rp "Create admin account named '$name'? [y/N]: " confirm
    case "$confirm" in
    [yY] | [yY][eE][sS]) break ;;
    *) echo "Okay, let's try again." ;;
    esac
  done
  mkdir -p "$STATE_DIR"
  printf '%s' "$name" >"$GENERAL_USER_FILE"
  GENERAL_USER="$name"
  log "admin account name set to: $GENERAL_USER"
}

uninstall_daemon() {
  launchctl bootout system "$PLIST_PATH" >/dev/null 2>&1 || launchctl unload "$PLIST_PATH" >/dev/null 2>&1
  rm -f "$PLIST_PATH"
}

acquire_lock() {
  mkdir -p "$STATE_DIR"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ >"$LOCK_DIR/pid"
    return 0
  fi
  local existing_pid
  existing_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
  if [ -n "$existing_pid" ] && ! kill -0 "$existing_pid" 2>/dev/null; then
    log "reclaiming stale lock left by dead pid $existing_pid"
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null && echo $$ >"$LOCK_DIR/pid" && return 0
  fi
  return 1
}

release_lock() {
  rm -rf "$LOCK_DIR"
}

# Live-state predicates used by reconcile_state() below, reusing checks
# already embedded in each step's own function where one exists.
general_account_exists() {
  dscl . -list /Users 2>/dev/null | grep -qx "$GENERAL_USER"
}

# Always a live content check against the actual sudoers config, never a
# "does our marker file merely exist" shortcut - that shortcut is exactly
# what let this step get stuck reporting "not done" even after a valid rule
# was added by hand elsewhere (e.g. directly in /etc/sudoers), since a
# manual fix never creates our marker file at all. Whitespace around "="
# is tolerated too, since a hand-edited line won't necessarily match our
# own script's exact formatting.
admin_nopasswd_present() {
  grep -RqsE '^[[:space:]]*%admin[[:space:]]+ALL[[:space:]]*=[[:space:]]*\(ALL(:ALL)?\)[[:space:]]+NOPASSWD:[[:space:]]*ALL' \
    /etc/sudoers /etc/sudoers.d/ 2>/dev/null
}

setup_assistant_suppressed() {
  [ "$(sudo -u "$1" defaults read com.apple.SetupAssistant DidSeeCloudSetup 2>/dev/null)" = "1" ]
}

user_prefs_applied() {
  local user="$1" style scroll scaling lock_pref
  style=$(sudo -u "$user" defaults read NSGlobalDomain AppleInterfaceStyle 2>/dev/null)
  scroll=$(sudo -u "$user" defaults read NSGlobalDomain com.apple.swipescrolldirection 2>/dev/null)
  scaling=$(sudo -u "$user" defaults read NSGlobalDomain com.apple.mouse.scaling 2>/dev/null)
  lock_pref=$(sudo -u "$user" defaults read com.apple.screensaver askForPassword 2>/dev/null)
  [ "$style" = "Dark" ] || return 1
  [ "$scroll" = "0" ] || return 1
  [ "$lock_pref" = "0" ] || return 1
  awk -v v="${scaling:-0}" 'BEGIN{exit !(v+0>=2.9)}'
}

power_autorestart_enabled() {
  pmset -g | grep -qE 'autorestart[[:space:]]+1'
}

remote_login_enabled() {
  systemsetup -getremotelogin 2>/dev/null | grep -qi "On"
}

# Best-effort only - kickstart has no simple, documented one-line status
# check, this is a commonly used proxy, not a guaranteed-accurate signal.
remote_management_enabled() {
  [ "$(defaults read /Library/Preferences/com.apple.RemoteManagement.plist ARD_AllLocalUsers 2>/dev/null)" = "1" ]
}

homebrew_installed_for_user() {
  sudo -u "$1" test -x "$BREW_PREFIX/bin/brew"
}

CHECK_MISMATCHES=0

# Prints one integrity-check line and flags a mismatch either direction:
# marked done but live check disagrees (the concerning case - something
# claims to be finished but isn't), or not marked done but already true live
# (harmless - reconcile_state would backfill this on the next real run).
check_line() {
  local step="$1" live_ok="$2" live_desc="$3"
  local marker="pending"
  is_done "$step" && marker="done"
  local note=""
  if [ "$marker" = "done" ] && [ "$live_ok" = "0" ]; then
    note=" <-- MISMATCH: marked done but live check disagrees"
    CHECK_MISMATCHES=$((CHECK_MISMATCHES + 1))
  elif [ "$marker" = "pending" ] && [ "$live_ok" = "1" ]; then
    note=" <-- mismatch: already satisfied live, marker not set (self-heals on next run)"
    CHECK_MISMATCHES=$((CHECK_MISMATCHES + 1))
  fi
  printf "  %-18s marker=%-8s live=%s%s\n" "$step" "$marker" "$live_desc" "$note"
}

# Read-only: unlike reconcile_state, never touches any marker - just reports
# where the marker file and live system state actually agree or disagree.
check_state() {
  echo "integrity check:"
  local labuser console_user
  labuser=$(find_lab_user)
  console_user=$(stat -f%Su /dev/console 2>/dev/null)

  if [ -n "$labuser" ] && user_prefs_applied "$labuser"; then
    check_line LAB_PREFS 1 "confirmed"
  else
    check_line LAB_PREFS 0 "not satisfied"
  fi

  if general_account_exists; then
    check_line GENERAL_CREATED 1 "confirmed"
  else
    check_line GENERAL_CREATED 0 "not satisfied"
  fi

  if has_secure_token "$GENERAL_USER"; then
    check_line SECURE_TOKEN 1 "confirmed"
  else
    check_line SECURE_TOKEN 0 "not satisfied"
  fi

  if admin_nopasswd_present; then
    check_line SUDO_NOPASSWD 1 "confirmed"
  else
    check_line SUDO_NOPASSWD 0 "not satisfied"
  fi

  if [ "$console_user" = "$GENERAL_USER" ]; then
    check_line SWITCH_TO_GENERAL 1 "confirmed ($GENERAL_USER is active session)"
  else
    check_line SWITCH_TO_GENERAL 0 "not satisfied (active session: $console_user)"
  fi

  if setup_assistant_suppressed "$GENERAL_USER"; then
    check_line SETUP_ASSISTANT 1 "confirmed"
  else
    check_line SETUP_ASSISTANT 0 "not satisfied"
  fi

  if user_prefs_applied "$GENERAL_USER"; then
    check_line GENERAL_PREFS 1 "confirmed"
  else
    check_line GENERAL_PREFS 0 "not satisfied"
  fi

  local banner_marker="pending"
  is_done BANNER && banner_marker="done"
  printf "  %-18s marker=%-8s live=%s\n" "BANNER" "$banner_marker" "(no live check available)"

  if ! os_update_pending; then
    check_line OS_UPDATE 1 "confirmed (no update pending)"
  else
    check_line OS_UPDATE 0 "update still pending"
  fi

  if power_autorestart_enabled; then
    check_line POWER_CONFIG 1 "confirmed"
  else
    check_line POWER_CONFIG 0 "not satisfied"
  fi

  if remote_login_enabled; then
    check_line SSH_ENABLED 1 "confirmed"
  else
    check_line SSH_ENABLED 0 "not satisfied"
  fi

  if remote_management_enabled; then
    check_line REMOTE_DESKTOP 1 "confirmed (best-effort check)"
  else
    check_line REMOTE_DESKTOP 0 "not satisfied (best-effort check)"
  fi

  if homebrew_installed_for_user "$GENERAL_USER"; then
    check_line HOMEBREW 1 "confirmed"
  else
    check_line HOMEBREW 0 "not satisfied"
  fi

  if android_studio_installed; then
    check_line ANDROID_STUDIO 1 "confirmed"
  else
    check_line ANDROID_STUDIO 0 "not satisfied"
  fi

  if dock_cleaned_up "$GENERAL_USER"; then
    check_line DOCK_CLEANUP 1 "confirmed"
  else
    check_line DOCK_CLEANUP 0 "not satisfied"
  fi

  if tailscale_installed; then
    check_line TAILSCALE 1 "confirmed"
  else
    check_line TAILSCALE 0 "not satisfied"
  fi

  echo
  if [ "$CHECK_MISMATCHES" -eq 0 ]; then
    echo "no mismatches - marker state matches live system state for every checked step"
  else
    echo "$CHECK_MISMATCHES mismatch(es) found - run 'update' to reconcile automatically, or investigate manually"
  fi
}

# Runs before the main step sequence on every pass. A step's marker file is
# the fast path, but it isn't the only source of truth: markers can go
# missing or stop matching after the script itself changes (a step gets
# renamed, or the tracking mechanism changes, as already happened once in
# this script's history), and re-running some steps unmarked is more than
# just wasted time - REMOTE_DESKTOP's kickstart restarts the ARD agent and
# would interrupt an active screen-sharing session every single boot if its
# marker kept coming up missing. So: check live system state too, and
# backfill the marker if reality already satisfies it, instead of trusting
# the marker file alone. Not every step has a cheap, reliable live signal
# (BANNER has no system state to check; SWITCH_TO_GENERAL and REMOTE_DESKTOP
# already self-guard inside their own functions too) - this covers the
# steps where one exists.
reconcile_state() {
  if ! is_done LAB_PREFS; then
    local labuser
    labuser=$(find_lab_user)
    if [ -n "$labuser" ] && user_prefs_applied "$labuser"; then
      log "reconcile: appearance/mouse prefs already applied to $labuser, backfilling LAB_PREFS"
      mark_done LAB_PREFS
    fi
  fi
  if ! is_done GENERAL_CREATED && general_account_exists; then
    log "reconcile: $GENERAL_USER account already exists, backfilling GENERAL_CREATED"
    mark_done GENERAL_CREATED
  fi
  if ! is_done SECURE_TOKEN && has_secure_token "$GENERAL_USER"; then
    log "reconcile: $GENERAL_USER already has a Secure Token, backfilling SECURE_TOKEN"
    mark_done SECURE_TOKEN
  fi
  if ! is_done SUDO_NOPASSWD && admin_nopasswd_present; then
    log "reconcile: admin NOPASSWD rule already present, backfilling SUDO_NOPASSWD"
    mark_done SUDO_NOPASSWD
  fi
  if ! is_done SWITCH_TO_GENERAL && [ "$(stat -f%Su /dev/console 2>/dev/null)" = "$GENERAL_USER" ]; then
    log "reconcile: $GENERAL_USER is already the active session, backfilling SWITCH_TO_GENERAL"
    mark_done SWITCH_TO_GENERAL
  fi
  if ! is_done SETUP_ASSISTANT && setup_assistant_suppressed "$GENERAL_USER"; then
    log "reconcile: SetupAssistant markers already present for $GENERAL_USER, backfilling SETUP_ASSISTANT"
    mark_done SETUP_ASSISTANT
  fi
  if ! is_done GENERAL_PREFS && user_prefs_applied "$GENERAL_USER"; then
    log "reconcile: appearance/mouse prefs already applied to $GENERAL_USER, backfilling GENERAL_PREFS"
    mark_done GENERAL_PREFS
  fi
  if ! is_done OS_UPDATE && ! os_update_pending; then
    log "reconcile: no macOS update pending, backfilling OS_UPDATE"
    mark_done OS_UPDATE
  fi
  if ! is_done POWER_CONFIG && power_autorestart_enabled; then
    log "reconcile: power-on-after-failure already enabled, backfilling POWER_CONFIG"
    mark_done POWER_CONFIG
  fi
  if ! is_done SSH_ENABLED && remote_login_enabled; then
    log "reconcile: Remote Login already enabled, backfilling SSH_ENABLED"
    mark_done SSH_ENABLED
  fi
  if ! is_done REMOTE_DESKTOP && remote_management_enabled; then
    log "reconcile: Remote Management already enabled, backfilling REMOTE_DESKTOP"
    mark_done REMOTE_DESKTOP
  fi
  if ! is_done HOMEBREW && homebrew_installed_for_user "$GENERAL_USER"; then
    log "reconcile: Homebrew already installed for $GENERAL_USER, backfilling HOMEBREW"
    mark_done HOMEBREW
  fi
  if ! is_done ANDROID_STUDIO && android_studio_installed; then
    log "reconcile: Android Studio already installed, backfilling ANDROID_STUDIO"
    mark_done ANDROID_STUDIO
  fi
  if ! is_done DOCK_CLEANUP && dock_cleaned_up "$GENERAL_USER"; then
    log "reconcile: Dock already cleaned up for $GENERAL_USER, backfilling DOCK_CLEANUP"
    mark_done DOCK_CLEANUP
  fi
  if ! is_done TAILSCALE && tailscale_installed; then
    log "reconcile: Tailscale already installed, backfilling TAILSCALE"
    mark_done TAILSCALE
  fi
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
  reconcile_state
  # Unconditional and up front, not scoped to OS_UPDATE - HOMEBREW, Android
  # Studio's DMG download, and TAILSCALE/dockutil all curl/brew-install
  # something too, and used to only work by accident because OS_UPDATE ran
  # right before them and always called this first. Once OS_UPDATE grew its
  # own require_done gate, anything gated behind that (e.g. SECURE_TOKEN not
  # done yet) would skip straight past this call, leaving later steps to hit
  # a boot where the network genuinely isn't up yet and fail silently every
  # pass. wait_for_internet itself is cheap to call redundantly - it exits
  # immediately if already connected.
  wait_for_internet

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

  if ! is_done SECURE_TOKEN; then
    if require_done GENERAL_CREATED; then
      grant_secure_token "$GENERAL_USER" "$GENERAL_PASS" "$(find_lab_user)" "$LAB_PASS"
      if has_secure_token "$GENERAL_USER"; then
        mark_done SECURE_TOKEN
      else
        log "WARNING: $GENERAL_USER still lacks a Secure Token, will retry next run"
      fi
    fi
  fi

  if ! is_done SUDO_NOPASSWD; then
    if configure_passwordless_sudo_for_admin; then
      mark_done SUDO_NOPASSWD
    fi
  fi

  if ! is_done SWITCH_TO_GENERAL; then
    if require_done GENERAL_CREATED; then
      switch_to_general
      mark_done SWITCH_TO_GENERAL
    fi
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
    if require_done SECURE_TOKEN; then
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
      if homebrew_installed_for_user "$GENERAL_USER"; then
        mark_done HOMEBREW
      else
        log "WARNING: Homebrew installation for $GENERAL_USER did not succeed, will retry next run"
      fi
    fi
  fi

  if ! is_done ANDROID_STUDIO; then
    if require_done GENERAL_CREATED; then
      if install_android_studio; then
        configure_android_studio_no_usage_stats "$GENERAL_USER"
        mark_done ANDROID_STUDIO
      else
        log "WARNING: Android Studio installation did not succeed, will retry next run"
      fi
    fi
  fi

  if ! is_done DOCK_CLEANUP; then
    # Needs both: ANDROID_STUDIO so there's actually an app to pin, and
    # HOMEBREW since configure_dock_for_user installs dockutil via brew -
    # without this second guard, a machine where HOMEBREW got skipped would
    # have this step fail every single run with no obvious cause (brew
    # simply not existing yet at $BREW_PREFIX), instead of clearly waiting.
    if require_done ANDROID_STUDIO && require_done HOMEBREW; then
      if configure_dock_for_user "$GENERAL_USER"; then
        mark_done DOCK_CLEANUP
      else
        log "WARNING: Dock cleanup for $GENERAL_USER did not succeed, will retry next run"
      fi
    fi
  fi

  if ! is_done TAILSCALE; then
    if require_done HOMEBREW; then
      if install_tailscale_for_user "$GENERAL_USER"; then
        enable_tailscale_launch_at_login "$GENERAL_USER"
        mark_done TAILSCALE
      else
        log "WARNING: Tailscale installation did not succeed, will retry next run"
      fi
    fi
  fi

  if all_done; then
    log "all currently defined steps complete, removing scheduled daemon"
    uninstall_daemon
  fi

  set_phase "idle"
  log "=== run finished ==="
}

install() {
  need_root
  prompt_for_general_username
  mkdir -p "$(dirname "$SCRIPT_INSTALL_PATH")"
  cp "$0" "$SCRIPT_INSTALL_PATH"
  chmod 755 "$SCRIPT_INSTALL_PATH"
  mkdir -p "$DONE_DIR"

  cat >"$PLIST_PATH" <<PLIST
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

  # RunAtLoad=true means bootstrap already triggers the first run on its
  # own the moment the job is loaded - calling kickstart -k right after a
  # *fresh* bootstrap races that automatic launch and can leave two
  # run_steps() processes alive at once (this was the actual cause of
  # every log line appearing duplicated, not a visudo hang). Only kickstart
  # when the job was already loaded from a previous run, where RunAtLoad
  # won't fire again on its own and an explicit kick is genuinely needed.
  # Re-bootstrapping/loading an already-loaded job is also what throws
  # launchd's cryptic "5: Input/output error", so this check avoids that too.
  if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    launchctl kickstart -k "system/$LABEL" 2>/dev/null || true
  else
    launchctl bootstrap system "$PLIST_PATH" 2>/dev/null || launchctl load -w "$PLIST_PATH" 2>/dev/null
  fi
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
  check      integrity check - compare marker files against live system
             state for every step and flag any mismatch, read-only
  reset      forget all progress (start over, e.g. for a new Mac Mini)
  uninstall  remove the LaunchDaemon (progress markers are left untouched)
EOF
}

case "${1:-}" in
install)
  need_root
  install
  ;;
update)
  need_root
  update
  ;;
run)
  need_root
  run_steps
  ;;
status)
  # Only reconciles when run as root (reconcile_state shells out as other
  # users) - a plain non-root status call still works, it just shows
  # whatever the markers said as of the last real run/reconcile instead of
  # a fresh live check.
  [ "$(id -u)" -eq 0 ] && reconcile_state
  echo "admin account name: $GENERAL_USER"
  echo "current phase: $(cat "$PHASE_FILE" 2>/dev/null || echo "idle")"
  echo "steps:"
  for s in "${STEPS[@]}"; do
    if is_done "$s"; then echo "  [x] $s"; else echo "  [ ] $s"; fi
  done
  echo "---- last 40 log lines ----"
  tail -n 40 "$LOG_FILE" 2>/dev/null
  ;;
check)
  need_root
  check_state
  ;;
reset)
  need_root
  rm -rf "$DONE_DIR"
  rm -f "$GENERAL_USER_FILE"
  echo "progress reset, next 'install'/'update' or daemon run starts from step 1 (will re-prompt for account name)"
  ;;
uninstall)
  need_root
  uninstall_daemon
  echo "daemon removed, recorded progress left in place"
  ;;
*)
  usage
  exit 1
  ;;
esac
