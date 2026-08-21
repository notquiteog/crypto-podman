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

# Upstream strings reach a URL, a Containerfile ARG, or a sed replacement that
# rewrites lib.sh -- which root sources on the very next invocation.  Nothing
# gets that far before it has been checked to look like what it claims to be.
readonly VERSION_RE='^[0-9]+(\.[0-9]+)*$'
readonly DIGEST_RE='^sha256:[0-9a-f]{64}$'
readonly SHA256_RE='^[0-9a-f]{64}$'

validate() {
  local what=$1 value=$2 pattern=$3
  if [[ ! $value =~ $pattern ]]; then
    printf 'Refusing %s: upstream returned %q\n' "$what" "$value" >&2
    return 1
  fi
}

pinned_keys()      { awk -v c="$1" '$1=="key" && $2==c {print toupper($3)}' "$FINGERPRINTS"; }
pinned_threshold() { awk -v c="$1" '$1=="threshold" && $2==c {print $3}' "$FINGERPRINTS"; }

# Import every pinned key, refusing anything whose primary fingerprint does not
# match.  The fetch is therefore untrusted: keys/fingerprints.txt is the anchor.
import_keys() {
  install -d -m 0700 "$KEYRING_DIR"
  local -a lines=()
  mapfile -t lines <"$FINGERPRINTS"
  local line kw chain fp url tmp=$WORK/key
  local -a got=()
  for line in "${lines[@]}"; do
    read -r kw chain fp url <<<"$line"
    [[ ${kw:-} == key ]] || continue
    fp=${fp^^}
    gpgr --list-keys "$fp" >/dev/null 2>&1 && continue
    if ! fetch -o "$tmp" "$url"; then
      printf 'Could not fetch key %s from %s\n' "$fp" "$url" >&2
      return 1
    fi
    # gpgr, not bare gpg: the latter falls back to root's ~/.gnupg, which this
    # bundle deliberately never touches and which the update timer's sandbox
    # makes read-only.  show-only implies --dry-run, so nothing is imported yet.
    if ! gpgr --with-colons --import-options show-only --import "$tmp" >"$tmp.list" 2>/dev/null; then
      printf 'Could not read the key file fetched from %s\n' "$url" >&2
      return 1
    fi
    # Every primary fingerprint in the file, not just the first: the import
    # below takes the whole file, so checking only the first key would let an
    # unpinned one ride along behind a pinned one.
    mapfile -t got < <(awk -F: '$1=="pub"{p=1} $1=="fpr" && p {print toupper($10); p=0}' "$tmp.list")
    if (( ${#got[@]} != 1 )) || [[ ${got[0]} != "$fp" ]]; then
      printf 'Refusing key from %s: got %s, pinned %s\n' "$url" "${got[*]:-none}" "$fp" >&2
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
  validate "the version of $chain" "$version" "$VERSION_RE" || return 1
  need=$(pinned_threshold "$chain")
  # An empty threshold would be arithmetic zero below, which reads as "no
  # signatures required" -- exactly backwards for a missing trust anchor.
  if [[ ! $need =~ ^[1-9][0-9]*$ ]]; then
    printf 'refusing %s: no usable threshold for it in %s\n' "$chain" "$FINGERPRINTS" >&2
    return 1
  fi
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
  # gpg emits REVKEYSIG (or EXPKEYSIG, or GOODSIG) immediately before the
  # VALIDSIG for the same signature, so a revoked signer can be dropped from the
  # tally without blocking the manifest: Bitcoin pins eleven builder keys and
  # needs four, and one builder rotating a key is routine upstream housekeeping,
  # not evidence against the release.  An expired key still counts -- Litecoin's
  # only signature is one -- and is reported instead.
  local -a signers=()
  mapfile -t signers < <(awk '$2=="REVKEYSIG" {rev=1; next}
                              $2=="GOODSIG" || $2=="EXPKEYSIG" {rev=0; next}
                              $2=="VALIDSIG" {if (!rev) print toupper($NF); rev=0}' \
                              "$status" | sort -u)
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
  if grep -q '^\[GNUPG:\] REVKEYSIG' "$status"; then
    printf '1\n' >"$WORK/revoked"
  else
    printf '0\n' >"$WORK/revoked"
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
  # Non-fatal, for the same reason the per-component fetches below are: all the
  # key URLs share one host, and an outage there must not cost the whole report.
  # Chains whose keys are missing then report BLOCKED, with this line above.
  if ! import_keys; then
    printf 'Some release keys could not be fetched; chain checks may report BLOCKED.\n' >&2
    rc=1
  fi
  printf '\nComponent  Status       Detail\n'
  printf -- '---------------------------------------------------------------\n'
  for comp in "${COMPONENTS[@]}"; do
    pinned=$(pinned_version "$comp")
    case $comp in
      # Clear rather than `|| true`: latest is declared once outside the loop,
      # so a partial transfer must not leave a stale value to be read as a
      # bogus 'current' row for the next component.
      base) latest=$(latest_digest library/debian trixie-slim) || latest='' ;;
      rust) latest=$(latest_digest library/rust 1-trixie) || latest='' ;;
      *)    latest=$(latest_version "$comp") || latest='' ;;
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
          local count expired revoked
          count=$(<"$WORK/sigcount")
          expired=$(<"$WORK/expired")
          revoked=$(<"$WORK/revoked")
          note="$pinned -> $latest  (${count} trusted sig"
          (( count == 1 )) || note+='s'
          note+=')'
          (( expired )) && note+='  [signing key EXPIRED]'
          (( revoked )) && note+='  [a signing key is REVOKED and was not counted]'
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
  validate "the version of $chain" "$version" "$VERSION_RE" || return 1
  validate "the checksum of $chain" "$sha" "$SHA256_RE" || return 1
  sed -i -e "s|^ARG ${upper}_VERSION=.*|ARG ${upper}_VERSION=${version}|" \
         -e "s|^ARG ${upper}_SHA256=.*|ARG ${upper}_SHA256=${sha}|" "$file"
  printf '  re-pinned %s to %s\n' "$chain" "$version"
}

repin_digest() {
  local var=$1 repo=$2 tag=$3 digest
  digest=$(latest_digest "$repo" "$tag")
  [[ -n $digest ]] || { printf 'Could not resolve %s:%s\n' "$repo" "$tag" >&2; return 1; }
  validate "the digest of $repo:$tag" "$digest" "$DIGEST_RE" || return 1
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
        validate 'the version of arti' "$latest" "$VERSION_RE" || return 1
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
  # exec replaces this process, so the EXIT trap never fires; the re-executed
  # copy makes a $WORK of its own.
  rm -rf -- "$WORK"
  WORK=''
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
    # Everything is about to be restarted anyway, which is the only safe moment
    # to rebuild the network underneath it.
    migrate_internal_network
    restart_all_services
  else
    for comp in "${comps[@]}"; do
      systemctl restart "${comp}.service"
      # monero-wallet-rpc runs the same image as monerod, and install_quadlets
      # has already repointed its unit at the new tag.  Without this it keeps
      # running the old container until something else restarts it, leaving a
      # spend-capable wallet on a different Monero build from the daemon it
      # talks to -- and doing so silently.
      if [[ $comp == monero ]]; then
        systemctl restart monero-wallet-rpc.service
      fi
    done
  fi

  # Confirm the chain daemons actually answered after the restart, so a failed
  # update is reported here rather than discovered later.  Only the ones this
  # run actually touched: waiting on a daemon nobody restarted would turn an
  # unrelated outage into a ten-minute hang.
  for comp in "${comps[@]}"; do
    case $comp in
      bitcoin)  wait_for_core_rpc bitcoin bitcoin-cli ;;
      litecoin) wait_for_core_rpc litecoin litecoin-cli ;;
      arti|base|rust)
        # These rebuild everything, so both Core daemons were restarted.
        wait_for_core_rpc bitcoin bitcoin-cli
        wait_for_core_rpc litecoin litecoin-cli
        break
        ;;
    esac
  done
  prune_old_images
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
