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

readonly COMPONENTS=(bitcoin litecoin monero arti base rust)
WORK=''
trap '[[ -n $WORK ]] && rm -rf -- "$WORK"' EXIT
# cmd_check's exit status.  Kept here rather than returned: under set -e a
# function returning non-zero ends the script through the error trap, which
# would announce a "stopped" run every time a component was merely unreachable.
CHECK_RC=0

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

Environment:
  UPDATE_CHECK_ROUTE     tor (default) or direct.  Every request --check and
                         --apply make goes through Arti's SOCKS proxy at
                         ${ARTI_SOCKS_HOST}:${ARTI_SOCKS_PORT}; if Arti cannot carry it, nothing is
                         fetched.  direct fetches from this host's own address,
                         as this script did before.  Unset, a run by hand
                         follows the daily timer's setting (setup.sh sets it).
                         Image builds still download over the clearnet.

Never prints wallet recovery material or RPC credentials; use
'setup.sh --print-details' for those.
USAGE
}

# How long a tor-routed run waits for Arti to be able to build a circuit.  The
# timer fires right at the end of setup.sh, which is also when Arti has just
# been restarted, and a cold Arti takes a few minutes to fetch a directory.
readonly TOR_WAIT_SECONDS=600
# Settled once per run by settle_route, before anything is fetched.
UPDATE_ROUTE=''
ROUTE_NONCE=''

settle_route() {
  # The environment wins; otherwise the route the timer's unit was given, so
  # `sudo ./update.sh --apply` by hand takes the same road as the daily check
  # on a host whose operator chose direct.  Default tor.  tail, because a
  # drop-in's Environment= line comes after the unit's own and is the one
  # systemd applies.
  local route=${UPDATE_CHECK_ROUTE:-} unit_env=''
  if [[ -z $route ]]; then
    unit_env=$(systemctl show -p Environment --value crypto-update-check.service 2>/dev/null) || unit_env=''
    route=$(grep -o 'UPDATE_CHECK_ROUTE=[^[:space:]]*' <<<"$unit_env" | tail -n 1) || route=''
    route=${route#UPDATE_CHECK_ROUTE=}
  fi
  route=${route:-tor}
  case $route in
    tor|direct) ;;
    *)
      printf 'UPDATE_CHECK_ROUTE must be tor or direct; got %q.  Nothing was fetched.\n' "$route" >&2
      exit 64
      ;;
  esac
  UPDATE_ROUTE=$route
  ROUTE_NONCE=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
}

route_curl() {
  # The only place this script calls curl, so that no request can leave by a
  # road the operator did not choose.  It refuses outright when no route has
  # been settled: a fetch added later that forgot to settle one must fail, not
  # quietly go direct.
  #
  # Over Tor, the SOCKS username is the destination host plus a per-run nonce.
  # Arti keeps streams with different credentials on different circuits, so
  # GitHub, crates.io and the download sites each see a different exit and no
  # one exit sees the whole pattern -- the same isolation Tor Browser gives
  # each site.  A failed request is tried once more under a new username, so
  # on a fresh circuit: an exit that refuses the port, or one whose shared
  # address has used up GitHub's anonymous API allowance (a 403), costs a
  # retry rather than an "unknown" row.  ROUTE_TRIES=1 turns that off.
  #
  # No custom User-Agent either way: a bundle-specific string would tag this
  # traffic as this deployment.  curl's default is generic and satisfies
  # GitHub's requirement that one be sent.
  local url='' arg host n rc=0 tries=${ROUTE_TRIES:-2}
  for arg; do
    case $arg in http://*|https://*) url=$arg ;; esac
  done
  case $UPDATE_ROUTE in
    direct)
      curl --max-time 60 "$@" </dev/null
      ;;
    tor)
      host=${url#*://}
      host=${host%%/*}
      for (( n = 1; n <= tries; n++ )); do
        rc=0
        curl --proxy "socks5h://${host:-none}-${ROUTE_NONCE}-${n}:x@${ARTI_SOCKS_HOST}:${ARTI_SOCKS_PORT}" \
          --max-time 120 "$@" </dev/null || rc=$?
        (( rc )) || return 0
      done
      return "$rc"
      ;;
    *)
      printf 'Refusing to fetch %s: no route was settled for this run.\n' "${url:-a URL}" >&2
      return 1
      ;;
  esac
}

fetch() { route_curl -fsSL "$@"; }

arti_listening() {
  timeout 5 bash -c "exec 3<>/dev/tcp/$ARTI_SOCKS_HOST/$ARTI_SOCKS_PORT" 2>/dev/null
}

tor_circuit() {
  # Any HTTP answer at all proves that Arti built a circuit and an exit
  # connected, which a listening SOCKS port does not: Arti accepts connections
  # long before it is bootstrapped, and simply holds each request until it is.
  # crates.io because it is asked anyway, so the probe adds no destination;
  # its front page because it is not a rate-limited API.  No -f: a 403 or a
  # 5xx from crates.io still proves the circuit.
  ROUTE_TRIES=1 route_curl -sS -o /dev/null --head --max-time 60 https://crates.io/
}

route_ready() {
  # Says which road this run's requests take, and for tor makes sure there is
  # one before anything is fetched.  Never falls back to direct: a check that
  # went to the clearnet whenever Arti was down would make the guarantee only
  # as good as Arti's uptime, and the operator could not tell which days.
  if [[ $UPDATE_ROUTE == direct ]]; then
    echo "Fetching directly, from this host's own address (UPDATE_CHECK_ROUTE=direct)."
    return 0
  fi
  local state err='' said=0 deadline=$(( SECONDS + TOR_WAIT_SECONDS ))
  local -r again='The daily timer tries again tomorrow; to try now: sudo systemctl start crypto-update-check.service'
  local -r instead="To fetch from this host's own address instead, set UPDATE_CHECK_ROUTE=direct (README, \"Applying security updates\")."
  if ! arti_listening; then
    state=$(systemctl is-active arti.service 2>/dev/null) || true
    if [[ $state == active ]]; then
      printf "Arti is running, but its SOCKS proxy at %s:%s does not answer from this host.\n" \
        "$ARTI_SOCKS_HOST" "$ARTI_SOCKS_PORT" >&2
      echo "The host reaches it through the crypto network's bridge: \`ip -br addr\` should" >&2
      echo 'show 10.89.0.1 on one of the podman bridges.' >&2
    else
      printf 'Arti is not running (arti.service is %s), so there is no way through Tor.\n' \
        "${state:-not installed}" >&2
    fi
    printf 'Nothing was fetched: this run goes through Tor and never falls back to the clearnet.\n%s\n%s\n' \
      "$again" "$instead" >&2
    return 1
  fi
  until err=$(tor_circuit 2>&1 >/dev/null); do
    if (( SECONDS >= deadline )); then
      printf 'Arti is listening but has not built a circuit in %d minutes%s.\n' \
        "$(( TOR_WAIT_SECONDS / 60 ))" "${err:+ (${err##*$'\n'})}" >&2
      echo 'Its own log says why: journalctl -u arti -n 50.  "No usable guards" there is the' >&2
      echo 'case in the README under "After an Arti update".' >&2
      printf 'Nothing was fetched: this run goes through Tor and never falls back to the clearnet.\n%s\n%s\n' \
        "$again" "$instead" >&2
      return 1
    fi
    if (( ! said )); then
      printf 'Waiting for Arti to build a circuit (up to %d minutes)...\n' "$(( TOR_WAIT_SECONDS / 60 ))"
      said=1
    fi
    sleep 30
  done
  printf 'Fetching through Tor, via Arti at %s:%s.\n' "$ARTI_SOCKS_HOST" "$ARTI_SOCKS_PORT"
}
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

version_newer() {
  # True only when $1 is a strictly later version than $2.  GitHub's "latest"
  # is whichever release was published last, and a maintenance release on an
  # older branch (a 30.x shipped after 31.0) is published later.  Compared with
  # plain inequality, as this used to be, that read as an UPDATE -- and --apply
  # would have re-pinned the node DOWN a major version.
  [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1) == "$1" ]]
}

pinned_keys()      { awk -v c="$1" '$1=="key" && $2==c {print toupper($3)}' "$FINGERPRINTS"; }
pinned_threshold() { awk -v c="$1" '$1=="threshold" && $2==c {print $3}' "$FINGERPRINTS"; }

# Import every pinned key, refusing anything whose primary fingerprint does not
# match.  The fetch is therefore untrusted: keys/fingerprints.txt is the anchor.
import_keys() {
  install -d -m 0700 "$KEYRING_DIR"
  # Keys already held are fetched again once a week.  Fetching each key only
  # the first time, as this used to, meant a revocation or a renewed expiry
  # date published upstream never reached this keyring: the REVKEYSIG handling
  # in verify_manifest could never fire, and a builder key past its original
  # expiry date would have been reported EXPIRED for good.  Merging a fresh
  # copy is safe for the same reason the first import is -- the primary
  # fingerprint must still match the pin, and gpg takes only components that
  # primary key signed.  A refresh that fails keeps the copy already held.
  local stamp=$KEYRING_DIR/refreshed refresh=0 stale=0 have
  if [[ ! -e $stamp || -n $(find "$stamp" -mmin +10080 2>/dev/null) ]]; then
    refresh=1
  fi
  local -a lines=()
  mapfile -t lines <"$FINGERPRINTS"
  local line kw chain fp url tmp=$WORK/key
  local -a got=()
  for line in "${lines[@]}"; do
    read -r kw chain fp url <<<"$line"
    [[ ${kw:-} == key ]] || continue
    fp=${fp^^}
    have=0
    if gpgr --list-keys "$fp" >/dev/null 2>&1; then
      have=1
      (( refresh )) || continue
    fi
    if ! fetch -o "$tmp" "$url" 2>/dev/null; then
      if (( have )); then stale=$((stale + 1)); continue; fi
      printf 'Could not fetch key %s from %s\n' "$fp" "$url" >&2
      return 1
    fi
    # gpgr, not bare gpg: the latter falls back to root's ~/.gnupg, which this
    # bundle deliberately never touches and which the update timer's sandbox
    # makes read-only.  show-only implies --dry-run, so nothing is imported yet.
    if ! gpgr --with-colons --import-options show-only --import "$tmp" >"$tmp.list" 2>/dev/null; then
      if (( have )); then stale=$((stale + 1)); continue; fi
      printf 'Could not read the key file fetched from %s\n' "$url" >&2
      return 1
    fi
    # Every primary fingerprint in the file, not just the first: the import
    # below takes the whole file, so checking only the first key would let an
    # unpinned one ride along behind a pinned one.
    mapfile -t got < <(awk -F: '$1=="pub"{p=1} $1=="fpr" && p {print toupper($10); p=0}' "$tmp.list")
    if (( ${#got[@]} != 1 )) || [[ ${got[0]} != "$fp" ]]; then
      printf 'Refusing key from %s: got %s, pinned %s\n' "$url" "${got[*]:-none}" "$fp" >&2
      if (( have )); then stale=$((stale + 1)); continue; fi
      return 1
    fi
    gpgr --import "$tmp" >/dev/null 2>&1
  done
  if (( refresh && ! stale )); then
    touch "$stamp"
  fi
  if (( stale )); then
    printf 'Could not refresh %d release key(s); verifying against the copies already held.\n' \
      "$stale" >&2
  fi
}

# Verify a chain's release manifest and echo the checksum of its x86_64 tarball.
# Prints nothing and fails if the signature threshold is not met, so a caller
# can never read a checksum out of an unverified document.
#
# Returns 1 when the release is refused, 3 when the manifest verified but does
# not list the tarball yet, and 4 when the manifest could not be downloaded.
# Callers run this in a command substitution, so why it failed is left in
# $WORK/why for them to read, along with the signature counts.
verify_manifest() {
  local chain=$1 version=$2
  local manifest=$WORK/manifest sig=$WORK/manifest.asc plain=$WORK/plain
  local status=$WORK/status tarball need good=0 fp
  # Reset every result first.  These files are the only way a caller learns
  # why a check failed, and one chain's leftovers -- an earlier signature
  # count, say -- must never be read as the next chain's.
  rm -f -- "$manifest" "$sig" "$plain"
  : >"$status"
  printf '0\n' >"$WORK/sigcount"
  printf '0\n' >"$WORK/expired"
  printf '0\n' >"$WORK/revoked"
  printf 'its release manifest could not be downloaded\n' >"$WORK/why"
  if ! validate "the version of $chain" "$version" "$VERSION_RE"; then
    printf 'upstream named a version that does not look like one\n' >"$WORK/why"
    return 1
  fi
  need=$(pinned_threshold "$chain")
  # An empty threshold would be arithmetic zero below, which reads as "no
  # signatures required" -- exactly backwards for a missing trust anchor.
  if [[ ! $need =~ ^[1-9][0-9]*$ ]]; then
    printf 'keys/fingerprints.txt has no usable threshold for it\n' >"$WORK/why"
    printf 'refusing %s: no usable threshold for it in %s\n' "$chain" "$FINGERPRINTS" >&2
    return 1
  fi

  case $chain in
    bitcoin)
      tarball="bitcoin-${version}-x86_64-linux-gnu.tar.gz"
      fetch -o "$manifest" "https://bitcoincore.org/bin/bitcoin-core-${version}/SHA256SUMS" || return 4
      fetch -o "$sig" "https://bitcoincore.org/bin/bitcoin-core-${version}/SHA256SUMS.asc" || return 4
      gpgr --status-fd 3 --verify "$sig" "$manifest" 3>"$status" >/dev/null 2>&1 || true
      cp "$manifest" "$plain"
      ;;
    litecoin)
      tarball="litecoin-${version}-x86_64-linux-gnu.tar.gz"
      fetch -o "$manifest" \
        "https://github.com/litecoin-project/litecoin/releases/download/v${version}/SHA256SUMS.asc" || return 4
      # --decrypt emits only the signed body, so text smuggled outside the
      # clearsigned block cannot reach the checksum lookup below.
      gpgr --status-fd 3 --output "$plain" --decrypt "$manifest" 3>"$status" >/dev/null 2>&1 || true
      ;;
    monero)
      tarball="monero-linux-x64-v${version}.tar.bz2"
      fetch -o "$manifest" 'https://www.getmonero.org/downloads/hashes.txt' || return 4
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
  printf '%s\n' "$good" >"$WORK/sigcount"
  if grep -q '^\[GNUPG:\] EXPKEYSIG' "$status"; then
    printf '1\n' >"$WORK/expired"
  fi
  if grep -q '^\[GNUPG:\] REVKEYSIG' "$status"; then
    printf '1\n' >"$WORK/revoked"
  fi
  if (( good < need )); then
    printf 'only %d of the %d required trusted signatures\n' "$good" "$need" >"$WORK/why"
    printf 'refusing %s %s: %d trusted signature(s), need %d\n' \
      "$chain" "$version" "$good" "$need" >&2
    return 1
  fi
  # A signed manifest that does not list the tarball is not a signature
  # failure.  It is what Monero's hashes.txt -- which covers one release only --
  # looks like between a release appearing on GitHub and the site being
  # updated, and it used to be reported as BLOCKED, "signature check failed".
  if ! awk -v t="$tarball" '$2 == t {print $1; found=1} END {exit !found}' "$plain"; then
    printf 'its checksum is not in the signed manifest yet\n' >"$WORK/why"
    printf 'refusing %s %s: the signed manifest does not list %s yet\n' \
      "$chain" "$version" "$tarball" >&2
    return 3
  fi
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
  route_curl -fsSI -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.oci.image.index.v1+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
    "https://registry-1.docker.io/v2/${repo}/manifests/${tag}" |
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

image_for() {
  case $1 in
    bitcoin)  printf '%s\n' "$BITCOIN_IMAGE" ;;
    litecoin) printf '%s\n' "$LITECOIN_IMAGE" ;;
    monero)   printf '%s\n' "$MONERO_IMAGE" ;;
  esac
}

report() { printf '  %-9s %-12s %s\n' "$1" "$2" "$3"; }

cmd_check() {
  local comp pinned latest sha note why pattern rc updates=0
  settle_route
  # 75 (EX_TEMPFAIL), apart from the 1 a finished check exits with when it has
  # something to report: nothing was checked, and nothing is known to be wrong
  # with any component -- only that there was no road to ask by.
  if ! route_ready; then
    CHECK_RC=75
    return 0
  fi
  # Non-fatal, for the same reason the per-component fetches below are: all the
  # key URLs share one host, and an outage there must not cost the whole report.
  # Chains whose keys are missing then report BLOCKED, with this line above.
  if ! import_keys; then
    printf 'Some release keys could not be fetched; chain checks may report BLOCKED.\n' >&2
    CHECK_RC=1
  fi
  printf '\nComponent  Status       Detail\n'
  printf -- '---------------------------------------------------------------\n'
  for comp in "${COMPONENTS[@]}"; do
    pinned=$(pinned_version "$comp")
    # Each probe's stderr is kept for its own row rather than printed: curl's
    # complaints used to land in the middle of the table, above the row they
    # belonged to.
    : >"$WORK/err"
    case $comp in
      # Clear rather than `|| true`: latest is declared once outside the loop,
      # so a partial transfer must not leave a stale value to be read as a
      # bogus 'current' row for the next component.
      base) latest=$(latest_digest library/debian trixie-slim 2>"$WORK/err") || latest='' ;;
      rust) latest=$(latest_digest library/rust 1-trixie 2>"$WORK/err") || latest='' ;;
      *)    latest=$(latest_version "$comp" 2>"$WORK/err") || latest='' ;;
    esac
    if [[ -z $latest || $latest == null ]]; then
      why=$(tail -n 1 "$WORK/err")
      report "$comp" 'unknown' "could not reach upstream${why:+ ($why)}"
      CHECK_RC=1
      continue
    fi
    case $comp in base|rust) pattern=$DIGEST_RE ;; *) pattern=$VERSION_RE ;; esac
    if [[ ! $latest =~ $pattern ]]; then
      report "$comp" 'unknown' 'upstream answered with something that is not a version'
      CHECK_RC=1
      continue
    fi
    if [[ $pinned == "$latest" ]]; then
      report "$comp" 'current' "$pinned"
      continue
    fi
    case $comp in
      bitcoin|litecoin|monero|arti)
        if ! version_newer "$latest" "$pinned"; then
          report "$comp" 'current' "$pinned  (upstream's latest release is the older $latest)"
          continue
        fi
        ;;
    esac
    case $comp in
      bitcoin|litecoin|monero)
        rc=0
        sha=$(verify_manifest "$comp" "$latest" 2>/dev/null) || rc=$?
        if (( rc == 0 )); then
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
          updates=$((updates + 1))
        elif (( rc == 3 )); then
          # Not a failure: the release exists and nothing about it is wrong;
          # there is just nothing verified to apply yet.  The next run will see it.
          report "$comp" 'pending' "$latest is out; $(<"$WORK/why")"
        elif (( rc == 4 )); then
          report "$comp" 'unknown' "$latest is out, but $(<"$WORK/why")"
          CHECK_RC=1
        else
          report "$comp" 'BLOCKED' "$latest: $(<"$WORK/why")"
          CHECK_RC=1
        fi
        ;;
      *)
        report "$comp" 'UPDATE' "$pinned -> $latest"
        updates=$((updates + 1))
        ;;
    esac
  done
  printf -- '---------------------------------------------------------------\n'
  # Free space is checked once at install and then never again, but the failure
  # it guards against -- a full disk during sync, which is what can damage
  # Monero's database -- arrives months later.  This runs daily and is already
  # somewhere an operator looks, so report it here.
  local avail
  avail=$(df -BG --output=avail "$DATA_DIR" 2>/dev/null | tail -1 | tr -dc '0-9') || avail=''
  if [[ -z $avail ]]; then
    report 'disk' 'unknown' "could not read free space on $DATA_DIR"
    CHECK_RC=1
  elif (( avail < 25 )); then
    report 'disk' 'LOW' "${avail} GiB free on $DATA_DIR -- a full disk can damage Monero's LMDB"
    CHECK_RC=1
  else
    report 'disk' 'ok' "${avail} GiB free on $DATA_DIR"
  fi
  printf -- '---------------------------------------------------------------\n'
  # Only when there is something to apply; printed under an all-current table
  # it read as an instruction with nothing to act on.
  if (( updates )); then
    printf 'Apply with: sudo ./update.sh --apply <component>\n'
  fi
  printf '\n'
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
  # sed reports success when its pattern matched nothing, so confirm the pins
  # actually changed rather than trusting the exit status.  A Containerfile that
  # has been reshaped by hand would otherwise be rebuilt at its old version.
  if ! grep -qxF "ARG ${upper}_VERSION=${version}" "$file" ||
     ! grep -qxF "ARG ${upper}_SHA256=${sha}" "$file"; then
    printf 'Failed to re-pin %s in %s; its ARG lines are not where expected.\n' \
      "$chain" "$file" >&2
    return 1
  fi
  printf '  re-pinned %s to %s\n' "$chain" "$version"
}

# Returns 2, distinctly from an error, when the digest has not moved.
repin_digest() {
  local var=$1 repo=$2 tag=$3 comp=$4 digest line
  digest=$(latest_digest "$repo" "$tag")
  [[ -n $digest ]] || { printf 'Could not resolve %s:%s\n' "$repo" "$tag" >&2; return 1; }
  validate "the digest of $repo:$tag" "$digest" "$DIGEST_RE" || return 1
  # Safe to read the in-memory pin: lib.sh was sourced before anything rewrote it.
  if [[ $digest == "$(pinned_version "$comp")" ]]; then
    return 2
  fi
  line="readonly ${var}='docker.io/${repo}@${digest}'"
  sed -i "s|^readonly ${var}=.*|${line}|" "$BUNDLE_DIR/lib.sh"
  grep -qxF "$line" "$BUNDLE_DIR/lib.sh" || {
    printf 'Failed to re-pin %s in lib.sh; its declaration is not where expected.\n' \
      "$var" >&2
    return 1
  }
  printf '  re-pinned %s to %s\n' "$var" "$digest"
}

pinned_not_deployed() {
  # True, with a line saying so, when the pin for a component is not what this
  # host runs.  A run that re-pinned a component and then stopped before
  # deploying it -- a failed build, a dropped connection -- used to make the
  # next --apply say "already current" and rebuild nothing, because it compared
  # upstream only with the pin it had itself just written.  images.env records
  # what the units actually point at.
  local comp=$1 var want have
  case $comp in
    bitcoin|litecoin|monero) var=${comp^^}_IMAGE; want=$(image_for "$comp") ;;
    arti) var=ARTI_IMAGE; want=$ARTI_IMAGE ;;
    base) var=BASE_IMAGE; want=$BASE_IMAGE ;;
    rust) var=ARTI_RUST_IMAGE; want=$ARTI_RUST_IMAGE ;;
  esac
  have=$(deployed_value "$var")
  [[ -n $have && $have != "$want" ]] || return 1
  printf '  %s is pinned at %s, but this host still runs %s; deploying the pin.\n' \
    "$comp" "${want##*[:@]}" "${have##*[:@]}"
}

check_base_drift() {
  # Refuses a rebuild that would quietly put some images on a different base
  # from the rest.  A base given at install time (BASE_IMAGE=... ./setup.sh) is
  # remembered only in images.env, so an --apply bitcoin months later used to
  # rebuild bitcoin on the bundle's own pin instead, with nothing said, leaving
  # one image on the operator's reviewed base and three on another.
  #   $1   the command to suggest re-running, e.g. "--apply bitcoin"
  #   $2.. the components being rebuilt
  local again=$1; shift
  local comp arti=0 base=0 rust=0 recorded var given current
  for comp in "$@"; do
    case $comp in
      base) base=1; arti=1 ;;
      rust) rust=1; arti=1 ;;
      arti) arti=1 ;;
    esac
  done
  for var in BASE_IMAGE ARTI_RUST_IMAGE; do
    case $var in
      BASE_IMAGE)      (( ! base )) || continue; given=$BASE_GIVEN; current=$BASE_IMAGE ;;
      ARTI_RUST_IMAGE) (( arti && ! rust )) || continue; given=$RUST_GIVEN; current=$ARTI_RUST_IMAGE ;;
    esac
    [[ -z $given ]] || continue
    recorded=$(deployed_value "$var")
    [[ -n $recorded && $recorded != "$current" ]] || continue
    cat <<DRIFT >&2
This host's images were built with
  $var=$recorded
(recorded in $PREFIX/images.env), but this run would use
  $var=$current
Rebuilding only some of them would leave the deployment on two different
images.  Either keep the one this host runs:
  sudo $var='$recorded' ./update.sh $again
or move everything to the bundle's pin:
  sudo ./update.sh --redeploy
Nothing was rebuilt.
DRIFT
    exit 1
  done
}

refuse_apply() {
  # Arguments: the components already re-pinned by this run, if any.  Their
  # Containerfiles now name the new release, so say plainly that it has not
  # been deployed -- and that re-running deploys it (see pinned_not_deployed).
  if (( $# )); then
    printf 'Re-pinned but not deployed: %s.  Running the same command again deploys\n' "$*" >&2
    printf 'that once the problem above is resolved.\n' >&2
  else
    printf 'Nothing was changed.\n' >&2
  fi
  exit 1
}

cmd_apply() {
  local comp latest pinned sha file rc
  # Only what actually moved is redeployed.  Naming a component that turns out
  # to be current used to rebuild and restart it anyway, which is a needless
  # outage on a daemon that handles money.
  local -a changed=()
  # Every name is checked before anything is touched, so a typo in the last
  # argument cannot leave the first ones re-pinned and undeployed.
  for comp in "$@"; do
    case $comp in
      bitcoin|litecoin|monero|arti|base|rust) ;;
      *) printf 'Unknown component: %s (components: %s)\n' "$comp" "${COMPONENTS[*]}" >&2; exit 64 ;;
    esac
  done
  # Effective bases, as the rebuild will see them; set before the drift check
  # and pinned_not_deployed read them.
  BASE_GIVEN=${BASE_IMAGE:+1}
  RUST_GIVEN=${ARTI_RUST_IMAGE:+1}
  resolve_base_images
  check_base_drift "--apply $*" "$@"
  # Applying asks the same upstreams the check does, so it takes the same road.
  # The rebuild it hands over to downloads over the clearnet; see the README.
  settle_route
  route_ready || refuse_apply
  import_keys || refuse_apply
  for comp in "$@"; do
    case $comp in
      bitcoin|litecoin|monero|arti)
        pinned=$(pinned_version "$comp")
        latest=$(latest_version "$comp") || latest=''
        if [[ -z $latest || $latest == null ]]; then
          printf 'Could not ask upstream for the latest %s release.\n' "$comp" >&2
          refuse_apply "${changed[@]}"
        fi
        validate "the version of $comp" "$latest" "$VERSION_RE" || refuse_apply "${changed[@]}"
        if version_newer "$latest" "$pinned"; then
          if [[ $comp == arti ]]; then
            file="$BUNDLE_DIR/containers/arti.Containerfile"
            sed -i "s|^ARG ARTI_VERSION=.*|ARG ARTI_VERSION=${latest}|" "$file"
            grep -qxF "ARG ARTI_VERSION=${latest}" "$file" || {
              printf 'Failed to re-pin arti in %s; its ARG line is not where expected.\n' \
                "$file" >&2
              refuse_apply "${changed[@]}"
            }
            printf '  re-pinned arti to %s\n' "$latest"
          else
            sha=$(verify_manifest "$comp" "$latest") || refuse_apply "${changed[@]}"
            repin_chain "$comp" "$latest" "$sha" || refuse_apply "${changed[@]}"
          fi
          changed+=("$comp")
        elif pinned_not_deployed "$comp"; then
          changed+=("$comp")
        else
          printf '  %s already current (%s)\n' "$comp" "$pinned"
        fi
        ;;
      base|rust)
        rc=0
        case $comp in
          base) repin_digest DEFAULT_BASE_IMAGE library/debian trixie-slim base || rc=$? ;;
          rust) repin_digest DEFAULT_ARTI_RUST_IMAGE library/rust 1-trixie rust || rc=$? ;;
        esac
        # 2 means the digest had not moved; anything else non-zero is an error.
        if (( rc == 0 )); then
          changed+=("$comp")
        elif (( rc != 2 )); then
          refuse_apply "${changed[@]}"
        elif pinned_not_deployed "$comp"; then
          changed+=("$comp")
        else
          printf '  %s already current\n' "$comp"
        fi
        ;;
    esac
  done
  if (( ${#changed[@]} == 0 )); then
    printf '\nEvery component named was already current; nothing rebuilt.\n'
    return 0
  fi
  # Re-exec so lib.sh re-reads the pins just rewritten; otherwise the rebuild
  # would tag images with the versions this process started with.
  printf '\nRebuilding from the new pins...\n'
  # exec replaces this process, so the EXIT trap never fires; the re-executed
  # copy makes a $WORK of its own.
  rm -rf -- "$WORK"
  WORK=''
  # Through bash rather than relying on the file's execute bit, which a copy of
  # the bundle does not always keep -- `sudo bash update.sh` would otherwise get
  # as far as re-pinning and then fail here with "Permission denied".
  exec bash "$BUNDLE_DIR/update.sh" --redeploy "${changed[@]}"
}

cmd_redeploy() {
  local -a comps=("$@")
  (( ${#comps[@]} )) || comps=("${COMPONENTS[@]}")
  BASE_GIVEN=${BASE_IMAGE:+1}
  RUST_GIVEN=${ARTI_RUST_IMAGE:+1}
  resolve_base_images
  local comp all=0 arti=0 prev_arti
  local -A wanted=()
  for comp in "${comps[@]}"; do
    case $comp in
      # The base image is under every image, so it is the one component that
      # really does mean rebuilding and restarting everything.
      base) all=1 ;;
      # Arti and the Rust image it is compiled with touch Arti alone.  These
      # used to rebuild and restart all five services as well -- both Core
      # nodes and the Monero wallet included -- for a change none of them can
      # see: the chains carry Wants=arti.service, not Requires=, precisely so
      # that an Arti restart leaves them running.
      arti|rust) arti=1 ;;
      bitcoin|litecoin|monero) wanted[$comp]=1 ;;
      *) printf 'Unknown component: %s (components: %s)\n' "$comp" "${COMPONENTS[*]}" >&2; exit 64 ;;
    esac
  done
  local -a chains=()
  if (( all )); then
    arti=1
    chains=(bitcoin litecoin monero)
  else
    for comp in bitcoin litecoin monero; do
      if [[ -n ${wanted[$comp]:-} ]]; then chains+=("$comp"); fi
    done
  fi
  check_base_drift "--redeploy ${comps[*]}" "${comps[@]}"
  prev_arti=$(deployed_value ARTI_IMAGE)

  remember_bundle_images
  if (( arti )); then
    build_arti_image
  fi
  for comp in "${chains[@]}"; do
    build_daemon_image "$comp" "$(image_for "$comp")"
  done

  install_quadlets
  write_images_env

  if (( all )); then
    # Everything is about to be restarted anyway, which is the only safe moment
    # to rebuild the network underneath it.
    migrate_internal_network
    restart_all_services
  else
    local -a units=()
    if (( arti )); then units+=(arti.service); fi
    for comp in "${chains[@]}"; do
      units+=("${comp}.service")
      # monero-wallet-rpc runs the same image as monerod, and install_quadlets
      # has already repointed its unit at the new tag.  Its Requires= would
      # restart it along with monerod anyway; naming it puts both in one
      # transaction, so it restarts once and the intent is on the page.
      if [[ $comp == monero ]]; then units+=(monero-wallet-rpc.service); fi
    done
    systemctl restart "${units[@]}"
  fi

  # Confirm each restarted service is actually answering, so a failed update is
  # reported here rather than discovered later.  Only the ones this run
  # touched: waiting on a daemon nobody restarted would turn an unrelated
  # outage into a ten-minute hang.
  local -a touched=()
  if (( arti )); then touched+=(arti); fi
  touched+=("${chains[@]}")
  wait_for_services "${touched[@]}"
  remove_superseded_images
  printf 'Update complete.  Deployed images:\n'
  sed 's/^/  /' "$PREFIX/images.env"
  if (( arti )) && [[ -n $prev_arti && $prev_arti != "$ARTI_IMAGE" ]]; then
    # Listening is all the wait above proves.  The failure worth knowing about
    # after a version change is the one the README describes: a new Arti
    # reading the old one's guard state and building no circuits at all.
    cat <<'ARTI'

Arti is listening on the new version.  Its SOCKS port answering does not prove
it can build circuits: watch the chains' peer counts for the next few minutes,
and if they fall to zero, see "After an Arti update" in the README.
ARTI
  fi
}

# Sourcing this file (a test harness does) defines the functions and stops.
[[ ${BASH_SOURCE[0]} == "$0" ]] || return 0

WORK=$(mktemp -d)

case ${1:-} in
  -h|--help) usage; exit 0 ;;
  --check)    require_root; shift; cmd_check; exit "$CHECK_RC" ;;
  --apply)    require_root; shift; (( $# )) || { echo 'Name at least one component.' >&2; exit 64; }; cmd_apply "$@" ;;
  --redeploy) require_root; shift; cmd_redeploy "$@" ;;
  '')  usage >&2; exit 64 ;;
  *)   printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 64 ;;
esac
