#!/bin/bash

# Installs Homebrew and the Tailscale CLI formula (no GUI app), starts tailscaled
# as a system launchd service so it comes up at every boot, and joins the tailnet.
# Run it as the normal admin user, not as root.
# Optional: TS_AUTHKEY=tskey-... ./tailscale-mac.sh joins without the browser login.

set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "Run this as the normal admin user, not as root." >&2
  exit 1
fi

if [ "$(uname -m)" = "arm64" ]; then
  BREW_PREFIX="/opt/homebrew"
else
  BREW_PREFIX="/usr/local"
fi
BREW="$BREW_PREFIX/bin/brew"
TAILSCALE="$BREW_PREFIX/bin/tailscale"

# Install Homebrew
if [ ! -x "$BREW" ]; then
  # Download first so a failed curl stops the script instead of running an empty installer.
  installer="$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  NONINTERACTIVE=1 /bin/bash -c "$installer"
fi

# Put brew on PATH for this script and for future zsh login shells.
shellenv_line="eval \"\$($BREW shellenv)\""
touch "$HOME/.zprofile"
grep -qxF "$shellenv_line" "$HOME/.zprofile" || echo "$shellenv_line" >>"$HOME/.zprofile"
eval "$("$BREW" shellenv)"

# Install the Tailscale CLI formula (tailscale and tailscaled, no Tailscale.app).
"$BREW" list --formula tailscale >/dev/null 2>&1 || "$BREW" install tailscale

# brew refuses to download anything as root when the Cellar belongs to a normal user.
# Updating as this user first leaves nothing to fetch for the root run below.
"$BREW" update

# Start tailscaled as a system-wide launchd daemon (/Library/LaunchDaemons).
# It runs as root, starts at boot, and does not need anyone to log in.
services="$(sudo "$BREW" services list)"
if ! grep -Eq '^tailscale[[:space:]]+started' <<<"$services"; then
  sudo "$BREW" services start tailscale
fi

# Wait for the daemon socket instead of sleeping a fixed time.
for _ in $(seq 1 30); do
  [ -S /var/run/tailscaled.socket ] && break
  sleep 1
done
if [ ! -S /var/run/tailscaled.socket ]; then
  echo "tailscaled did not create its socket within 30 seconds." >&2
  exit 1
fi

# Join the tailnet. Without TS_AUTHKEY this prints a login URL and waits for sign-in.
up_args=(--operator="$USER")
if [ -n "${TS_AUTHKEY:-}" ]; then
  up_args+=(--auth-key="$TS_AUTHKEY")
fi
sudo "$TAILSCALE" up "${up_args[@]}"

"$TAILSCALE" status
