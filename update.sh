#!/usr/bin/env bash
# Routine maintenance for an installed bundle: check upstream for new releases,
# verify their signatures, re-pin, rebuild and restart.
#
# Deliberately does not print wallet recovery material or connection secrets --
# those live in setup.sh.  That makes this safe to run from a timer, where
# stdout lands in the journal.
set -Eeuo pipefail
umask 077

# shellcheck source=lib.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

readonly UA='crypto-daemons-podman'
readonly COMPONENTS=(bitcoin litecoin monero arti base rust)
WORK=''
trap '[[ -n $WORK ]] && rm -rf -- "$WORK"' EXIT

usage() {
  cat <<USAGE
Usage: sudo ./update.sh --check
       sudo ./update.sh --apply <component>...
       sudo ./update.sh --redeploy [component]...

Checks upstream for new releases, verifies their signatures against the
fingerprints pinned in keys/fingerprints.txt, and re-pins on request.

Commands:
  --check                Report pinned vs available for every component.
                         Read-only and safe to run from a timer.
  --apply <component>... Verify, re-pin, rebuild and restart the component.
  --redeploy [comp]...   Rebuild and restart from the pins as they stand now,
                         without consulting upstream.  Use after editing a
                         Containerfile by hand.  No arguments means everything.
  -h, --help             Show this message.

Components: ${COMPONENTS[*]}
  bitcoin, litecoin, monero   daemon release, checksum verified against a
                              signed upstream manifest
  arti                        crate version; cargo verifies the crate itself
  base                        Debian build/runtime image digest
  rust                        Rust image digest used to compile arti

Never prints wallet recovery material or RPC credentials; use
'setup.sh --print-details' for those.
USAGE
}

fetch() { curl -fsSL --max-time 60 -A "$UA" "$@" </dev/null; }
# --yes because --batch otherwise refuses to overwrite an existing --output
# file, which reads as a zero-signature verification on the second chain.
gpgr()  { gpg --batch --yes --no-tty --homedir "$KEYRING_DIR" "$@"; }

pinned_keys()      { awk -v c="$1" '$1=="key" && $2==c {print toupper($3)}' "$FINGERPRINTS"; }
pinned_threshold() { awk -v c="$1" '$1=="threshold" && $2==c {print $3}' "$FINGERPRINTS"; }

# Import every pinned key, refusing anything whose primary fingerprint does not
# match.  The fetch is therefore untrusted: keys/fingerprints.txt is the anchor.
import_keys() {
  install -d -m 0700 "$KEYRING_DIR"
  local -a lines=()
  mapfile -t lines <"$FINGERPRINTS"
  local line kw chain fp url got tmp=$WORK/key
  for line in "${lines[@]}"; do
    read -r kw chain fp url <<<"$line"
    [[ ${kw:-} == key ]] || continue
    fp=${fp^^}
    gpgr --list-keys "$fp" >/dev/null 2>&1 && continue
    if ! fetch -o "$tmp" "$url"; then
      printf 'Could not fetch key %s from %s\n' "$fp" "$url" >&2
      return 1
    fi
    got=$(gpg --batch --with-colons --import-options show-only --import "$tmp" 2>/dev/null |
          awk -F: '/^fpr:/{print toupper($10); exit}')
    if [[ ${got:-} != "$fp" ]]; then
      printf 'Refusing key from %s: got %s, pinned %s\n' "$url" "${got:-none}" "$fp" >&2
      return 1
    fi
    gpgr --import "$tmp" >/dev/null 2>&1
  done
}

# Verify a chain's release manifest and echo the checksum of its x86_64 tarball.
# Prints nothing and fails if the signature threshold is not met, so a caller
# can never read a checksum out of an unverified document.
verify_manifest() {
  local chain=$1 version=$2
  local manifest=$WORK/manifest sig=$WORK/manifest.asc plain=$WORK/plain
  local status=$WORK/status tarball need good=0 fp
  need=$(pinned_threshold "$chain")
  # Never let one chain's artefacts survive into the next chain's check.
  rm -f -- "$manifest" "$sig" "$plain"
  : >"$status"

  case $chain in
    bitcoin)
      tarball="bitcoin-${version}-x86_64-linux-gnu.tar.gz"
      fetch -o "$manifest" "https://bitcoincore.org/bin/bitcoin-core-${version}/SHA256SUMS" || return 1
      fetch -o "$sig" "https://bitcoincore.org/bin/bitcoin-core-${version}/SHA256SUMS.asc" || return 1
      gpgr --status-fd 3 --verify "$sig" "$manifest" 3>"$status" >/dev/null 2>&1 || true
      cp "$manifest" "$plain"
      ;;
    litecoin)
      tarball="litecoin-${version}-x86_64-linux-gnu.tar.gz"
      fetch -o "$manifest" \
        "https://github.com/litecoin-project/litecoin/releases/download/v${version}/SHA256SUMS.asc" || return 1
      # --decrypt emits only the signed body, so text smuggled outside the
      # clearsigned block cannot reach the checksum lookup below.
      gpgr --status-fd 3 --output "$plain" --decrypt "$manifest" 3>"$status" >/dev/null 2>&1 || true
      ;;
    monero)
      tarball="monero-linux-x64-v${version}.tar.bz2"
      fetch -o "$manifest" 'https://www.getmonero.org/downloads/hashes.txt' || return 1
      gpgr --status-fd 3 --output "$plain" --decrypt "$manifest" 3>"$status" >/dev/null 2>&1 || true
      ;;
    *) return 1 ;;
  esac

  # Count distinct PRIMARY keys that both signed validly and are pinned for this
  # chain.  VALIDSIG's last field is the primary key; several Bitcoin builders
  # sign with subkeys, whose fingerprints would never match a pinned primary.
  local -a signers=()
  mapfile -t signers < <(awk '/^\[GNUPG:\] VALIDSIG/{print toupper($NF)}' "$status" | sort -u)
  for fp in "${signers[@]:-}"; do
    [[ -n $fp ]] || continue
    if pinned_keys "$chain" | grep -qxF "$fp"; then
      good=$((good + 1))
    fi
  done
  # Callers invoke this in a command substitution to capture the checksum, so
  # the subshell cannot hand back variables; leave the counts in $WORK instead.
  printf '%s\n' "$good" >"$WORK/sigcount"
  if grep -q '^\[GNUPG:\] EXPKEYSIG' "$status"; then
    printf '1\n' >"$WORK/expired"
  else
    printf '0\n' >"$WORK/expired"
  fi

  if (( good < need )); then
    printf 'refusing %s %s: %d trusted signature(s), need %d\n' \
      "$chain" "$version" "$good" "$need" >&2
    return 1
  fi
  awk -v t="$tarball" '$2 == t {print $1; found=1} END {exit !found}' "$plain"
}

latest_version() {
  case $1 in
    bitcoin)  fetch https://api.github.com/repos/bitcoin/bitcoin/releases/latest | jq -r '.tag_name | ltrimstr("v")' ;;
    litecoin) fetch https://api.github.com/repos/litecoin-project/litecoin/releases/latest | jq -r '.tag_name | ltrimstr("v")' ;;
    monero)   fetch https://api.github.com/repos/monero-project/monero/releases/latest | jq -r '.tag_name | ltrimstr("v")' ;;
    arti)     fetch https://crates.io/api/v1/crates/arti | jq -r '.crate.max_stable_version' ;;
  esac
}

# Current index digest for a Docker Hub tag, without pulling the image.
latest_digest() {
  local repo=$1 tag=$2 token
  token=$(fetch "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" |
          jq -r .token)
  curl -fsSI --max-time 60 -A "$UA" -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.oci.image.index.v1+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
    "https://registry-1.docker.io/v2/${repo}/manifests/${tag}" </dev/null |
    tr -d '\r' | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: //p'
}

pinned_version() {
  case $1 in
    bitcoin)  printf '%s\n' "$BITCOIN_VERSION" ;;
    litecoin) printf '%s\n' "$LITECOIN_VERSION" ;;
    monero)   printf '%s\n' "$MONERO_VERSION" ;;
    arti)     printf '%s\n' "$ARTI_VERSION" ;;
    base)     printf '%s\n' "${DEFAULT_BASE_IMAGE#*@}" ;;
    rust)     printf '%s\n' "${DEFAULT_ARTI_RUST_IMAGE#*@}" ;;
  esac
}

report() { printf '  %-9s %-12s %s\n' "$1" "$2" "$3"; }

cmd_check() {
  local comp pinned latest sha note rc=0
  import_keys
  printf '\nComponent  Status       Detail\n'
  printf -- '---------------------------------------------------------------\n'
  for comp in "${COMPONENTS[@]}"; do
    pinned=$(pinned_version "$comp")
    case $comp in
      base) latest=$(latest_digest library/debian trixie-slim) ;;
      rust) latest=$(latest_digest library/rust 1-trixie) ;;
      *)    latest=$(latest_version "$comp") ;;
    esac
    if [[ -z ${latest:-} ]]; then
      report "$comp" 'unknown' 'could not reach upstream'
      rc=1
      continue
    fi
    if [[ $pinned == "$latest" ]]; then
      report "$comp" 'current' "$pinned"
      continue
    fi
    case $comp in
      bitcoin|litecoin|monero)
        if sha=$(verify_manifest "$comp" "$latest"); then
          local count expired
          count=$(<"$WORK/sigcount")
          expired=$(<"$WORK/expired")
          note="$pinned -> $latest  (${count} trusted sig"
          (( count == 1 )) || note+='s'
          note+=')'
          (( expired )) && note+='  [signing key EXPIRED]'
          report "$comp" 'UPDATE' "$note"
          printf '  %-9s %-12s sha256:%s\n' '' '' "$sha"
        else
          report "$comp" 'BLOCKED' "$latest available but signature check failed"
          rc=1
        fi
        ;;
      *)
        report "$comp" 'UPDATE' "$pinned -> $latest"
        ;;
    esac
  done
  printf -- '---------------------------------------------------------------\n'
  printf 'Apply with: sudo ./update.sh --apply <component>\n\n'
  return $rc
}

repin_chain() {
  local chain=$1 version=$2 sha=$3
  # Separate statement: bash creates every name in a `local` list before
  # assigning any of them, so ${chain^^} here would read as unset under set -u.
  local upper=${chain^^}
  local file="$BUNDLE_DIR/containers/${chain}.Containerfile"
  sed -i -e "s|^ARG ${upper}_VERSION=.*|ARG ${upper}_VERSION=${version}|" \
         -e "s|^ARG ${upper}_SHA256=.*|ARG ${upper}_SHA256=${sha}|" "$file"
  printf '  re-pinned %s to %s\n' "$chain" "$version"
}

repin_digest() {
  local var=$1 repo=$2 tag=$3 digest
  digest=$(latest_digest "$repo" "$tag")
  [[ -n $digest ]] || { printf 'Could not resolve %s:%s\n' "$repo" "$tag" >&2; return 1; }
  sed -i "s|^readonly ${var}=.*|readonly ${var}='docker.io/${repo}@${digest}'|" "$BUNDLE_DIR/lib.sh"
  printf '  re-pinned %s to %s\n' "$var" "$digest"
}

cmd_apply() {
  local comp latest sha
  import_keys
  for comp in "$@"; do
    case $comp in
      bitcoin|litecoin|monero)
        latest=$(latest_version "$comp")
        [[ $latest == "$(pinned_version "$comp")" ]] && { printf '  %s already current\n' "$comp"; continue; }
        sha=$(verify_manifest "$comp" "$latest") || return 1
        repin_chain "$comp" "$latest" "$sha"
        ;;
      arti)
        latest=$(latest_version arti)
        [[ $latest == "$ARTI_VERSION" ]] && { printf '  arti already current\n'; continue; }
        sed -i "s|^ARG ARTI_VERSION=.*|ARG ARTI_VERSION=${latest}|" \
          "$BUNDLE_DIR/containers/arti.Containerfile"
        printf '  re-pinned arti to %s\n' "$latest"
        ;;
      base) repin_digest DEFAULT_BASE_IMAGE library/debian trixie-slim ;;
      rust) repin_digest DEFAULT_ARTI_RUST_IMAGE library/rust 1-trixie ;;
      *) printf 'Unknown component: %s\n' "$comp" >&2; return 64 ;;
    esac
  done
  # Re-exec so lib.sh re-reads the pins just rewritten; otherwise the rebuild
  # would tag images with the versions this process started with.
  printf '\nRebuilding from the new pins...\n'
  exec "$BUNDLE_DIR/update.sh" --redeploy "$@"
}

cmd_redeploy() {
  local -a comps=("$@")
  (( ${#comps[@]} )) || comps=("${COMPONENTS[@]}")
  resolve_base_images
  local comp rebuild_all=0
  for comp in "${comps[@]}"; do
    case $comp in arti|base|rust) rebuild_all=1 ;; esac
  done

  if (( rebuild_all )); then
    build_all_images
  else
    for comp in "${comps[@]}"; do
      case $comp in
        bitcoin)  build_daemon_image bitcoin "$BITCOIN_IMAGE" ;;
        litecoin) build_daemon_image litecoin "$LITECOIN_IMAGE" ;;
        monero)   build_daemon_image monero "$MONERO_IMAGE" ;;
        *) printf 'Unknown component: %s\n' "$comp" >&2; return 64 ;;
      esac
    done
  fi

  write_images_env
  install_quadlets

  if (( rebuild_all )); then
    restart_all_services
  else
    for comp in "${comps[@]}"; do systemctl restart "${comp}.service"; done
  fi

  # Confirm the chain daemons actually answered after the restart, so a failed
  # update is reported here rather than discovered later.
  wait_for_core_rpc bitcoin bitcoin-cli
  wait_for_core_rpc litecoin litecoin-cli
  printf 'Update complete.  Deployed images:\n'
  sed 's/^/  /' "$PREFIX/images.env"
}

WORK=$(mktemp -d)

case ${1:-} in
  -h|--help) usage; exit 0 ;;
  --check)    require_root; shift; cmd_check ;;
  --apply)    require_root; shift; (( $# )) || { echo 'Name at least one component.' >&2; exit 64; }; cmd_apply "$@" ;;
  --redeploy) require_root; shift; cmd_redeploy "$@" ;;
  '')  usage >&2; exit 64 ;;
  *)   printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 64 ;;
esac
