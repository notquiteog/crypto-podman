#!/usr/bin/env bash
# Shared definitions for setup.sh and update.sh.  Sourced, never executed.
#
# shellcheck disable=SC2034
#   Every constant here is consumed by setup.sh or update.sh after sourcing, so
#   "appears unused" is structurally wrong for this file.  Loop counters are
#   written as _ rather than hidden behind this.
#
# setup.sh performs the first install: host packages, secrets, wallets, and the
# one-time printing of recovery material.  update.sh performs routine
# maintenance: re-pinning a component, rebuilding, and restarting.  Everything
# both of them need lives here, so a pin is defined once and a rebuild behaves
# identically whichever entry point triggered it.

readonly PREFIX=/etc/crypto-daemons
readonly QUADLET_DIR=/etc/containers/systemd
readonly DATA_DIR=/srv/crypto-daemons
# Assigned before it is made readonly: `readonly X="$(cmd)"` returns readonly's
# status, which would mask a failing cd.
BUNDLE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly BUNDLE_DIR
# Signature checking uses a keyring of its own rather than root's, so importing
# a release key never widens what the rest of the system trusts.
readonly KEYRING_DIR="$PREFIX/keys"
# podman tars the build context and hands it to the builder.  $PREFIX holds the
# wallet spend keys, so builds get a directory of their own that is kept empty;
# no Containerfile here reads anything from its context.
readonly BUILD_CONTEXT="$PREFIX/build"
readonly FINGERPRINTS="$BUNDLE_DIR/keys/fingerprints.txt"
readonly SERVICES=(arti.service bitcoin.service litecoin.service monero.service)
# Every image repository this bundle builds into.  Superseded images are only
# ever looked for here, so nothing else on the host can be touched.
readonly IMAGE_REPOS=(localhost/crypto-arti localhost/crypto-bitcoin localhost/crypto-litecoin localhost/crypto-monero)
# Arti's SOCKS listener.  The same address is written in arti.container
# (Network=crypto.network:ip= and HealthCmd), in arti.toml (socks_listen) and
# in systemd/crypto-update-check.service (IPAddressAllow=); move all of them
# together.  The host reaches it through the internal bridge's own gateway
# address, so nothing is published for update.sh to use it.
readonly ARTI_SOCKS_HOST=10.89.0.10
readonly ARTI_SOCKS_PORT=9150
# Present only when setup.sh was run with UPDATE_CHECK_ROUTE=direct; see
# install_update_timer.  update.sh reads the route back out of the unit.
readonly UPDATE_ROUTE_DROPIN=/etc/systemd/system/crypto-update-check.service.d/route.conf

on_error() {
  # Under set -e a failing step used to end the run with only the failing
  # command's own output -- often a bare podman or curl line -- and nothing to
  # say that the run had stopped, or whether it was safe to try again.  Both
  # scripts are written to be re-run, so say so.  Only the top-level shell
  # reports: set -E hands this trap to every command substitution as well, and
  # a failure inside one would otherwise be announced twice.
  #
  # The step is quoted from the source line, not taken from $BASH_COMMAND: when
  # a function of this bundle fails, $BASH_COMMAND is the last thing it ran --
  # usually "return 1" -- which names nothing.  BASH_SOURCE[1] is the file the
  # trap fired in, so a failure inside lib.sh is pointed at lib.sh.
  local status=$? line=$1 file=${BASH_SOURCE[1]:-$0} text
  (( BASH_SUBSHELL == 0 )) || return 0
  text=$(sed -n "${line}{s/^[[:space:]]*//;p;q;}" "$file" 2>/dev/null) || text=''
  (( ${#text} <= 100 )) || text="${text:0:97}..."
  printf '\n%s stopped (exit %s) at %s line %s:\n  %s\n' \
    "${0##*/}" "$status" "${file##*/}" "$line" "$text" >&2
  printf 'Nothing after that step ran.  Fix the cause above, then run the same command again; it is safe to repeat.\n' >&2
}
trap 'on_error "$LINENO"' ERR

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
# live in containers/*.Containerfile; bump them there and nowhere else, or let
# update.sh --apply do it for you.
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
# name -- require_digest still refuses mutable tags.  update.sh --check reports
# when either has moved.
readonly DEFAULT_BASE_IMAGE='docker.io/library/debian@sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258'
readonly DEFAULT_ARTI_RUST_IMAGE='docker.io/library/rust@sha256:b1b3c9c0d921d7fa0a6d1f9ec7e4eab87f8c8ec97644c3d791450f131dec813f'

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

load_credentials() {
  # This file is created locally with 0600 permissions and contains only values
  # generated by this script.
  set -a
  # shellcheck source=/dev/null
  . "$PREFIX/secrets/rpc-credentials.env"
  set +a
}

install_template() {
  local input=$1 output=$2
  sed \
    -e "s|@@BUNDLE_DIR@@|${BUNDLE_DIR}|g" \
    -e "s|@@ARTI_IMAGE@@|${ARTI_IMAGE}|g" \
    -e "s|@@BITCOIN_IMAGE@@|${BITCOIN_IMAGE}|g" \
    -e "s|@@LITECOIN_IMAGE@@|${LITECOIN_IMAGE}|g" \
    -e "s|@@MONERO_IMAGE@@|${MONERO_IMAGE}|g" \
    "$input" >"$output"
  # Written under this script's umask 077; every caller installs a unit file,
  # and unit files are 0644 like the two .network files installed beside them.
  chmod 0644 "$output"
}

build_daemon_image() {
  # The Containerfile downloads the upstream release and checks it against a
  # checksum pinned in the file itself, so a tampered download fails the build.
  local chain=$1 tag=$2
  install -m 0644 "$BUNDLE_DIR/containers/$chain.Containerfile" "$PREFIX/$chain.Containerfile"
  install -d -m 0755 "$BUILD_CONTEXT"
  # --pull=missing, not podman build's default of always: both bases are
  # digest-pinned and require_digest refuses anything else, so a re-pull cannot
  # produce different bytes than the local copy -- it only makes every rebuild
  # depend on Docker Hub being reachable.
  podman build --pull=missing --tag "$tag" \
    --build-arg "FETCH_IMAGE=$BASE_IMAGE" \
    --build-arg "RUNTIME_IMAGE=$BASE_IMAGE" \
    --file "$PREFIX/$chain.Containerfile" "$BUILD_CONTEXT"
}

wait_for_core_rpc() {
  # main restarts the daemons, so this waits for a real block-index reload
  # rather than answering instantly against an already-running node.  Ten
  # minutes matches the units' TimeoutStopSec and costs nothing when the
  # daemon comes up quickly.
  local container=$1 cli=$2
  for _ in {1..300}; do
    if podman exec "$container" "$cli" -datadir=/data getblockchaininfo >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "$container RPC did not become ready within ten minutes." >&2
  echo "Its own log says why: journalctl -u $container -n 50" >&2
  return 1
}

wait_for_listener() {
  # For the three services whose RPC needs credentials (and Arti, which has no
  # RPC at all): a TCP connect inside the container, the same probe as their
  # health checks, so a successful update is reported only once the process is
  # actually accepting connections.  Container and unit names differ for Arti.
  local container=$1 unit=$2 address=$3 port=$4 minutes=$5
  local tries=$(( minutes * 30 )) n
  for (( n = 0; n < tries; n++ )); do
    if podman exec "$container" bash -c "exec 3<>/dev/tcp/$address/$port" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "$unit is not accepting connections on $address:$port after $minutes minutes." >&2
  echo "Its own log says why: journalctl -u $unit -n 50" >&2
  return 1
}

resolve_base_images() {
  # Unset means "use the reviewed pin above", not "pick something mutable".
  BASE_IMAGE=${BASE_IMAGE:-$DEFAULT_BASE_IMAGE}
  ARTI_RUST_IMAGE=${ARTI_RUST_IMAGE:-$DEFAULT_ARTI_RUST_IMAGE}
  require_digest BASE_IMAGE "$BASE_IMAGE"
  require_digest ARTI_RUST_IMAGE "$ARTI_RUST_IMAGE"
}

build_arti_image() {
  install -m 0644 "$BUNDLE_DIR/containers/arti.Containerfile" "$PREFIX/arti.Containerfile"
  install -d -m 0755 "$BUILD_CONTEXT"
  podman build --pull=missing --tag "$ARTI_IMAGE" \
    --build-arg "RUST_IMAGE=$ARTI_RUST_IMAGE" \
    --build-arg "RUNTIME_IMAGE=$BASE_IMAGE" \
    --file "$PREFIX/arti.Containerfile" "$BUILD_CONTEXT"
}

build_all_images() {
  build_arti_image
  build_daemon_image bitcoin "$BITCOIN_IMAGE"
  build_daemon_image litecoin "$LITECOIN_IMAGE"
  build_daemon_image monero "$MONERO_IMAGE"
}

install_quadlets() {
  install -m 0644 "$BUNDLE_DIR/quadlet/crypto.network" "$QUADLET_DIR/crypto.network"
  install -m 0644 "$BUNDLE_DIR/quadlet/crypto-egress.network" \
    "$QUADLET_DIR/crypto-egress.network"
  install_template "$BUNDLE_DIR/quadlet/arti.container" "$QUADLET_DIR/arti.container"
  install_template "$BUNDLE_DIR/quadlet/bitcoin.container" "$QUADLET_DIR/bitcoin.container"
  install_template "$BUNDLE_DIR/quadlet/litecoin.container" "$QUADLET_DIR/litecoin.container"
  install_template "$BUNDLE_DIR/quadlet/monero.container" "$QUADLET_DIR/monero.container"
  install_template "$BUNDLE_DIR/quadlet/monero-wallet-rpc.container" \
    "$QUADLET_DIR/monero-wallet-rpc.container"
  systemctl daemon-reload
  # daemon-reload succeeds even when the Quadlet generator rejected a file: the
  # unit is simply never created, and the first sign was a restart failing with
  # "Unit arti.service not found", which says nothing about the cause.  Ask for
  # each unit, and show the generator's own complaint if one is missing.
  local unit missing=()
  for unit in "${SERVICES[@]}" monero-wallet-rpc.service crypto-network.service crypto-egress-network.service; do
    [[ $(systemctl show -p LoadState --value "$unit" 2>/dev/null) == loaded ]] || missing+=("$unit")
  done
  if (( ${#missing[@]} )); then
    printf 'The Quadlet generator did not produce: %s\n' "${missing[*]}" >&2
    if [[ -x /usr/libexec/podman/quadlet ]]; then
      echo 'Its own report on the installed files:' >&2
      /usr/libexec/podman/quadlet -dryrun 2>&1 >/dev/null | sed 's/^/  /' >&2 || true
    fi
    return 1
  fi
}

check_update_route_choice() {
  # Called before anything is changed, so a typo stops the run up front
  # rather than after an hour of image builds.
  case ${UPDATE_CHECK_ROUTE:-} in
    ''|tor|direct) ;;
    *)
      printf 'UPDATE_CHECK_ROUTE must be tor or direct; got %q.  Nothing was changed.\n' \
        "$UPDATE_CHECK_ROUTE" >&2
      exit 64
      ;;
  esac
}

install_update_timer() {
  # update.sh is run from wherever the bundle was copied, so the unit records
  # that path at install time.  Moving the bundle afterwards breaks the timer;
  # rerun setup.sh from the new location to repoint it.
  install_template "$BUNDLE_DIR/systemd/crypto-update-check.service" \
    /etc/systemd/system/crypto-update-check.service
  install -m 0644 "$BUNDLE_DIR/systemd/crypto-update-check.timer" \
    /etc/systemd/system/crypto-update-check.timer
  # The unit itself always says tor, and only lets the check talk to Arti's
  # SOCKS address.  Going direct is a drop-in on top of it rather than a second
  # copy of the unit, so `systemctl cat` shows the deviation where it lives.
  # Unset keeps whatever this host already has, so a re-run that forgets the
  # variable cannot quietly undo a deliberate choice in either direction.
  case ${UPDATE_CHECK_ROUTE:-} in
    direct)
      install -d -m 0755 "${UPDATE_ROUTE_DROPIN%/*}"
      cat >"$UPDATE_ROUTE_DROPIN" <<'DIRECT'
# Written by crypto-daemons setup.sh, because it was run with
# UPDATE_CHECK_ROUTE=direct: the daily update check fetches from this host's
# own address instead of through Arti.  To go back through Tor, re-run setup.sh
# with UPDATE_CHECK_ROUTE=tor, or delete this file and run
# `systemctl daemon-reload`.
[Service]
Environment=UPDATE_CHECK_ROUTE=direct
# The unit allows only Arti's SOCKS address; an empty value clears each list.
IPAddressAllow=
IPAddressDeny=
DIRECT
      chmod 0644 "$UPDATE_ROUTE_DROPIN"
      ;;
    tor)
      # Only ever the file written above, recognised by its first line.
      if [[ -e $UPDATE_ROUTE_DROPIN ]] &&
         head -n 1 "$UPDATE_ROUTE_DROPIN" | grep -qF 'Written by crypto-daemons setup.sh'; then
        rm -f -- "$UPDATE_ROUTE_DROPIN"
      fi
      ;;
  esac
  systemctl daemon-reload
  systemctl enable --now crypto-update-check.timer
  if [[ -e $UPDATE_ROUTE_DROPIN ]]; then
    echo "The daily update check fetches from this host's own address (UPDATE_CHECK_ROUTE=direct, in $UPDATE_ROUTE_DROPIN)."
  else
    echo 'The daily update check fetches through Tor, via Arti.'
  fi
}

migrate_internal_network() {
  # `podman network create --ignore` leaves an existing network exactly as it
  # was, so a host installed before crypto.network became internal keeps a
  # network with egress and DNS -- and nothing anywhere would say so.  The
  # whole network-level half of the Tor-only guarantee rests on those two
  # flags, so check them rather than assume the create applied.
  local internal dns
  podman network exists crypto || return 0
  internal=$(podman network inspect crypto --format '{{.Internal}}' 2>/dev/null || echo unknown)
  dns=$(podman network inspect crypto --format '{{.DNSEnabled}}' 2>/dev/null || echo unknown)
  if [[ $internal == true && $dns == false ]]; then
    return 0
  fi
  cat <<MIGRATE

The existing 'crypto' network is not internal (internal=$internal, dns=$dns).
The daemons on it can still reach the clearnet, so the network-level part of
their Tor-only guarantee is not actually in force.  Recreating it -- the
daemons stop for a moment and come back on the same volumes and addresses.
MIGRATE
  systemctl stop monero-wallet-rpc.service "${SERVICES[@]}"
  # RemainAfterExit keeps the network unit "active" long after podman ran, and
  # the network cannot be removed while that unit still owns it.
  systemctl stop crypto-network.service
  if ! podman network rm crypto; then
    cat <<'STUCK' >&2
Could not remove the 'crypto' network.  Something is still attached to it.
Find it with `podman ps -a --filter network=crypto`, detach or remove it, then
rerun.  Refusing to continue: carrying on here would leave the deployment
looking hardened while the daemons still had a route out.
STUCK
    return 1
  fi
  echo 'Removed; the crypto-network unit recreates it internally on next start.'
}

restart_chain_services() {
  # Quadlet-generated units cannot be enabled; the generator applies each unit's
  # [Install] section itself, so starting them is all that is required.
  # restart rather than start: on a re-run the units are already up, and start
  # would leave them on the previous image after a version or base-image bump.
  # The chain units allow 10min TimeoutStopSec, so this is a clean shutdown.
  systemctl restart "${SERVICES[@]}"
}

write_images_env() {
  # A record of exactly what is deployed, so --check and an operator reading
  # the host can both see the resolved pins without re-deriving them.  Written
  # once the units point at these images, never before the build: a build that
  # failed used to leave this naming images that were never deployed, which
  # update.sh then took for the truth.
  {
    printf 'BITCOIN_IMAGE=%s\n' "$BITCOIN_IMAGE"
    printf 'LITECOIN_IMAGE=%s\n' "$LITECOIN_IMAGE"
    printf 'MONERO_IMAGE=%s\n' "$MONERO_IMAGE"
    printf 'ARTI_IMAGE=%s\n' "$ARTI_IMAGE"
    printf 'BASE_IMAGE=%s\n' "$BASE_IMAGE"
    printf 'ARTI_RUST_IMAGE=%s\n' "$ARTI_RUST_IMAGE"
  } >"$PREFIX/images.env"
}

deployed_value() {
  # One NAME=value line out of images.env, the record of what the installed
  # units point at.  Empty when there is no record yet.
  [[ -r $PREFIX/images.env ]] || return 0
  sed -n "s/^$1=//p" "$PREFIX/images.env" | tail -n 1
}

# Image IDs this bundle had tagged before a build, filled by
# remember_bundle_images and consumed by remove_superseded_images.
PREVIOUS_IMAGE_IDS=()

remember_bundle_images() {
  # Taken before building, so that afterwards exactly the images the build
  # replaced can be named by ID.  A version bump leaves the old tag behind; a
  # base-image refresh rebuilds under the SAME tag and leaves the old image
  # untagged -- the old cleanup, which went by tag, never saw that second case,
  # so every `--apply base` stranded four images on the host for good.
  # Each entry is "ID NAME", the name kept for the report: after a same-tag
  # rebuild the old image has no tag left to be called by.
  local repo
  PREVIOUS_IMAGE_IDS=()
  for repo in "${IMAGE_REPOS[@]}"; do
    mapfile -t -O "${#PREVIOUS_IMAGE_IDS[@]}" PREVIOUS_IMAGE_IDS < <(
      podman images --no-trunc --format '{{.ID}} {{.Repository}}:{{.Tag}}' "$repo" 2>/dev/null)
  done
}

remove_superseded_images() {
  # Removes, by exact ID and without force, each image remember_bundle_images
  # saw that no current tag points at any more.  Nothing outside this bundle's
  # own repositories is ever a candidate, so there is no prune here: `podman
  # image prune` acts on the whole host, which may not be dedicated to this.
  # An image a container still uses is refused by podman and kept, and said so.
  # Intermediate layers of arti's Rust build stage are not reachable from any of
  # these IDs and stay as build cache; see the README.
  local ref entry id name current reason removed=0
  local -A keep=() seen=()
  for ref in "$ARTI_IMAGE" "$BITCOIN_IMAGE" "$LITECOIN_IMAGE" "$MONERO_IMAGE"; do
    current=$(podman image inspect --format '{{.Id}}' "$ref" 2>/dev/null) || continue
    keep[${current#sha256:}]=1
  done
  for entry in "${PREVIOUS_IMAGE_IDS[@]}"; do
    id=${entry%% *}
    name=${entry#* }
    id=${id#sha256:}
    [[ -n $id && -z ${keep[$id]:-} && -z ${seen[$id]:-} ]] || continue
    seen[$id]=1
    podman image exists "$id" 2>/dev/null || continue
    if reason=$(podman rmi "$id" 2>&1 >/dev/null); then
      removed=$((removed + 1))
    else
      reason=${reason##*$'\n'}
      printf 'Kept the earlier %s (%s): %s\n' "$name" "${id:0:12}" "${reason#Error: }"
    fi
  done
  if (( removed == 1 )); then
    echo 'Removed 1 image this build replaced.'
  elif (( removed > 1 )); then
    printf 'Removed %d images this build replaced.\n' "$removed"
  fi
}

restart_all_services() {
  # monero-wallet-rpc is excluded from restart_chain_services because at install
  # time it cannot start until the wallet exists; by update time it always does.
  systemctl restart "${SERVICES[@]}" monero-wallet-rpc.service
}

wait_for_services() {
  # Arguments are component names: arti, bitcoin, litecoin, monero.  monero
  # covers the wallet RPC too, since both run the same image.
  local comp
  for comp in "$@"; do
    case $comp in
      arti)     wait_for_listener crypto-arti arti "$ARTI_SOCKS_HOST" "$ARTI_SOCKS_PORT" 5 ;;
      bitcoin)  wait_for_core_rpc bitcoin bitcoin-cli ;;
      litecoin) wait_for_core_rpc litecoin litecoin-cli ;;
      monero)
        wait_for_listener monero monero 127.0.0.1 18089 10
        wait_for_listener monero-wallet-rpc monero-wallet-rpc 127.0.0.1 18088 5
        ;;
    esac
  done
}
