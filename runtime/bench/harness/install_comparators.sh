#!/bin/bash
# Installs the comparators on Ubuntu 24.04: docker.io, the oven/bun image,
# a native Bun under <prefix>/bun and the workerd release binary under
# <prefix>/workerd. Usage: install_comparators.sh <prefix>
set -euo pipefail
prefix=${1:?prefix}; mkdir -p "$prefix"
export DEBIAN_FRONTEND=noninteractive
sudo -n apt-get install -y -q docker.io >/dev/null
sudo -n systemctl enable --now docker >/dev/null
sudo -n docker pull -q oven/bun:1.4-slim
curl -fsSL https://bun.sh/install | BUN_INSTALL="$prefix/bun" bash >/dev/null
tag=$(curl -fsSL https://api.github.com/repos/cloudflare/workerd/releases/latest | grep -m1 '"tag_name"' | cut -d'"' -f4)
curl -fsSL -o "$prefix/workerd.gz" "https://github.com/cloudflare/workerd/releases/download/$tag/workerd-linux-$(uname -m | sed 's/aarch64/arm64/;s/x86_64/64/').gz"
gunzip -f "$prefix/workerd.gz" && chmod +x "$prefix/workerd"
echo "bun=$("$prefix/bun/bin/bun" --version) workerd=$("$prefix/workerd" --version) docker=$(sudo -n docker --version)"
