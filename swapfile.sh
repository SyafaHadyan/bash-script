#!/bin/bash

set -euxo pipefail

sudo dd if=/dev/zero of=/swapfile bs=1M count=4096
sudo chmod 600 /swapfile
sudo mkswap /swapfile
echo "/swapfile none swap sw,pri=1 0 0" | sudo tee -a /etc/fstab
sudo swapon -a
