#!/bin/bash

# Docker etc
mkdir ~/docker/
mkdir ~/docker/prometheus/

# Docker Compose Prometheus
wget -O ~/docker/prometheus/compose.yml https://raw.githubusercontent.com/SyafaHadyan/docker-compose/refs/heads/main/src/prometheus/prometheus.yml
wget -O ~/prometheus.yml https://raw.githubusercontent.com/SyafaHadyan/docker-sync/refs/heads/main/src/prometheus.yml

cd ~/docker/prometheus/
docker compose up -d
cd
