#!/usr/bin/env bash
# Idempotent Debian 13 installer for the Quadlets in this bundle.
set -Eeuo pipefail
umask 077

readonly PREFIX=/etc/crypto-daemons
readonly QUADLET_DIR=/etc/containers/systemd
readonly DATA_DIR=/srv/crypto-daemons
readonly ARTI_IMAGE=localhost/crypto-arti:2.5.1
readonly BUNDLE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo 'Run as root (for example: sudo ./setup.sh).' >&2
    exit 1
  fi
}

require_digest() {
  local name=$1 value=$2
  if [[ -z ${value} || ${value} != *@sha256:* ]]; then
    printf '%s must be an immutable image reference ending in @sha256:…\n' "$name" >&2
    exit 2
  fi
}

maybe_install_podman_desktop() {
  # Desktop is optional and deliberately defaults to no: servers are commonly
  # headless, while Flatpak is per-user rather than a system daemon dependency.
  local answer=${INSTALL_PODMAN_DESKTOP:-}
  local desktop_user=${PODMAN_DESKTOP_USER:-${SUDO_USER:-}}
  local desktop_home
  if [[ -z $answer && -t 0 ]]; then
    read -r -p 'Install Podman Desktop for a local GUI? [y/N] ' answer
  fi
  case ${answer,,} in
    y|yes)
      if [[ -z $desktop_user || $desktop_user == root ]]; then
        echo 'Set PODMAN_DESKTOP_USER to the desktop login when installing as root.' >&2
        return 1
      fi
      desktop_home=$(getent passwd "$desktop_user" | cut -d: -f6)
      if [[ -z $desktop_home ]]; then
        echo "Podman Desktop user does not exist: $desktop_user" >&2
        return 1
      fi
      apt-get install -y --no-install-recommends flatpak
      runuser -u "$desktop_user" -- env HOME="$desktop_home" \
        flatpak remote-add --if-not-exists --user flathub https://flathub.org/repo/flathub.flatpakrepo
      runuser -u "$desktop_user" -- env HOME="$desktop_home" \
        flatpak install -y --user flathub io.podman_desktop.PodmanDesktop
      echo "Podman Desktop installed for $desktop_user."
      ;;
    ''|n|no) ;;
    *)
      echo "Unrecognised INSTALL_PODMAN_DESKTOP value: $answer (use yes or no)." >&2
      return 2
      ;;
  esac
}

random_password() { openssl rand -base64 36 | tr -d '\n' | tr '/+' 'xy'; }

rpcauth_line() {
  local user=$1 password=$2 salt hash
  salt=$(openssl rand -hex 16)
  hash=$(printf '%s' "$password" | openssl dgst -sha256 -hmac "$salt" -binary | xxd -p -c 256)
  printf 'rpcauth=%s:%s$%s\n' "$user" "$salt" "$hash"
}

create_secrets_once() {
  local credential_file="$PREFIX/secrets/rpc-credentials.env"
  [[ -f $credential_file ]] && return

  local bitcoin_password litecoin_password monero_password
  bitcoin_password=$(random_password)
  litecoin_password=$(random_password)
  monero_password=$(random_password)

  install -d -m 0700 "$PREFIX/secrets"
  {
    printf 'BITCOIN_RPC_USER=bitcoinrpc\nBITCOIN_RPC_PASSWORD=%s\n' "$bitcoin_password"
    printf 'LITECOIN_RPC_USER=litecoinrpc\nLITECOIN_RPC_PASSWORD=%s\n' "$litecoin_password"
    printf 'MONERO_RPC_USER=monerorpc\nMONERO_RPC_PASSWORD=%s\n' "$monero_password"
  } >"$credential_file"
  rpcauth_line bitcoinrpc "$bitcoin_password" >"$PREFIX/secrets/bitcoin-rpcauth.conf"
  rpcauth_line litecoinrpc "$litecoin_password" >"$PREFIX/secrets/litecoin-rpcauth.conf"
  printf 'rpc-login=monerorpc:%s\n' "$monero_password" >"$PREFIX/secrets/monero-rpc.conf"
  chmod 0600 "$PREFIX/secrets"/*

  echo 'Generated RPC credentials (store these in a password manager now):'
  grep '_USER\|_PASSWORD' "$credential_file"
}

install_template() {
  local input=$1 output=$2
  sed \
    -e "s|@@BITCOIN_IMAGE@@|${BITCOIN_IMAGE}|g" \
    -e "s|@@LITECOIN_IMAGE@@|${LITECOIN_IMAGE}|g" \
    -e "s|@@MONERO_IMAGE@@|${MONERO_IMAGE}|g" \
    "$input" >"$output"
}

main() {
  require_root
  require_digest BITCOIN_IMAGE "${BITCOIN_IMAGE:-}"
  require_digest LITECOIN_IMAGE "${LITECOIN_IMAGE:-}"
  require_digest MONERO_IMAGE "${MONERO_IMAGE:-}"
  require_digest ARTI_RUST_IMAGE "${ARTI_RUST_IMAGE:-}"
  require_digest ARTI_RUNTIME_IMAGE "${ARTI_RUNTIME_IMAGE:-}"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends podman uidmap slirp4netns fuse-overlayfs \
    ca-certificates openssl xxd
  maybe_install_podman_desktop

  install -d -m 0755 "$PREFIX" "$QUADLET_DIR" "$DATA_DIR" \
    "$DATA_DIR/arti" "$DATA_DIR/bitcoin" "$DATA_DIR/litecoin" "$DATA_DIR/monero"
  create_secrets_once

  install -m 0644 "$BUNDLE_DIR/config/arti.toml" "$PREFIX/arti.toml"
  install -m 0644 "$BUNDLE_DIR/config/bitcoin.conf" "$PREFIX/bitcoin.conf"
  install -m 0644 "$BUNDLE_DIR/config/litecoin.conf" "$PREFIX/litecoin.conf"
  # monerod has no includeconf equivalent; build its config without printing its secret.
  install -m 0600 "$BUNDLE_DIR/config/monero.conf" "$PREFIX/monero.conf"
  sed -n '1,$p' "$PREFIX/secrets/monero-rpc.conf" >>"$PREFIX/monero.conf"

  install -m 0600 "$PREFIX/secrets/bitcoin-rpcauth.conf" "$PREFIX/bitcoin-rpcauth.conf"
  install -m 0600 "$PREFIX/secrets/litecoin-rpcauth.conf" "$PREFIX/litecoin-rpcauth.conf"
  {
    printf 'BITCOIN_IMAGE=%s\n' "$BITCOIN_IMAGE"
    printf 'LITECOIN_IMAGE=%s\n' "$LITECOIN_IMAGE"
    printf 'MONERO_IMAGE=%s\n' "$MONERO_IMAGE"
    printf 'ARTI_RUST_IMAGE=%s\n' "$ARTI_RUST_IMAGE"
    printf 'ARTI_RUNTIME_IMAGE=%s\n' "$ARTI_RUNTIME_IMAGE"
  } >"$PREFIX/images.env"

  install -m 0644 "$BUNDLE_DIR/containers/arti.Containerfile" "$PREFIX/arti.Containerfile"
  podman build --pull=always --tag "$ARTI_IMAGE" \
    --build-arg "RUST_IMAGE=$ARTI_RUST_IMAGE" \
    --build-arg "RUNTIME_IMAGE=$ARTI_RUNTIME_IMAGE" \
    --file "$PREFIX/arti.Containerfile" "$PREFIX"

  install -m 0644 "$BUNDLE_DIR/quadlet/crypto.network" "$QUADLET_DIR/crypto.network"
  install -m 0644 "$BUNDLE_DIR/quadlet/arti.container" "$QUADLET_DIR/arti.container"
  install_template "$BUNDLE_DIR/quadlet/bitcoin.container" "$QUADLET_DIR/bitcoin.container"
  install_template "$BUNDLE_DIR/quadlet/litecoin.container" "$QUADLET_DIR/litecoin.container"
  install_template "$BUNDLE_DIR/quadlet/monero.container" "$QUADLET_DIR/monero.container"

  systemctl daemon-reload
  systemctl enable --now arti.service bitcoin.service litecoin.service monero.service
  echo 'Installation complete.  Services may take time to bootstrap/sync.'
}

main "$@"
