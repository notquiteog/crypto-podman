#!/usr/bin/env bash
# Idempotent Debian 13 first-install for the Quadlets in this bundle.
#
# This is the install-time entry point: it prepares the host, generates
# credentials, creates the wallets, and prints the recovery material once so it
# can be backed up.  Because it prints spend keys it is meant to be run by a
# human at a terminal.  Routine maintenance -- new daemon releases, base-image
# refreshes -- is update.sh, which never prints that material and is therefore
# safe to run unattended.
set -Eeuo pipefail
umask 077

# shellcheck source=lib.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<USAGE
Usage: sudo ./setup.sh [OPTION]

First-time install of the Tor-routed Bitcoin, Litecoin and Monero Quadlets on
Debian 13.  Idempotent and safe to re-run, but it reprints wallet recovery
material every time; use ./update.sh for routine updates.

Options:
  --print-details    Reprint operator connection details and exit.
  --print-recovery   Reprint wallet recovery material and exit.
  --shred-recovery   Destroy the server-side copies of the spend keys, once
                     they are backed up offline.  Irreversible.
  --add-rpc-client <service> <name>
                     Authorize one client for restricted discovery on an onion
                     service, and print its private key.  Services are
                     bitcoin-rpc, litecoin-rpc, monero-rpc, monero-wallet-rpc.
                     See the restricted-discovery notes in config/arti.toml.
  -h, --help         Show this message and exit.

Environment:
  BASE_IMAGE               Debian build/runtime base, as an immutable
                           name@sha256:... reference.  Mutable tags are
                           refused.  Default:
                             $DEFAULT_BASE_IMAGE
  ARTI_RUST_IMAGE          Rust image used to compile arti, same digest rule.
                           Default:
                             $DEFAULT_ARTI_RUST_IMAGE
  MIN_FREE_GIB             Free space required on $DATA_DIR before installing.
                           Default 150, matching the README's budget.
  INSTALL_PODMAN_DESKTOP   yes/no; skips the interactive prompt.
  PODMAN_DESKTOP_USER      Desktop login to install Podman Desktop for,
                           required when that is enabled and you are root.

The daemons themselves are always built here from upstream signed releases
with checksums pinned in containers/*.Containerfile; no daemon image is
pulled from a registry.  See README.md.
USAGE
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

warn_podman_version() {
  # A support floor rather than a technical one: the Quadlet syntax used here
  # also converts on podman 4.9, so refusing to run would be overreach, but this
  # bundle is only tested against the 5.4 that Debian 13 ships.
  local version major
  version=$(podman --version 2>/dev/null | awk '{print $3}') || version=''
  major=${version%%.*}
  if [[ ! $major =~ ^[0-9]+$ ]] || (( major < 5 )); then
    printf 'Found podman %s; this bundle is tested against 5.0 and later.\n' \
      "${version:-none}" >&2
  fi
}

require_free_space_on() {
  # Refuse rather than skip when df cannot be read: a preflight that fails open
  # is worse than none, because it is quiet about it.
  local path=$1 need=$2 what=$3 have
  have=$(df -BG --output=avail "$path" 2>/dev/null | tail -1 | tr -dc '0-9') || have=''
  if [[ -z $have ]]; then
    printf 'Could not read free space on %s (%s); refusing to continue.\n' \
      "$path" "$what" >&2
    exit 1
  fi
  if (( have < need )); then
    printf 'Only %s GiB free on %s (%s); %s GiB is required.\n' \
      "$have" "$path" "$what" "$need" >&2
    printf 'Free space or move it to a larger filesystem; MIN_FREE_GIB lowers\n' >&2
    printf 'the chain-data figure if you mean to run a smaller deployment.\n' >&2
    exit 1
  fi
}

require_free_space() {
  # As configured the three chains want roughly 95 GB and grow from there.  A
  # disk that fills during initial sync is the one failure here that can leave
  # Monero's LMDB damaged, so check before spending an hour building images.
  # The images are built into podman's store, which is regularly a different
  # filesystem from the chain data, so both are checked.
  local need=${MIN_FREE_GIB:-150} store
  if [[ ! $need =~ ^[0-9]+$ ]]; then
    printf 'MIN_FREE_GIB must be a whole number of GiB; got %q\n' "$need" >&2
    exit 1
  fi
  store=$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null) || store=''
  [[ -n $store && -d $store ]] || store=/var/lib
  require_free_space_on "$DATA_DIR" "$need" 'chain data'
  require_free_space_on "$store" 20 'image builds'
}

enable_time_sync() {
  # The daemon units order themselves After=time-sync.target, but that target is
  # only ever reached if something pulls it in: systemd ships
  # systemd-time-wait-sync for exactly this and leaves it disabled.  Without it
  # the ordering is a no-op and the nodes can start against an unsynchronised
  # clock, which Monero and both Core daemons all handle badly.
  if ! systemctl cat systemd-time-wait-sync.service >/dev/null 2>&1; then
    echo 'systemd-time-wait-sync is not available; make sure the host clock is' >&2
    echo 'synchronised by whatever means you already use.' >&2
    return 0
  fi
  systemctl enable --now systemd-time-wait-sync.service ||
    echo 'Could not enable systemd-time-wait-sync; clock ordering is advisory only.' >&2
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

ensure_core_wallet() {
  # Litecoin Core is Bitcoin Core 0.21-based and rejects descriptor wallets
  # outright, so the wallet type is per-chain rather than assumed.
  local container=$1 cli=$2 passphrase_var=$3 address_var=$4 descriptors=$5 wallet_list address
  wait_for_core_rpc "$container" "$cli"
  wallet_list=$(podman exec "$container" "$cli" -datadir=/data listwalletdir)
  if ! grep -Eq '"name"[[:space:]]*:[[:space:]]*"default"' <<<"$wallet_list"; then
    # -stdin reads the named arguments from stdin rather than argv, so the
    # passphrase never appears in the host process table.
    printf '%s\n' wallet_name=default disable_private_keys=false blank=false \
      "passphrase=${!passphrase_var}" avoid_reuse=true "descriptors=${descriptors}" |
      podman exec -i "$container" "$cli" -datadir=/data -named -stdin createwallet >/dev/null
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

capture_bitcoin_descriptors() {
  local out="$PREFIX/secrets/bitcoin-wallet-descriptors.json"
  [[ -s $out ]] && return 0
  # -stdinwalletpassphrase, for the same reason as createwallet above.
  printf '%s\n' "$BITCOIN_WALLET_PASSPHRASE" |
    podman exec -i bitcoin bitcoin-cli -datadir=/data -rpcwallet=default \
      -stdinwalletpassphrase walletpassphrase 60 >/dev/null
  podman exec bitcoin bitcoin-cli -datadir=/data -rpcwallet=default \
    listdescriptors true >"$out"
  podman exec bitcoin bitcoin-cli -datadir=/data -rpcwallet=default walletlock >/dev/null
  chmod 0600 "$out"
}

capture_litecoin_dump() {
  local out="$PREFIX/secrets/litecoin-wallet-dump.txt"
  [[ -s $out ]] && return 0
  printf '%s\n' "$LITECOIN_WALLET_PASSPHRASE" |
    podman exec -i litecoin litecoin-cli -datadir=/data -rpcwallet=default \
      -stdinwalletpassphrase walletpassphrase 60 >/dev/null
  podman exec litecoin litecoin-cli -datadir=/data -rpcwallet=default \
    dumpwallet /data/wallet-dump.txt >/dev/null
  podman exec litecoin litecoin-cli -datadir=/data -rpcwallet=default walletlock >/dev/null
  # dumpwallet writes cleartext keys into the chain data volume; move it into
  # the protected secrets directory rather than leaving it there.
  mv "$DATA_DIR/litecoin/wallet-dump.txt" "$out"
  chmod 0600 "$out"
}

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

recovery_files() {
  printf '%s\n' \
    "$PREFIX/secrets/wallet-recovery.txt" \
    "$PREFIX/secrets/bitcoin-wallet-descriptors.json" \
    "$PREFIX/secrets/litecoin-wallet-dump.txt" \
    "$PREFIX/secrets/monero-default-wallet-recovery.txt"
}

shred_recovery() {
  # The README has always told the operator to delete these by hand once they
  # are backed up.  Until that happens the wallet encryption is decorative: the
  # cleartext master keys sit in the same directory as the wallets they
  # protect, so anyone who can read the disk can spend without a passphrase.
  local -a present=()
  local f
  while IFS= read -r f; do [[ -e $f ]] && present+=("$f"); done < <(recovery_files)
  if (( ${#present[@]} == 0 )); then
    echo 'No server-side recovery material found; nothing to shred.'
    return 0
  fi
  cat <<WARN
About to destroy the server-side copies of the spend keys:

$(printf '  %s\n' "${present[@]}")
This cannot be undone.  Do not continue unless the material is already backed
up offline and you have verified that backup.

Two things to know first:

  * The Monero mnemonic exists nowhere else on this host.  Once it is gone it
    can only be recovered from the wallet itself, using the wallet password in
    rpc-credentials.env with monero-wallet-cli.
  * The Bitcoin and Litecoin exports are derived from their wallets, so a later
    full run of setup.sh will simply recreate them.  Shred again after any such
    run, or the files come back.

Neither the RPC credentials nor the wallet passphrases are touched; the daemons
need those to run.  Note also that shred cannot promise much on a copy-on-write
or journalling filesystem, or on flash with wear levelling -- treat this as
closing the obvious hole, not as forensic erasure.

WARN
  local answer
  read -r -p 'Type SHRED to continue: ' answer
  if [[ $answer != SHRED ]]; then
    echo 'Aborted; nothing was removed.'
    return 1
  fi
  local rc=0
  for f in "${present[@]}"; do
    if shred -u -z -- "$f"; then
      printf '  shredded %s\n' "$f"
    else
      printf '  FAILED to shred %s -- it is still on disk\n' "$f" >&2
      rc=1
    fi
  done
  if (( rc )); then
    echo 'Some files could not be destroyed; the spend keys they hold are still' >&2
    echo 'on this server.  Investigate before assuming they are gone.' >&2
    return 1
  fi
  echo 'Done.  setup.sh --print-recovery will now report the material as unavailable.'
}

add_rpc_client() {
  # Generates one x25519 keypair for Arti's restricted discovery: the public
  # half is authorized here, the private half is printed once for the client.
  # This only takes effect once the service's restricted_discovery block is
  # uncommented in arti.toml -- see the notes there, and rebuild Arti first.
  local service=${1:-} name=${2:-} dir tmp pub priv
  case $service in
    bitcoin-rpc|litecoin-rpc|monero-rpc|monero-wallet-rpc) ;;
    *)
      echo 'Service must be one of: bitcoin-rpc litecoin-rpc monero-rpc monero-wallet-rpc' >&2
      return 64
      ;;
  esac
  # The name becomes a filename in a directory Arti reads; keep it boring.
  if [[ ! $name =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
    echo 'Client name must be alphanumeric, with - and _ allowed after the first character.' >&2
    return 64
  fi
  dir="$DATA_DIR/arti/authorized_clients/$service"
  install -d -m 0700 "$dir"
  if [[ -e $dir/$name.auth ]]; then
    echo "A client called $name is already authorized for $service." >&2
    echo "Remove $dir/$name.auth first if you mean to reissue its key." >&2
    return 1
  fi
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf -- '$tmp'" RETURN
  openssl genpkey -algorithm x25519 -out "$tmp/key.pem"
  # Both DER encodings put the raw 32-byte key last, which is what Tor's
  # base32 client-auth format wants.
  pub=$(openssl pkey -in "$tmp/key.pem" -pubout -outform DER | tail -c 32 | base32 | tr -d '=\n')
  priv=$(openssl pkey -in "$tmp/key.pem" -outform DER | tail -c 32 | base32 | tr -d '=\n')
  printf 'descriptor:x25519:%s\n' "$pub" >"$dir/$name.auth"
  chmod 0600 "$dir/$name.auth"
  cat <<CLIENT

Authorized '$name' for $service.
  Public key recorded in: $dir/$name.auth

Give the client this private key.  It is printed once and is not stored here:

  descriptor:x25519:$priv

For a C-tor client, that line goes in ClientOnionAuthDir as
<onion-address-without-.onion>:descriptor:x25519:$priv

Restricted discovery is not active until you uncomment this service's
restricted_discovery block in /etc/crypto-daemons/arti.toml and restart Arti.
Confirm you can still reach the service afterwards, from a client holding this
key, before doing the same to the others.
CLIENT
}

onion_address() {
  # The identity exists as soon as the service launches, but arti needs a moment
  # after start before the command answers.
  local nickname=$1 address
  for _ in {1..60}; do
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

install_configs() {
  # arti.toml is the one config an operator is expected to edit, to turn on
  # restricted discovery.  Reinstalling it would silently revert that gate in
  # front of a spend-capable wallet, so install it once and report drift after.
  if [[ ! -e $PREFIX/arti.toml ]]; then
    install -m 0644 "$BUNDLE_DIR/config/arti.toml" "$PREFIX/arti.toml"
  elif ! cmp -s "$BUNDLE_DIR/config/arti.toml" "$PREFIX/arti.toml"; then
    # Show the difference rather than just announcing one: an operator who has
    # enabled restricted discovery needs to merge bundle changes by hand, and
    # cannot do that from a warning that does not say what changed.
    echo "Keeping the existing $PREFIX/arti.toml, which differs from this" >&2
    echo 'bundle. Merge anything you want from the diff below by hand:' >&2
    diff -u "$PREFIX/arti.toml" "$BUNDLE_DIR/config/arti.toml" >&2 || true
  fi
  install -m 0644 "$BUNDLE_DIR/config/bitcoin.conf" "$PREFIX/bitcoin.conf"
  install -m 0644 "$BUNDLE_DIR/config/litecoin.conf" "$PREFIX/litecoin.conf"
  # monerod has no includeconf equivalent; build its config without printing its secret.
  install -m 0600 "$BUNDLE_DIR/config/monero.conf" "$PREFIX/monero.conf"
  sed -n '1,$p' "$PREFIX/secrets/monero-rpc.conf" >>"$PREFIX/monero.conf"
  install -m 0600 "$BUNDLE_DIR/config/monero-wallet-rpc.conf" "$PREFIX/monero-wallet-rpc.conf"
  sed -n '1,$p' "$PREFIX/secrets/monero-wallet-rpc.conf" >>"$PREFIX/monero-wallet-rpc.conf"
  install -m 0600 "$PREFIX/secrets/bitcoin-rpcauth.conf" "$PREFIX/bitcoin-rpcauth.conf"
  install -m 0600 "$PREFIX/secrets/litecoin-rpcauth.conf" "$PREFIX/litecoin-rpcauth.conf"
}

main() {
  require_root
  # Only the two build base images come from a registry, and both must still be
  # immutable: they are the root of trust for every binary built below.
  resolve_base_images

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  # gnupg and jq are for update.sh: it verifies upstream release signatures and
  # parses the GitHub, crates.io and registry APIs.  Without jq every component
  # check fails, so it is a hard dependency of the bundle, not an extra.
  apt-get install -y --no-install-recommends podman uidmap slirp4netns fuse-overlayfs \
    ca-certificates openssl xxd gnupg curl jq
  warn_podman_version
  maybe_install_podman_desktop
  enable_time_sync

  install -d -m 0755 "$PREFIX" "$QUADLET_DIR" "$DATA_DIR" "$DATA_DIR/arti"
  # 0700, not 0755: capture_litecoin_dump has litecoind write a cleartext copy
  # of every private key into its data directory before moving it into secrets,
  # and the daemon writes under the container's umask, not this script's.  A
  # world-readable data directory would expose it for that window.
  install -d -m 0700 "$DATA_DIR/bitcoin" "$DATA_DIR/litecoin" "$DATA_DIR/monero"
  # -walletdir must already exist or the daemon refuses to start.
  install -d -m 0700 "$DATA_DIR/bitcoin/wallets" "$DATA_DIR/litecoin/wallets"
  install -d -m 0700 "$DATA_DIR/monero-wallet"
  # Empty unless --add-rpc-client is used; Arti only reads these when a
  # service's restricted_discovery block is uncommented in arti.toml.
  install -d -m 0700 "$DATA_DIR/arti/authorized_clients"
  # Created here rather than on first use so the update timer's unit can name it
  # in ReadWritePaths= under ProtectSystem=strict.
  install -d -m 0700 "$KEYRING_DIR"
  require_free_space
  initialize_secrets
  install_configs
  # install_configs reinstalls both Core configs from the bundle, dropping the
  # wallet=default line a previous run appended.  Put it back before the restart
  # below, or a re-run brings the daemons up with no wallet loaded and the
  # -rpcwallet=default probe in ensure_core_wallet aborts the install.  The
  # existence guard inside makes this a no-op on a first install.
  autoload_wallet bitcoin "$PREFIX/bitcoin.conf"
  autoload_wallet litecoin "$PREFIX/litecoin.conf"
  write_images_env

  build_all_images
  install_quadlets
  migrate_internal_network
  restart_chain_services

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
  prune_old_images
  # Last, not with the other installs: Persistent=true and no stamp file means
  # the timer fires its first check the moment it is enabled, and that is worth
  # far less noise once the install has actually finished.
  install_update_timer
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
  --shred-recovery)
    require_root
    shred_recovery
    exit $?
    ;;
  --add-rpc-client)
    require_root
    shift
    add_rpc_client "${1:-}" "${2:-}"
    exit $?
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
