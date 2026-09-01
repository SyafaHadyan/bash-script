#!/bin/bash

set -exuo pipefail

NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install tailscale
sudo brew services start tailscale
sleep 15
sudo tailscale up --operator="$USER"
