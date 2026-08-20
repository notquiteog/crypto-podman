#!/usr/bin/env bash
# Idempotent Debian 13 installer for the Quadlets in this bundle.
set -Eeuo pipefail
umask 077

readonly PREFIX=/etc/crypto-daemons
readonly QUADLET_DIR=/etc/containers/systemd
readonly DATA_DIR=/srv/crypto-daemons
readonly BUNDLE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

containerfile_arg() {
  # Read an ARG default straight out of the Containerfile that consumes it.
  # Each version is then declared exactly once, next to the checksum it is
  # verified against, so an image tag cannot claim a version the image does
  # not actually contain.
  local file=$1 name=$2 value
  value=$(sed -n "s/^ARG ${name}=//p" "$file")
  value=${value%%$'\n'*}
  if [[ -z $value ]]; then
    printf 'Could not read ARG %s from %s\n' "$name" "$file" >&2
    exit 3
  fi
  printf '%s\n' "$value"
}

# Every daemon image is built locally from the upstream project's own signed
# release tarball.  The version and the checksum it is checked against both
# live in containers/*.Containerfile; bump them there and nowhere else.
ARTI_VERSION="$(containerfile_arg "$BUNDLE_DIR/containers/arti.Containerfile" ARTI_VERSION)"
BITCOIN_VERSION="$(containerfile_arg "$BUNDLE_DIR/containers/bitcoin.Containerfile" BITCOIN_VERSION)"
LITECOIN_VERSION="$(containerfile_arg "$BUNDLE_DIR/containers/litecoin.Containerfile" LITECOIN_VERSION)"
MONERO_VERSION="$(containerfile_arg "$BUNDLE_DIR/containers/monero.Containerfile" MONERO_VERSION)"
readonly ARTI_VERSION BITCOIN_VERSION LITECOIN_VERSION MONERO_VERSION
readonly ARTI_IMAGE="localhost/crypto-arti:${ARTI_VERSION}"
readonly BITCOIN_IMAGE="localhost/crypto-bitcoin:${BITCOIN_VERSION}"
readonly LITECOIN_IMAGE="localhost/crypto-litecoin:${LITECOIN_VERSION}"
readonly MONERO_IMAGE="localhost/crypto-monero:${MONERO_VERSION}"

# The two registry images this bundle still needs, pinned so a clean checkout
# installs with no arguments.  These are the docker.io/library/debian:trixie-slim
# and docker.io/library/rust:1-trixie multi-arch indexes as resolved on
# 2026-08-20; pinning the index digest keeps the per-architecture resolution.
# Both are Debian 13, matching the host this script targets and each other's
# glibc, which matters because arti is compiled in the Rust image and run in
# the Debian one.  Override either with the environment variable of the same
# name -- require_digest still refuses mutable tags.  README.md records how to
# re-verify these and how to refresh them.
readonly DEFAULT_BASE_IMAGE='docker.io/library/debian@sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258'
readonly DEFAULT_ARTI_RUST_IMAGE='docker.io/library/rust@sha256:b1b3c9c0d921d7fa0a6d1f9ec7e4eab87f8c8ec97644c3d791450f131dec813f'

usage() {
  cat <<USAGE
Usage: sudo ./setup.sh [OPTION]

Installs the Tor-routed Bitcoin, Litecoin and Monero Quadlets on Debian 13.
Run with no options for a default install; it is idempotent and safe to re-run.

Options:
  --print-details    Reprint operator connection details and exit.
  --print-recovery   Reprint wallet recovery material and exit.
  -h, --help         Show this message and exit.

Environment:
  BASE_IMAGE               Debian build/runtime base, as an immutable
                           name@sha256:... reference.  Mutable tags are
                           refused.  Default:
                             $DEFAULT_BASE_IMAGE
  ARTI_RUST_IMAGE          Rust image used to compile arti, same digest rule.
                           Default:
                             $DEFAULT_ARTI_RUST_IMAGE
  INSTALL_PODMAN_DESKTOP   yes/no; skips the interactive prompt.
  PODMAN_DESKTOP_USER      Desktop login to install Podman Desktop for,
                           required when that is enabled and you are root.

The daemons themselves are always built here from upstream signed releases
with checksums pinned in containers/*.Containerfile; no daemon image is
pulled from a registry.  See README.md.
USAGE
}

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

random_password() { openssl rand -hex 32; }

rpcauth_line() {
  local user=$1 password=$2 salt hash
  salt=$(openssl rand -hex 16)
  hash=$(printf '%s' "$password" | openssl dgst -sha256 -hmac "$salt" -binary | xxd -p -c 256)
  printf 'rpcauth=%s:%s$%s\n' "$user" "$salt" "$hash"
}

ensure_credential() {
  local name=$1
  local credential_file="$PREFIX/secrets/rpc-credentials.env"
  if ! grep -q "^${name}=" "$credential_file"; then
    printf '%s=%s\n' "$name" "$(random_password)" >>"$credential_file"
  fi
}

load_credentials() {
  # This file is created locally with 0600 permissions and contains only values
  # generated by this script. shellcheck disable=SC1090
  set -a
  . "$PREFIX/secrets/rpc-credentials.env"
  set +a
}

initialize_secrets() {
  local credential_file="$PREFIX/secrets/rpc-credentials.env"
  install -d -m 0700 "$PREFIX/secrets"
  touch "$credential_file"
  chmod 0600 "$credential_file"
  touch "$PREFIX/secrets/default-wallet-addresses.env"
  chmod 0600 "$PREFIX/secrets/default-wallet-addresses.env"
  ensure_credential BITCOIN_RPC_PASSWORD
  ensure_credential LITECOIN_RPC_PASSWORD
  ensure_credential MONERO_RPC_PASSWORD
  ensure_credential BITCOIN_WALLET_PASSPHRASE
  ensure_credential LITECOIN_WALLET_PASSPHRASE
  ensure_credential MONERO_WALLET_PASSWORD
  ensure_credential MONERO_WALLET_RPC_PASSWORD
  if ! grep -q '^BITCOIN_RPC_USER=' "$credential_file"; then printf 'BITCOIN_RPC_USER=bitcoinrpc\n' >>"$credential_file"; fi
  if ! grep -q '^LITECOIN_RPC_USER=' "$credential_file"; then printf 'LITECOIN_RPC_USER=litecoinrpc\n' >>"$credential_file"; fi
  if ! grep -q '^MONERO_RPC_USER=' "$credential_file"; then printf 'MONERO_RPC_USER=monerorpc\n' >>"$credential_file"; fi
  if ! grep -q '^MONERO_WALLET_RPC_USER=' "$credential_file"; then printf 'MONERO_WALLET_RPC_USER=monerowalletrpc\n' >>"$credential_file"; fi
  load_credentials

  [[ -f $PREFIX/secrets/bitcoin-rpcauth.conf ]] || rpcauth_line "$BITCOIN_RPC_USER" "$BITCOIN_RPC_PASSWORD" >"$PREFIX/secrets/bitcoin-rpcauth.conf"
  [[ -f $PREFIX/secrets/litecoin-rpcauth.conf ]] || rpcauth_line "$LITECOIN_RPC_USER" "$LITECOIN_RPC_PASSWORD" >"$PREFIX/secrets/litecoin-rpcauth.conf"
  [[ -f $PREFIX/secrets/monero-rpc.conf ]] || printf 'rpc-login=%s:%s\n' "$MONERO_RPC_USER" "$MONERO_RPC_PASSWORD" >"$PREFIX/secrets/monero-rpc.conf"
  printf '%s\n' "$MONERO_WALLET_PASSWORD" >"$PREFIX/secrets/monero-wallet-password"
  printf 'rpc-login=%s:%s\ndaemon-login=%s:%s\n' \
    "$MONERO_WALLET_RPC_USER" "$MONERO_WALLET_RPC_PASSWORD" \
    "$MONERO_RPC_USER" "$MONERO_RPC_PASSWORD" >"$PREFIX/secrets/monero-wallet-rpc.conf"
  chmod 0600 "$PREFIX/secrets"/*

  echo "Credentials and wallet passphrases are in $credential_file (mode 0600)."
  echo 'Copy them to an offline password manager before funding any wallet.'
}

wait_for_core_rpc() {
  # main restarts the daemons, so this waits for a real block-index reload
  # rather than answering instantly against an already-running node.  Ten
  # minutes matches the units' TimeoutStopSec and costs nothing when the
  # daemon comes up quickly.
  local container=$1 cli=$2 attempt
  for attempt in {1..300}; do
    if podman exec "$container" "$cli" -datadir=/data getblockchaininfo >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "$container RPC did not become ready within ten minutes." >&2
  return 1
}

ensure_core_wallet() {
  # Litecoin Core is Bitcoin Core 0.21-based and rejects descriptor wallets
  # outright, so the wallet type is per-chain rather than assumed.
  local container=$1 cli=$2 passphrase_var=$3 address_var=$4 descriptors=$5 wallet_list address
  wait_for_core_rpc "$container" "$cli"
  wallet_list=$(podman exec "$container" "$cli" -datadir=/data listwalletdir)
  if ! grep -Eq '"name"[[:space:]]*:[[:space:]]*"default"' <<<"$wallet_list"; then
    podman exec "$container" "$cli" -datadir=/data -named createwallet \
      wallet_name=default disable_private_keys=false blank=false \
      "passphrase=${!passphrase_var}" avoid_reuse=true "descriptors=${descriptors}" >/dev/null
  fi
  podman exec "$container" "$cli" -datadir=/data -rpcwallet=default getwalletinfo >/dev/null
  if ! grep -q "^${address_var}=" "$PREFIX/secrets/default-wallet-addresses.env"; then
    address=$(podman exec "$container" "$cli" -datadir=/data -rpcwallet=default getnewaddress default bech32)
    # Never record an empty address: it would mask a failed wallet setup and be
    # copied out as a receive address.
    if [[ -z $address ]]; then
      echo "$container did not return a receive address; wallet setup incomplete." >&2
      return 1
    fi
    printf '%s=%s\n' "$address_var" "$address" >>"$PREFIX/secrets/default-wallet-addresses.env"
  fi
}

ensure_monero_wallet() {
  local recovery_file="$PREFIX/secrets/monero-default-wallet-recovery.txt"
  if [[ ! -s $DATA_DIR/monero-wallet/default.keys ]]; then
    # Keep all CLI output (including the mnemonic) out of the terminal/journal.
    # The temporary CLI runs offline: it only creates the encrypted wallet.
    # The trailing `seed` command re-prompts for the password on stdin even when
    # --password-file created the wallet; without it the wallet is still created
    # but the recovery file records "Error: invalid password" instead of the
    # mnemonic, leaving a funded wallet with no seed backup.
    printf '%s\n' "$MONERO_WALLET_PASSWORD" | podman run --rm -i --network none --user 0 \
      --entrypoint monero-wallet-cli \
      -v "$DATA_DIR/monero-wallet:/wallets" \
      -v "$PREFIX/secrets:/secrets:ro" \
      "$MONERO_IMAGE" --generate-new-wallet /wallets/default \
      --password-file /secrets/monero-wallet-password \
      --mnemonic-language English --offline --create-address-file seed >"$recovery_file"
    chmod 0600 "$recovery_file"
    [[ -s $DATA_DIR/monero-wallet/default.keys ]] || {
      echo 'Monero wallet creation failed; inspect the protected recovery output.' >&2
      return 1
    }
    if grep -q 'Error:' "$recovery_file"; then
      echo 'Monero mnemonic was not captured; refusing to leave a wallet with no seed backup.' >&2
      echo "Remove $DATA_DIR/monero-wallet/default* and rerun after investigating." >&2
      return 1
    fi
  fi
  if ! grep -q '^MONERO_DEFAULT_ADDRESS=' "$PREFIX/secrets/default-wallet-addresses.env"; then
    printf 'MONERO_DEFAULT_ADDRESS=%s\n' "$(tr -d '\r\n' <"$DATA_DIR/monero-wallet/default.address.txt")" >>"$PREFIX/secrets/default-wallet-addresses.env"
  fi
}

autoload_wallet() {
  # Only add -wallet once the wallet exists; naming a missing wallet is a
  # startup error, and the daemon has to come up before it can be created.
  local name=$1 conf=$2
  if [[ -e $DATA_DIR/$name/wallets/default ]] && ! grep -qx 'wallet=default' "$conf"; then
    printf 'wallet=default\n' >>"$conf"
  fi
}

build_daemon_image() {
  # The Containerfile downloads the upstream release and checks it against a
  # checksum pinned in the file itself, so a tampered download fails the build.
  local chain=$1 tag=$2
  install -m 0644 "$BUNDLE_DIR/containers/$chain.Containerfile" "$PREFIX/$chain.Containerfile"
  podman build --pull=always --tag "$tag" \
    --build-arg "FETCH_IMAGE=$BASE_IMAGE" \
    --build-arg "RUNTIME_IMAGE=$BASE_IMAGE" \
    --file "$PREFIX/$chain.Containerfile" "$PREFIX"
}

# ── Wallet recovery material ─────────────────────────────────────
#
# Only Monero has a mnemonic; Bitcoin Core and Litecoin Core have never used
# seed phrases.  The equivalent secret is the descriptor set (Bitcoin) or the
# HD master key inside a wallet dump (Litecoin).  Both exports require the
# wallet to be unlocked, so this runs right after creation and re-locks.

capture_bitcoin_descriptors() {
  local out="$PREFIX/secrets/bitcoin-wallet-descriptors.json"
  [[ -s $out ]] && return 0
  podman exec bitcoin bitcoin-cli -datadir=/data -rpcwallet=default \
    walletpassphrase "$BITCOIN_WALLET_PASSPHRASE" 60 >/dev/null
  podman exec bitcoin bitcoin-cli -datadir=/data -rpcwallet=default \
    listdescriptors true >"$out"
  podman exec bitcoin bitcoin-cli -datadir=/data -rpcwallet=default walletlock >/dev/null
  chmod 0600 "$out"
}

capture_litecoin_dump() {
  local out="$PREFIX/secrets/litecoin-wallet-dump.txt"
  [[ -s $out ]] && return 0
  podman exec litecoin litecoin-cli -datadir=/data -rpcwallet=default \
    walletpassphrase "$LITECOIN_WALLET_PASSPHRASE" 60 >/dev/null
  podman exec litecoin litecoin-cli -datadir=/data -rpcwallet=default \
    dumpwallet /data/wallet-dump.txt >/dev/null
  podman exec litecoin litecoin-cli -datadir=/data -rpcwallet=default walletlock >/dev/null
  # dumpwallet writes cleartext keys into the chain data volume; move it into
  # the protected secrets directory rather than leaving it there.
  mv "$DATA_DIR/litecoin/wallet-dump.txt" "$out"
  chmod 0600 "$out"
}

# Last 25 all-lowercase words in the recovery output are the Monero seed.
monero_mnemonic() {
  local f="$PREFIX/secrets/monero-default-wallet-recovery.txt"
  [[ -s $f ]] || { printf 'unavailable'; return 0; }
  awk '/^[a-z]+( [a-z]+)*$/ { for (i = 1; i <= NF; i++) w[++n] = $i }
       END { if (n >= 25) { for (i = n - 24; i <= n; i++) printf "%s%s", w[i], (i < n ? " " : "") }
             else printf "unavailable" }' "$f"
}

print_recovery_summary() {
  local out="$PREFIX/secrets/wallet-recovery.txt"
  local desc_file="$PREFIX/secrets/bitcoin-wallet-descriptors.json"
  local dump_file="$PREFIX/secrets/litecoin-wallet-dump.txt"
  umask 077
  {
    cat <<'HEADER'
================================================================
 WALLET RECOVERY MATERIAL — SPEND KEYS.  BACK UP OFFLINE, THEN
 REMOVE THIS FILE FROM THE SERVER.
================================================================
Anyone holding what follows can spend every coin in these wallets, with no
password needed.  Reprint with:  setup.sh --print-recovery

---- Monero — 25-word mnemonic ---------------------------------
HEADER
    printf '  %s\n\n' "$(monero_mnemonic)"

    cat <<'BTCHDR'
---- Bitcoin — descriptors (Bitcoin Core has no seed phrase) ----
  Import these into a descriptor-capable wallet to restore.  Each carries the
  master private key; the derivation paths and checksums matter, so keep them
  verbatim.
BTCHDR
    if [[ -s $desc_file ]]; then
      grep -oE '"desc": *"[^"]+"' "$desc_file" | sed -E 's/"desc": *"//; s/"$//' | sed 's/^/  /'
    else
      echo '  unavailable'
    fi
    printf '\n'

    cat <<'LTCHDR'
---- Litecoin — HD master key (no seed phrase either) ----------
LTCHDR
    if [[ -s $dump_file ]]; then
      grep -E '^# extended private masterkey:' "$dump_file" | sed 's/^# /  /'
      printf '  Full dump (every private key, needed for any non-HD keys):\n    %s\n' "$dump_file"
    else
      echo '  unavailable'
    fi
  } >"$out"
  chmod 0600 "$out"
  cat "$out"
}

onion_address() {
  # The identity exists as soon as the service launches, but arti needs a moment
  # after start before the command answers.
  local nickname=$1 attempt address
  for attempt in {1..60}; do
    address=$(podman exec crypto-arti arti --config /etc/arti/arti.toml hss \
      --nickname "$nickname" onion-address 2>/dev/null | tr -d '\r\n')
    if [[ -n $address ]]; then
      printf '%s' "$address"
      return 0
    fi
    sleep 2
  done
  printf 'unavailable — check: systemctl status arti'
}

print_operator_summary() {
  local out="$PREFIX/secrets/connection-details.txt"
  local btc_onion ltc_onion xmr_onion wallet_onion
  btc_onion=$(onion_address bitcoin-rpc)
  ltc_onion=$(onion_address litecoin-rpc)
  xmr_onion=$(onion_address monero-rpc)
  wallet_onion=$(onion_address monero-wallet-rpc)
  load_credentials
  # shellcheck disable=SC1091
  . "$PREFIX/secrets/default-wallet-addresses.env" 2>/dev/null || true

  umask 077
  cat >"$out" <<SUMMARY
================================================================
 CONNECTION DETAILS — CONTAINS SECRETS, TREAT AS SENSITIVE
================================================================
Reprint at any time with:  sudo $0 --print-details

Every endpoint below is reachable only through Tor.  The client must send
traffic via a SOCKS5 proxy AND let the proxy resolve the name (socks5h://,
or curl --socks5-hostname): .onion has no DNS.

---- Bitcoin Core (node RPC + wallet) --------------------------
  Onion            : ${btc_onion}:8332
  Auth             : HTTP Basic
  Username         : ${BITCOIN_RPC_USER}
  Password         : ${BITCOIN_RPC_PASSWORD}
  Wallet name      : default        (descriptor wallet, encrypted)
  Wallet endpoint  : /wallet/default
  Wallet passphrase: ${BITCOIN_WALLET_PASSPHRASE}
  Receive address  : ${BITCOIN_DEFAULT_ADDRESS:-not yet generated}

---- Litecoin Core (node RPC + wallet) -------------------------
  Onion            : ${ltc_onion}:9332
  Auth             : HTTP Basic
  Username         : ${LITECOIN_RPC_USER}
  Password         : ${LITECOIN_RPC_PASSWORD}
  Wallet name      : default        (legacy wallet, encrypted)
  Wallet endpoint  : /wallet/default
  Wallet passphrase: ${LITECOIN_WALLET_PASSPHRASE}
  Receive address  : ${LITECOIN_DEFAULT_ADDRESS:-not yet generated}

---- Monero daemon (restricted node RPC) -----------------------
  Onion            : ${xmr_onion}:18089
  Auth             : HTTP Digest  (NOT Basic)
  Username         : ${MONERO_RPC_USER}
  Password         : ${MONERO_RPC_PASSWORD}
  Endpoint         : /json_rpc

---- Monero wallet RPC (spend-capable) -------------------------
  Onion            : ${wallet_onion}:18088
  Auth             : HTTP Digest  (NOT Basic)
  Username         : ${MONERO_WALLET_RPC_USER}
  Password         : ${MONERO_WALLET_RPC_PASSWORD}
  Endpoint         : /json_rpc
  Wallet file      : default
  Wallet password  : ${MONERO_WALLET_PASSWORD}
  Receive address  : ${MONERO_DEFAULT_ADDRESS:-not yet generated}

---- Notes for whoever writes the client -----------------------
* Monero uses HTTP **digest** auth.  Sending Basic auth with correct
  credentials still returns 401, which looks like a wrong password.
* Monero binds the digest nonce to the TCP connection, so the client must
  keep the connection alive between the 401 challenge and the authenticated
  retry.  A new socket per request fails every time.
* Bitcoin and Litecoin wallets are encrypted and start LOCKED.  Receiving
  and address generation work while locked; sending needs
  walletpassphrase first, and the daemon caps that timeout at 100000000
  seconds.  The unlock is in memory only: every daemon restart re-locks it.
* Litecoin's wallet is legacy and cannot refill its address keypool while
  locked.  After roughly 1000 addresses getnewaddress fails with "Keypool
  ran out" until the wallet is unlocked once.
* The Monero wallet RPC has no lock: while running it can always spend.
* Treat every onion address as a secret.  There is no authorization at the
  Tor layer, so the address plus these credentials is the entire gate.

  Monero recovery seed (NOT needed to operate; back it up offline):
    $PREFIX/secrets/monero-default-wallet-recovery.txt
SUMMARY
  chmod 0600 "$out"
  cat "$out"
}

install_template() {
  local input=$1 output=$2
  sed \
    -e "s|@@ARTI_IMAGE@@|${ARTI_IMAGE}|g" \
    -e "s|@@BITCOIN_IMAGE@@|${BITCOIN_IMAGE}|g" \
    -e "s|@@LITECOIN_IMAGE@@|${LITECOIN_IMAGE}|g" \
    -e "s|@@MONERO_IMAGE@@|${MONERO_IMAGE}|g" \
    "$input" >"$output"
}

main() {
  require_root
  # Only the two build base images come from a registry now, and both must still
  # be immutable: they are the root of trust for every binary built below.
  # Unset means "use the reviewed pin above", not "pick something mutable".
  BASE_IMAGE=${BASE_IMAGE:-$DEFAULT_BASE_IMAGE}
  ARTI_RUST_IMAGE=${ARTI_RUST_IMAGE:-$DEFAULT_ARTI_RUST_IMAGE}
  require_digest BASE_IMAGE "$BASE_IMAGE"
  require_digest ARTI_RUST_IMAGE "$ARTI_RUST_IMAGE"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends podman uidmap slirp4netns fuse-overlayfs \
    ca-certificates openssl xxd
  maybe_install_podman_desktop

  install -d -m 0755 "$PREFIX" "$QUADLET_DIR" "$DATA_DIR" \
    "$DATA_DIR/arti" "$DATA_DIR/bitcoin" "$DATA_DIR/litecoin" "$DATA_DIR/monero"
  # -walletdir must already exist or the daemon refuses to start.
  install -d -m 0700 "$DATA_DIR/bitcoin/wallets" "$DATA_DIR/litecoin/wallets"
  install -d -m 0700 "$DATA_DIR/monero-wallet"
  initialize_secrets

  install -m 0644 "$BUNDLE_DIR/config/arti.toml" "$PREFIX/arti.toml"
  install -m 0644 "$BUNDLE_DIR/config/bitcoin.conf" "$PREFIX/bitcoin.conf"
  install -m 0644 "$BUNDLE_DIR/config/litecoin.conf" "$PREFIX/litecoin.conf"
  # monerod has no includeconf equivalent; build its config without printing its secret.
  install -m 0600 "$BUNDLE_DIR/config/monero.conf" "$PREFIX/monero.conf"
  sed -n '1,$p' "$PREFIX/secrets/monero-rpc.conf" >>"$PREFIX/monero.conf"
  install -m 0600 "$BUNDLE_DIR/config/monero-wallet-rpc.conf" "$PREFIX/monero-wallet-rpc.conf"
  sed -n '1,$p' "$PREFIX/secrets/monero-wallet-rpc.conf" >>"$PREFIX/monero-wallet-rpc.conf"

  install -m 0600 "$PREFIX/secrets/bitcoin-rpcauth.conf" "$PREFIX/bitcoin-rpcauth.conf"
  install -m 0600 "$PREFIX/secrets/litecoin-rpcauth.conf" "$PREFIX/litecoin-rpcauth.conf"
  {
    printf 'BITCOIN_IMAGE=%s\n' "$BITCOIN_IMAGE"
    printf 'LITECOIN_IMAGE=%s\n' "$LITECOIN_IMAGE"
    printf 'MONERO_IMAGE=%s\n' "$MONERO_IMAGE"
    printf 'ARTI_IMAGE=%s\n' "$ARTI_IMAGE"
    printf 'BASE_IMAGE=%s\n' "$BASE_IMAGE"
    printf 'ARTI_RUST_IMAGE=%s\n' "$ARTI_RUST_IMAGE"
  } >"$PREFIX/images.env"

  install -m 0644 "$BUNDLE_DIR/containers/arti.Containerfile" "$PREFIX/arti.Containerfile"
  podman build --pull=always --tag "$ARTI_IMAGE" \
    --build-arg "RUST_IMAGE=$ARTI_RUST_IMAGE" \
    --build-arg "RUNTIME_IMAGE=$BASE_IMAGE" \
    --file "$PREFIX/arti.Containerfile" "$PREFIX"
  build_daemon_image bitcoin "$BITCOIN_IMAGE"
  build_daemon_image litecoin "$LITECOIN_IMAGE"
  build_daemon_image monero "$MONERO_IMAGE"

  install -m 0644 "$BUNDLE_DIR/quadlet/crypto.network" "$QUADLET_DIR/crypto.network"
  install_template "$BUNDLE_DIR/quadlet/arti.container" "$QUADLET_DIR/arti.container"
  install_template "$BUNDLE_DIR/quadlet/bitcoin.container" "$QUADLET_DIR/bitcoin.container"
  install_template "$BUNDLE_DIR/quadlet/litecoin.container" "$QUADLET_DIR/litecoin.container"
  install_template "$BUNDLE_DIR/quadlet/monero.container" "$QUADLET_DIR/monero.container"
  install_template "$BUNDLE_DIR/quadlet/monero-wallet-rpc.container" "$QUADLET_DIR/monero-wallet-rpc.container"

  systemctl daemon-reload
  # Quadlet-generated units cannot be enabled; the generator applies each unit's
  # [Install] section itself, so starting them is all that is required.
  # restart rather than start: on a re-run the units are already up, and start
  # would leave them on the previous image after a version or base-image bump.
  # The chain units allow 10min TimeoutStopSec, so this is a clean shutdown.
  systemctl restart arti.service bitcoin.service litecoin.service monero.service
  ensure_core_wallet bitcoin bitcoin-cli BITCOIN_WALLET_PASSPHRASE BITCOIN_DEFAULT_ADDRESS true
  ensure_core_wallet litecoin litecoin-cli LITECOIN_WALLET_PASSPHRASE LITECOIN_DEFAULT_ADDRESS false
  # Only now can these be written: the wallet has to exist before naming it in
  # the config, and without the line the daemons come back from a reboot with no
  # wallet loaded.
  autoload_wallet bitcoin "$PREFIX/bitcoin.conf"
  autoload_wallet litecoin "$PREFIX/litecoin.conf"
  capture_bitcoin_descriptors
  capture_litecoin_dump
  ensure_monero_wallet
  systemctl restart monero-wallet-rpc.service
  echo 'Installation complete.  Services may take time to bootstrap/sync.'
  print_operator_summary
  print_recovery_summary
}

case ${1:-} in
  -h|--help)
    usage
    exit 0
    ;;
  --print-details)
    require_root
    print_operator_summary
    exit 0
    ;;
  --print-recovery)
    require_root
    print_recovery_summary
    exit 0
    ;;
  '')
    main
    ;;
  *)
    printf 'Unknown option: %s\n\n' "$1" >&2
    usage >&2
    exit 64
    ;;
esac
