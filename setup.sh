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
  --add-rpc-client <service> <name> [--public-key <key>]
                     Authorize one client for restricted discovery on an onion
                     service.  Services are bitcoin-rpc, litecoin-rpc,
                     monero-rpc, monero-wallet-rpc.  Without --public-key a
                     keypair is made here and its private half printed once.
                     With it, the client's own public key is recorded instead
                     -- the line an Arti client such as CryptoStore's prints,
                     descriptor:x25519:<52 base32 characters> -- and nothing
                     secret is made or shown.  If restricted discovery is
                     already on for that service, Arti is restarted so it
                     reads the key.  See config/arti.toml.
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
  UPDATE_CHECK_ROUTE       tor or direct, for the daily update check.  tor
                           (the default on a first install) sends every
                           request through Arti; direct sends them from this
                           host's own address.  Unset on a re-run keeps what
                           the host already has.
  RESTART_ARTI             yes/no, for --add-rpc-client.  Default yes: when
                           restricted discovery is on for the service, restart
                           Arti so the new key takes effect.  no leaves that
                           to your next restart of Arti.

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
      desktop_home=$(getent passwd "$desktop_user" | cut -d: -f6) || desktop_home=''
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
  local path=$1 need=$2 what=$3 note=${4:-} have
  have=$(df -BG --output=avail "$path" 2>/dev/null | tail -1 | tr -dc '0-9') || have=''
  if [[ -z $have ]]; then
    printf 'Could not read free space on %s (%s); refusing to continue.\n' \
      "$path" "$what" >&2
    exit 1
  fi
  if (( have < need )); then
    printf 'Only %s GiB free on %s (%s); %s GiB is required%s.\n' \
      "$have" "$path" "$what" "$need" "$note" >&2
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
  local budget=${MIN_FREE_GIB:-150} need store held floor note=''
  if [[ ! $budget =~ ^[0-9]+$ ]]; then
    printf 'MIN_FREE_GIB must be a whole number of GiB; got %q\n' "$budget" >&2
    exit 1
  fi
  need=$budget
  # The budget is for the whole deployment, and on a re-run much of it is
  # already on disk as chain data.  Asking for all of it again as FREE space
  # refused a re-run on exactly the host that had been sized correctly -- once
  # the chains had synced, 150 GiB was no longer free, and could not be.  So
  # what is already held counts toward the budget, down to the 25 GiB that
  # update.sh --check reports as LOW (or MIN_FREE_GIB, if that is lower).
  held=$(du -s --block-size=1G "$DATA_DIR" 2>/dev/null | cut -f1) || held=0
  [[ $held =~ ^[0-9]+$ ]] || held=0
  if (( held > 1 )); then
    floor=$(( budget < 25 ? budget : 25 ))
    need=$(( budget - held ))
    (( need >= floor )) || need=$floor
    note=" (the ${budget} GiB budget, less ${held} GiB of chain data already here)"
  fi
  store=$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null) || store=''
  [[ -n $store && -d $store ]] || store=/var/lib
  require_free_space_on "$DATA_DIR" "$need" 'chain data' "$note"
  require_free_space_on "$store" 20 'image builds'
}

enable_time_sync() {
  # The daemon units order themselves After=time-sync.target, but that target is
  # only ever reached if something pulls it in: systemd ships
  # systemd-time-wait-sync for exactly this and leaves it disabled.  Without it
  # the ordering is a no-op and the nodes can start against an unsynchronised
  # clock, which Monero and both Core daemons all handle badly.
  if ! systemctl cat systemd-time-wait-sync.service >/dev/null 2>&1; then
    # Debian 13 ships the unit in systemd-timesyncd, so this is the expected
    # branch on a host that keeps time with chrony or ntpsec instead.
    echo 'systemd-time-wait-sync is not installed (on Debian it comes with' >&2
    echo 'systemd-timesyncd), so the nodes will not wait for a synchronised clock' >&2
    echo 'at boot.  That is expected with chrony or ntpsec; make sure something' >&2
    echo 'keeps this clock in sync.' >&2
    return 0
  fi
  # Without a bound this unit waits forever, and every container orders itself
  # After=time-sync.target -- so an unreachable NTP server would hold the whole
  # deployment at boot rather than starting it with a slightly wrong clock.
  # Ordering is not a requirement, so a timeout still lets the target be reached.
  install -d -m 0755 /etc/systemd/system/systemd-time-wait-sync.service.d
  cat >/etc/systemd/system/systemd-time-wait-sync.service.d/timeout.conf <<'TIMEOUT'
[Service]
TimeoutStartSec=5min
TIMEOUT
  chmod 0644 /etc/systemd/system/systemd-time-wait-sync.service.d/timeout.conf
  systemctl daemon-reload
  # Enabling and starting are separate steps with separate failures.  One
  # `enable --now` used to report "could not enable" when the enable had worked
  # and the START had sat out its five minutes waiting for an NTP server -- the
  # message sent the operator to the wrong problem.
  if ! systemctl enable systemd-time-wait-sync.service >/dev/null; then
    echo 'Could not enable systemd-time-wait-sync; the nodes will not wait for a' >&2
    echo 'synchronised clock at boot.' >&2
    return 0
  fi
  if [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) != yes ]]; then
    echo 'Waiting up to five minutes for the clock to synchronise...'
  fi
  if ! systemctl start systemd-time-wait-sync.service; then
    echo 'The clock has not synchronised after five minutes.  Continuing -- the' >&2
    echo 'nodes start regardless, and at boot they wait no longer than this -- but' >&2
    echo 'check timedatectl: both Core daemons and Monero handle a skewed clock badly.' >&2
  fi
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
      -v "$PREFIX/secrets/monero-wallet-password:/secrets/monero-wallet-password:ro" \
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
  local leftover="$DATA_DIR/litecoin/wallet-dump.txt"
  [[ -s $out ]] && return 0
  # A run that stopped between dumpwallet and the mv below left the dump in the
  # chain data directory, and dumpwallet refuses to overwrite an existing file
  # -- so every later run failed at this same step, with the wallet unlocked
  # for a minute each time.  A complete dump ends with Core's "End of dump"
  # line: finish moving that one; anything shorter is destroyed and redone.
  if [[ -e $leftover ]]; then
    if tail -n 1 "$leftover" | grep -q '^# End of dump'; then
      mv "$leftover" "$out"
      chmod 0600 "$out"
      return 0
    fi
    shred -u -z -- "$leftover"
  fi
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
  local answer=''
  # || answer='': with no terminal, read fails at end of input and errexit
  # would end the run without the line below saying nothing was touched.
  read -r -p 'Type SHRED to continue: ' answer || answer=''
  if [[ $answer != SHRED ]]; then
    echo 'Aborted; nothing was removed.'
    exit 1
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
    # exit, not return: the message above is complete, and a return here would
    # also have the error trap announce a "stopped" run on top of it.
    exit 1
  fi
  echo 'Done.  setup.sh --print-recovery will now report the material as unavailable.'
}

client_public_key() {
  # Prints the one line to record for a client that brings its own key, in the
  # exact form the generate path below writes, or refuses.  Arti reads every
  # *.auth file in the directory at start and skips one it cannot parse with
  # only a warning in its log -- so a mistyped key here would leave the client
  # locked out while this command reported success.  Checked here instead.
  local given=$1 key bytes
  key=${given//[[:space:]]/}
  # The C-tor CLIENT file format, <onion>:descriptor:x25519:<key>, carries the
  # client's PRIVATE key.  Its shape is unmistakable, and a private key copied
  # onto the server is exactly what this path exists to avoid.
  if [[ ${key,,} =~ ^[a-z2-7]{56}(\.onion)?:descriptor:x25519: ]]; then
    echo 'That is a client PRIVATE key line (<onion address>:descriptor:x25519:...),' >&2
    echo 'as kept in a C-tor ClientOnionAuthDir.  It must never be copied to this server.' >&2
    echo "Give the client's PUBLIC key instead: the line \`arti hsc key get\` prints." >&2
    echo 'Nothing was changed.' >&2
    exit 64
  fi
  if [[ ${key,,} == descriptor:x25519:* ]]; then
    key=${key:18}
  fi
  # Base32 is case-insensitive; Arti accepts either, and one case on disk keeps
  # the duplicate check below honest.
  key=${key^^}
  # 32 bytes is 52 base32 characters, and the last one carries a single bit of
  # key and four of padding, which a strict decoder requires to be zero -- so
  # it can only be A or Q.
  bytes=0
  if [[ $key =~ ^[A-Z2-7]{51}[AQ]$ ]]; then
    bytes=$(printf '%s====' "$key" | base32 -d 2>/dev/null | wc -c) || bytes=0
  fi
  if (( bytes != 32 )) || [[ $key =~ ^A+$ ]]; then
    echo 'That is not an x25519 public key.  Expected descriptor:x25519: followed by' >&2
    printf '52 base32 characters (A-Z, 2-7), as \140arti hsc key get\140 prints it; got %d characters\n' \
      "${#key}" >&2
    echo 'after the prefix.  Nothing was changed.' >&2
    exit 64
  fi
  printf 'descriptor:x25519:%s\n' "$key"
}

restricted_discovery_on() {
  # True when the INSTALLED arti.toml turns restricted discovery on for this
  # service, in either of the two spellings TOML allows.  Comments are dropped
  # first: the shipped file carries every one of these lines commented out.
  local service=$1
  [[ -r $PREFIX/arti.toml ]] || return 1
  awk -v s="$service" '
    { line = $0; sub(/#.*/, "", line); gsub(/[[:space:]]/, "", line) }
    line ~ /^\[/ { hdr = line; next }
    hdr == "[onion_services.\"" s "\"]" && line == "restricted_discovery.enabled=true" { on = 1 }
    hdr == "[onion_services.\"" s "\".restricted_discovery]" && line == "enabled=true" { on = 1 }
    END { exit !on }' "$PREFIX/arti.toml"
}

apply_client_key() {
  # Arti reads restricted-discovery keys when it starts.  Measured against
  # Arti 2.8.0 with no network: after SIGHUP it logs "Successfully reloaded
  # configuration" but showed no sign of rereading the key directory -- a
  # malformed key file added before the signal drew no warning, the same file
  # present at start did -- and watch_configuration behaved the same.  A
  # reload that may not apply is the worst kind of success message here, so
  # this restarts instead, which is known to.
  local service=$1 file=$2 since log rejected=''
  if ! restricted_discovery_on "$service"; then
    cat <<OFF

Restricted discovery is not on for $service yet, so Arti does not read this
key until it is.  Uncomment this service's restricted_discovery.enabled line
and its key_dirs block in $PREFIX/arti.toml, then: sudo systemctl restart arti
Confirm you can still reach the service afterwards, from a client holding this
key, before doing the same to the others.
OFF
    return 0
  fi
  if [[ ${RESTART_ARTI:-yes} == no ]]; then
    cat <<LATER

Restricted discovery is on for $service, and RESTART_ARTI=no: Arti reads this
key the next time it starts.  Until then the client cannot reach the service.
When ready: sudo systemctl restart arti
LATER
    return 0
  fi
  echo
  echo 'Restricted discovery is on for this service, so restarting Arti to read the'
  echo 'key.  All four onion services are unreachable for a few minutes while they'
  echo 'republish; the chains keep running and reconnect through it.'
  since=$(date +%s)
  systemctl restart arti.service
  wait_for_listener crypto-arti arti "$ARTI_SOCKS_HOST" "$ARTI_SOCKS_PORT" 5
  # Arti names a key file in its log only when it could not use it.  The line
  # comes before it starts listening, but reaches the journal through conmon,
  # so give it a moment rather than reading the journal once.
  for _ in 1 2 3; do
    sleep 2
    if ! log=$(journalctl -u arti.service --since "@$since" -o cat 2>/dev/null); then
      echo "Arti is back, but its log could not be read to confirm it took the key:" >&2
      echo "look for a line naming $file in: journalctl -u arti -n 50" >&2
      return 0
    fi
    rejected=$(grep -F -- "${file#"$DATA_DIR"/arti/}" <<<"$log" | tail -n 1) || rejected=''
    [[ -z $rejected ]] || break
  done
  if [[ -n $rejected ]]; then
    printf 'Arti did not accept %s:\n  %s\n' "$file" "$rejected" >&2
    echo 'The file is left in place so you can see it; remove it and add the key again.' >&2
    exit 1
  fi
  echo 'Arti is back and did not reject the key.'
}

add_rpc_client() {
  # Authorizes one client for Arti's restricted discovery on one service.
  # Either generates an x25519 keypair (the public half is recorded here, the
  # private half printed once for the client), or, with --public-key, records
  # a public key the client made itself -- the only way an Arti client can be
  # authorized, since Arti cannot take a pasted private key.
  # Refusals exit rather than return: each message is complete on its own, and
  # a return would also have the error trap report a "stopped" run.
  local service=${1:-} name=${2:-} given='' have_key=0 dir file line tmp pub priv held
  shift 2 2>/dev/null || shift $#
  while (( $# )); do
    case $1 in
      --public-key)
        (( $# >= 2 )) || { echo '--public-key needs the key after it.' >&2; exit 64; }
        given=$2; have_key=1; shift 2 ;;
      --public-key=*) given=${1#--public-key=}; have_key=1; shift ;;
      *) printf 'Unexpected argument after the client name: %s\n' "$1" >&2; exit 64 ;;
    esac
  done
  case $service in
    bitcoin-rpc|litecoin-rpc|monero-rpc|monero-wallet-rpc) ;;
    *)
      echo 'Service must be one of: bitcoin-rpc litecoin-rpc monero-rpc monero-wallet-rpc' >&2
      exit 64
      ;;
  esac
  # The name becomes a filename in a directory Arti reads; keep it boring.
  if [[ ! $name =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
    echo 'Client name must be alphanumeric, with - and _ allowed after the first character.' >&2
    exit 64
  fi
  case ${RESTART_ARTI:-yes} in
    yes|no) ;;
    *) printf 'RESTART_ARTI must be yes or no; got %q.  Nothing was changed.\n' "$RESTART_ARTI" >&2; exit 64 ;;
  esac
  if (( have_key )); then
    # || exit: the refusal is already printed, and errexit here would add the
    # error trap's "stopped" banner under it.
    line=$(client_public_key "$given") || exit 64
  fi
  dir="$DATA_DIR/arti/authorized_clients/$service"
  file="$dir/$name.auth"
  install -d -m 0700 "$dir"
  if [[ -e $file ]]; then
    echo "A client called $name is already authorized for $service." >&2
    echo "Remove $file first if you mean to reissue its key." >&2
    exit 1
  fi
  if (( have_key )); then
    # Two names for one key would make removing either one look like revoking
    # the client when it is not.
    held=$(grep -rlxF -- "$line" "$dir" 2>/dev/null | head -n 1) || held=''
    if [[ -n $held ]]; then
      echo "That key is already authorized for $service, in $held." >&2
      echo 'Nothing was changed.' >&2
      exit 1
    fi
    # Written beside the target and renamed, so Arti -- which reads every
    # *.auth here -- can never see half a key.
    printf '%s\n' "$line" >"$dir/.$name.auth.new"
    chmod 0600 "$dir/.$name.auth.new"
    mv -f -- "$dir/.$name.auth.new" "$file"
    cat <<OWNKEY

Authorized '$name' for $service with the public key it brought.
  Recorded in: $file
Nothing secret was made or shown: the private half stays with the client.
OWNKEY
    apply_client_key "$service" "$file"
    return 0
  fi
  tmp=$(mktemp -d)
  # EXIT, not RETURN: key.pem below is the client's PRIVATE key, and a RETURN
  # trap does not run when errexit ends the script part way through -- which
  # left that key behind in /tmp whenever an openssl step failed.
  # shellcheck disable=SC2064
  trap "rm -rf -- '$tmp'" EXIT
  openssl genpkey -algorithm x25519 -out "$tmp/key.pem"
  # Both DER encodings put the raw 32-byte key last, which is what Tor's
  # base32 client-auth format wants.
  pub=$(openssl pkey -in "$tmp/key.pem" -pubout -outform DER | tail -c 32 | base32 | tr -d '=\n')
  priv=$(openssl pkey -in "$tmp/key.pem" -outform DER | tail -c 32 | base32 | tr -d '=\n')
  printf 'descriptor:x25519:%s\n' "$pub" >"$dir/.$name.auth.new"
  chmod 0600 "$dir/.$name.auth.new"
  mv -f -- "$dir/.$name.auth.new" "$file"
  cat <<CLIENT

Authorized '$name' for $service.
  Public key recorded in: $file

Give the client this private key.  It is printed once and is not stored here:

  descriptor:x25519:$priv

For a C-tor client, that line goes in ClientOnionAuthDir as
<onion-address-without-.onion>:descriptor:x25519:$priv
An Arti client cannot take it; give one of those --public-key instead.
CLIENT
  apply_client_key "$service" "$file"
}

onion_address() {
  # The identity exists as soon as the service launches, but arti needs a moment
  # after start before the command answers.
  local nickname=$1 address
  # Without this, a stopped Arti cost two minutes per service -- eight before
  # --print-details printed anything -- for an answer known at the first try.
  if [[ $(podman inspect --format '{{.State.Running}}' crypto-arti 2>/dev/null) != true ]]; then
    printf 'unavailable — Arti is not running (systemctl status arti)'
    return 0
  fi
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

require_installed() {
  # --print-details and --print-recovery on a host this has never run on used
  # to end in a bare "No such file or directory" from the shell.
  if [[ ! -s $PREFIX/secrets/rpc-credentials.env ]]; then
    echo "Nothing is installed here yet ($PREFIX/secrets is empty)." >&2
    echo 'Run sudo ./setup.sh first.' >&2
    exit 1
  fi
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

---- For CryptoStore -------------------------------------------
Where each value goes in the store: Admin > Nodes, the coin's card,
then its Connection row.  No password is repeated here; each line
names the one above to copy.  Every address is an onion, so the
store's own Tor proxy (Settings > Tor proxy) has to work first.
Offering a coin to buyers is the card's "Accept ... at checkout"
switch, which nothing here sets.

Bitcoin card > Connection
  Node enabled                 : on
  Address / IP                 : ${btc_onion}
  Port                         : 8332
  RPC username                 : ${BITCOIN_RPC_USER}
  RPC password                 : Password, under Bitcoin Core above
  Wallet name                  : default   (not the store's own default,
                                 "wallet": this node has no such wallet)
  Reach this node through Tor  : on        (forced on for an onion)
  The card's Unlock asks for the Wallet passphrase above when a send
  needs it; it is typed then, never kept as a setting.
  In the store's .env instead: BTC_RPC_ENABLED=true BTC_RPC_HOST
  BTC_RPC_PORT=8332 BTC_RPC_USER BTC_RPC_PASS BTC_RPC_WALLET=default

Litecoin card > Connection
  Node enabled                 : on
  Address / IP                 : ${ltc_onion}
  Port                         : 9332
  RPC username                 : ${LITECOIN_RPC_USER}
  RPC password                 : Password, under Litecoin Core above
  Wallet name                  : default   (not the store's own default,
                                 "wallet": this node has no such wallet)
  Reach this node through Tor  : on        (forced on for an onion)
  Unlock asks for the Litecoin Wallet passphrase above, as for Bitcoin.
  In the store's .env instead: LTC_RPC_ENABLED=true LTC_RPC_HOST
  LTC_RPC_PORT=9332 LTC_RPC_USER LTC_RPC_PASS LTC_RPC_WALLET=default

Monero card > Connection  (the wallet RPC, which takes the payments)
  Node enabled                 : on
  Address / IP                 : ${wallet_onion}
  Port                         : 18088     (the store suggests 18083)
  RPC username                 : ${MONERO_WALLET_RPC_USER}
  RPC password                 : Password, under Monero wallet RPC above
  Wallet name                  : default
  Wallet file password         : leave blank  (this wallet RPC opens its
                                 one file at start and cannot reopen it)
  Reach this node through Tor  : on        (forced on for an onion)
 Same card, Monero daemon (optional; shows real chain sync)
  Daemon address               : ${xmr_onion}
  Port                         : 18089
  Daemon username              : ${MONERO_RPC_USER}
  Daemon password              : Password, under Monero daemon above
  Reach the daemon through Tor : on
  In the store's .env instead: XMR_RPC_ENABLED=true XMR_RPC_HOST
  XMR_RPC_PORT=18088 XMR_RPC_USER XMR_RPC_PASS XMR_DAEMON_HOST
  XMR_DAEMON_PORT=18089 XMR_DAEMON_USER XMR_DAEMON_PASS

If restricted discovery is on for a service (README), authorize the
store's own Arti for it first, with the public key that Arti prints:
  sudo $0 --add-rpc-client <service> store --public-key '<key>'

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
* Treat every onion address as a secret.  Unless restricted discovery has
  been turned on (README), there is no authorization at the Tor layer, so the
  address plus these credentials is the entire gate.
* Onion addresses answer only once Arti has bootstrapped and published them,
  usually a few minutes after it starts; a client that connects sooner gets a
  descriptor-not-found error, not a wrong-password one.

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
  check_update_route_choice
  # Only the two build base images come from a registry, and both must still be
  # immutable: they are the root of trust for every binary built below.
  resolve_base_images

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  # gnupg and jq are for update.sh: it verifies upstream release signatures and
  # parses the GitHub, crates.io and registry APIs.  Without jq every component
  # check fails, so it is a hard dependency of the bundle, not an extra.
  # nftables is named because --no-install-recommends skips it: it is only a
  # Recommends of netavark, podman's network backend, whose nftables firewall
  # driver programs the bridges' rules through it.  It is Priority: important, so
  # a normal install already has it; naming it keeps a minimal image from
  # depending on that.  Installing it changes no rules and enables nothing.
  # (aardvark-dns, the other Recommends, is not needed: neither network here
  # has container DNS.)
  apt-get install -y --no-install-recommends podman uidmap slirp4netns fuse-overlayfs \
    nftables ca-certificates openssl xxd gnupg curl jq
  warn_podman_version

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
  # Before the two steps below that can wait (a prompt, and up to five minutes
  # for the clock), so a disk that is too small is reported straight away.
  require_free_space
  # Optional and cosmetic; a failure here must not take the install with it.
  maybe_install_podman_desktop ||
    echo 'Podman Desktop step failed; continuing without it.' >&2
  enable_time_sync

  initialize_secrets
  install_configs
  # install_configs reinstalls both Core configs from the bundle, dropping the
  # wallet=default line a previous run appended.  Put it back before the restart
  # below, or a re-run brings the daemons up with no wallet loaded and the
  # -rpcwallet=default probe in ensure_core_wallet aborts the install.  The
  # existence guard inside makes this a no-op on a first install.
  autoload_wallet bitcoin "$PREFIX/bitcoin.conf"
  autoload_wallet litecoin "$PREFIX/litecoin.conf"

  remember_bundle_images
  build_all_images
  install_quadlets
  write_images_env
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
  remove_superseded_images
  # Last, not with the other installs: Persistent=true and no stamp file means
  # the timer fires its first check the moment it is enabled, and that is worth
  # far less noise once the install has actually finished.
  install_update_timer
  echo 'Installation complete.  Services may take time to bootstrap/sync.'
  print_operator_summary
  print_recovery_summary
}

# Sourcing this file (a test harness does) defines the functions and stops.
[[ ${BASH_SOURCE[0]} == "$0" ]] || return 0

case ${1:-} in
  -h|--help)
    usage
    exit 0
    ;;
  --print-details)
    require_root
    require_installed
    print_operator_summary
    exit 0
    ;;
  --print-recovery)
    require_root
    require_installed
    print_recovery_summary
    exit 0
    ;;
  --shred-recovery)
    require_root
    shred_recovery
    exit 0
    ;;
  --add-rpc-client)
    require_root
    shift
    add_rpc_client "$@"
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
