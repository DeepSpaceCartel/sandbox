#!/usr/bin/env bash
# Installs the tools the devcontainer Features don't cover.
# Idempotent: safe to re-run; each tool is skipped if already on PATH.
set -euo pipefail

BIN=/usr/local/bin
ARCH="$(dpkg --print-architecture)"   # amd64 | arm64
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

have() { command -v "$1" >/dev/null 2>&1; }

# Latest release tag of a GitHub repo, via the /releases/latest redirect (no API token needed).
latest() { curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest" | sed 's|.*/tag/||'; }

if ! have talosctl; then
  v="$(latest siderolabs/talos)"
  sudo curl -fsSL -o "$BIN/talosctl" "https://github.com/siderolabs/talos/releases/download/$v/talosctl-linux-$ARCH"
  sudo chmod +x "$BIN/talosctl"
fi

if ! have kubebuilder; then
  v="$(latest kubernetes-sigs/kubebuilder)"
  sudo curl -fsSL -o "$BIN/kubebuilder" "https://github.com/kubernetes-sigs/kubebuilder/releases/download/$v/kubebuilder_linux_$ARCH"
  sudo chmod +x "$BIN/kubebuilder"
fi

if ! have k9s; then
  v="$(latest derailed/k9s)"
  curl -fsSL "https://github.com/derailed/k9s/releases/download/$v/k9s_Linux_$ARCH.tar.gz" | tar -xz -C "$TMP" k9s
  sudo install -m 0755 "$TMP/k9s" "$BIN/k9s"
fi

# docker CLI + buildx plugin only: builds go to a remote BuildKit (no Docker daemon in the workspace).
if ! have docker; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq docker-cli
fi
if ! docker buildx version >/dev/null 2>&1; then
  v="$(latest docker/buildx)"
  mkdir -p "$HOME/.docker/cli-plugins"
  curl -fsSL -o "$HOME/.docker/cli-plugins/docker-buildx" "https://github.com/docker/buildx/releases/download/$v/buildx-$v.linux-$ARCH"
  chmod +x "$HOME/.docker/cli-plugins/docker-buildx"
fi

# 1Password CLI, from 1Password's apt repo (https://developer.1password.com/docs/cli/get-started/).
if ! have op; then
  curl -fsSL https://downloads.1password.com/linux/keys/1password.asc | sudo gpg --dearmor --yes -o /usr/share/keyrings/1password-archive-keyring.gpg
  echo "deb [arch=$ARCH signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/$ARCH stable main" \
    | sudo tee /etc/apt/sources.list.d/1password.list >/dev/null
  sudo mkdir -p /etc/debsig/policies/AC2D62742012EA22/ /usr/share/debsig/keyrings/AC2D62742012EA22
  curl -fsSL https://downloads.1password.com/linux/debian/debsig/1password.pol | sudo tee /etc/debsig/policies/AC2D62742012EA22/1password.pol >/dev/null
  curl -fsSL https://downloads.1password.com/linux/keys/1password.asc | sudo gpg --dearmor --yes -o /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg
  sudo apt-get update -qq && sudo apt-get install -y -qq 1password-cli
fi

# OP_SERVICE_ACCOUNT_TOKEN lives in the persistent home, never in the repo (see docs/setup/manual-prerequisites.md).
if [ -f "$HOME/.config/sandbox/op-token" ] && ! grep -q 'sandbox/op-token' "$HOME/.bashrc" 2>/dev/null; then
  echo 'export OP_SERVICE_ACCOUNT_TOKEN="$(cat "$HOME/.config/sandbox/op-token")"' >> "$HOME/.bashrc"
fi

for t in go node terraform kubectl helm gh claude talosctl kubebuilder k9s docker op; do
  printf '%-12s %s\n' "$t" "$(command -v "$t" || echo MISSING)"
done
