#!/bin/bash

# Package
sudo apt update
sudo apt upgrade -y
sudo apt install htop wget kitty-terminfo ufw cron -y

# ufw
sudo ufw allow OpenSSH
sudo ufw allow SSH
sudo ufw allow http
sudo ufw allow https
sudo ufw allow 9090
sudo ufw allow 9100
sudo ufw allow 22
sudo ufw --force enable

# Add Docker's official GPG key:
sudo apt-get update
sudo apt-get install ca-certificates curl -y
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" |
    sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update

# Install Docker
sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y

# Setup user
sudo groupadd docker
sudo usermod -aG docker $USER

# Swapfile
sudo dd if=/dev/zero of=/swapfile bs=1M count=4096
sudo chmod 600 /swapfile
sudo mkswap /swapfile
echo "/swapfile none swap sw,pri=1 0 0" | sudo tee -a /etc/fstab
sudo swapon -a

echo "Please log out and log back in to refresh"
echo "Modify /etc/fstab as needed"
