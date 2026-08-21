# Bitcoin, Litecoin, Monero over Arti / Tor

This bundle deploys three full nodes, encrypted default wallets, and
authenticated v3 onion-service RPC endpoints. No TCP port is published on the
Debian host. Podman Quadlet keeps the five containers under systemd.

Bitcoin and Monero reach the network **only over Tor**, and that is enforced by
the container network rather than by their own config files. There are two
Podman networks:

| Network | Members | Route to the internet |
|---|---|---|
| `crypto` | Arti, Bitcoin, Monero, Monero wallet RPC | none — `--internal --disable-dns` |
| `crypto-egress` | Arti, Litecoin | yes |

Arti is on both, and is the only way anything on `crypto` reaches the outside
world. A daemon there cannot open a clearnet connection or resolve a hostname
even if its configuration told it to, so a bad `onlynet` line or a DNS seed
lookup fails closed instead of leaking.

Litecoin is the exception and peers over the clearnet: Tor exit relays reject
port 9333, and the three onion addresses compiled into Litecoin Core are
unreachable, so an onion-only Litecoin node never finds a peer and never syncs.
It therefore lives on `crypto-egress` with Arti. All four RPC endpoints,
Litecoin's included, are reachable only through an authenticated onion service.

**Upgrading an existing install:** `podman network create --ignore` leaves an
already-existing network exactly as it was, so a host set up before this change
would keep a `crypto` network that still has egress and DNS — with nothing to
say the hardening had not applied. `setup.sh` and `update.sh --redeploy` both
check the live network's flags and rebuild it when they do not match, which
stops the daemons briefly. They refuse to continue if something is still
attached to the old network, rather than leave you looking hardened while
Bitcoin and Monero still have a route out. To check by hand:

```bash
sudo podman network inspect crypto --format 'internal={{.Internal}} dns={{.DNSEnabled}}'
```

All three chains are pruned. Bitcoin Core and Litecoin Core use a 10000 MiB
(~10 GB) automatic block/undo target, and Monero uses pruned-block sync. They
still fully validate the chain, but cannot provide old blocks, historical
transaction lookups, or full initial-sync service to other peers.

That target is deliberately well above Core's 550 MiB minimum. The prune depth
is exactly the depth a wallet rescan can reach, so 550 MiB would leave the
captured recovery material (see "Wallet recovery material") restorable only
against roughly a day of chain. 10 GB buys about a month on Bitcoin and several
months on Litecoin, for about 19 GB of extra disk across the two.

## Before installing

1. Use a fresh, supported Debian 13 host with enough fast, redundant storage.
   Podman 5.0 or later is expected — Debian 13 ships 5.4, and that is what this
   bundle is tested against. `setup.sh` warns on anything older rather than
   refusing; the Quadlet syntax used here does still convert on Podman 4.9.
   As configured, budget roughly 150 GB and grow from there: about 22 GB for
   Bitcoin (10 GB of blocks plus chainstate), about 13 GB for Litecoin, and
   about 60 GB for pruned Monero, which is by far the largest consumer. A
   non-pruned Bitcoin node would instead need hundreds of GB. `setup.sh` refuses
   to start below that budget, checking both the chain-data filesystem and
   podman's image store, which are often not the same one; set `MIN_FREE_GIB`
   to lower the chain-data figure deliberately. A disk that fills during initial
   sync is the one failure here that can leave Monero's database damaged.
2. Review the two pinned build base images, or replace them with your own.
   `setup.sh` ships a reviewed, digest-pinned default for each, so a clean
   checkout installs with no arguments.  Overriding is still allowed, but the
   bundle refuses mutable tags in either case: these daemons validate money, so
   image provenance is a security boundary.  Run `./setup.sh --help` for the
   exact variables, and see "Verifying or refreshing the build bases" below.
3. This is a **hot-wallet** deployment: the server generates and holds spend
   keys for default BTC, LTC, and XMR wallets. Fund it only with an amount you
   can accept losing if the server is compromised. Use an external signer or a
   watch-only wallet for material balances.

## Install

Copy this directory to the server and run:

```bash
sudo ./setup.sh
```

That is the whole install.  It is idempotent, so re-running it after a change
or a failed attempt is safe.  It asks one optional question (whether to install
Podman Desktop, default no); set `INSTALL_PODMAN_DESKTOP=no` to skip even that
and run completely unattended.

A re-run reinstalls `bitcoin.conf`, `litecoin.conf` and `monero.conf` from this
bundle, so hand edits to those (a changed `prune`, for example) do not survive
one. `arti.toml` is the exception and is installed only once: reverting it would
silently turn restricted discovery back off in front of a spend-capable wallet.
A re-run prints a diff when the installed copy has drifted from the bundle's.
That cuts both ways — a change to `arti.toml` in a future version of this bundle
will not reach an existing install on its own; merge it from that diff.

Three scripts make up the bundle: `setup.sh` installs, `update.sh` maintains
(see "Applying security updates"), and `lib.sh` holds what they share — the
pins, the image build steps, and the Quadlet install.  `lib.sh` is sourced, not
run. `check.sh` runs `bash -n` over all four and then `shellcheck -x`, failing
if shellcheck is absent — `bash -n` alone finds parse errors and nothing else,
so it is not a lint gate on its own; `ALLOW_NO_SHELLCHECK=1` gives a syntax-only
run. It is for whoever edits the bundle; no deployed host needs it.

Expect it to take a while: it compiles arti from source and downloads three
daemon release tarballs before the nodes ever start syncing.

To build against your own reviewed bases instead of the shipped pins:

```bash
sudo BASE_IMAGE='docker.io/library/debian@sha256:...' ARTI_RUST_IMAGE='docker.io/library/rust@sha256:...' ./setup.sh
```

### Verifying or refreshing the build bases

The defaults in `lib.sh` are the `docker.io/library/debian:trixie-slim` and
`docker.io/library/rust:1-trixie` indexes as resolved on 2026-08-20.  Both are
Debian 13, which matches the host this bundle targets and keeps the glibc of
the image that compiles arti in step with the image that runs it.

`sudo ./update.sh --check` reports whether either digest has moved, and
`sudo ./update.sh --apply base` (or `rust`) moves the pin and rebuilds.  To
confirm a pin independently of this bundle's own tooling, ask the registry
yourself:

```bash
repo=library/debian; tag=trixie-slim; tok=$(curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p'); curl -fsSI -H "Authorization: Bearer $tok" -H 'Accept: application/vnd.oci.image.index.v1+json' -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' "https://registry-1.docker.io/v2/${repo}/manifests/${tag}" | tr -d '\r' | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: //p'
```

Moving a pin by hand is a deliberate act: read what changed in the base first,
then edit `DEFAULT_BASE_IMAGE` / `DEFAULT_ARTI_RUST_IMAGE` in `lib.sh`, update
the date in the comment above them, and run `sudo ./update.sh --redeploy`.

## Where the binaries come from

No third-party daemon image is used. `setup.sh` builds every image locally:
Bitcoin Core, Litecoin Core and Monero come from each project's own official
release tarball, and Arti is compiled from the pinned `arti` crate. The only
images pulled from a registry are the two build bases above, which is why they
are digest-pinned rather than tagged.

Each `containers/*.Containerfile` pins the SHA256 of the release tarball it
downloads and fails the build if the download does not match. Those checksums
were taken from signed upstream manifests and verified against the projects'
own keys:

| Chain | Version | Manifest | Signature checked against |
|---|---|---|---|
| Bitcoin Core | 31.1 | `bitcoincore.org` `SHA256SUMS.asc` | 4 Guix builder keys from `bitcoin-core/guix.sigs` |
| Monero | 0.18.5.1 | `getmonero.org` `hashes.txt` | binaryFate `81AC 591F E9C4 B65C 5806 AFC3 F0AF 4D46 2A0B DF92` |
| Litecoin Core | 0.21.5.6 | GitHub release `SHA256SUMS.asc` | David Burkett `D356 21D5 3A1C C6A3 4567 58D0 3620 E9D3 87E5 5666` |

**Litecoin caveat:** its manifest carries exactly one signature, and that
signing key is expired. The signature is cryptographically valid and the key
ships in Litecoin's own repository, but this is weaker provenance than Bitcoin's
multi-signer Guix attestations or Monero's current release key. Re-verify it
yourself before trusting the Litecoin node with funds.

To re-verify a pinned checksum, fetch the upstream manifest and its key, run
`gpg --verify`, and compare the hash with the `ARG *_SHA256` line in the
corresponding Containerfile. Changing a version means updating both the version
and its checksum together.

Those digests are the images this bundle was tested against: Bitcoin Core
31.1, Litecoin Core 0.21.5.6, and Monero 0.18.5.1 — the versions in the table
above and in `containers/*.Containerfile`, which are the only places a version
is declared. Review them yourself before trusting them with funds. If you substitute others, note that the
Quadlets bypass each image's entrypoint and invoke `bitcoind`, `litecoind`,
`monerod`, and `monero-wallet-rpc` directly, so the replacement must ship those
binaries; the Monero image must provide `monero-wallet-cli` and
`monero-wallet-rpc` as well as `monerod`.

The script is idempotent: rerunning it preserves data, RPC credentials, and
Arti onion-service keys. It builds `localhost/crypto-arti` from the pinned
`arti` crate with onion-service support, tagged with the version in
`containers/arti.Containerfile`, installs Quadlets into
`/etc/containers/systemd`, creates encrypted default wallets once, then
restarts `arti`, `bitcoin`, `litecoin`, `monero`, and `monero-wallet-rpc` so a
rerun adopts any image it just rebuilt.

During an interactive run it asks whether to install Podman Desktop through
Flathub for the login that invoked `sudo`; choose **No** on a headless server.
For noninteractive use, set `INSTALL_PODMAN_DESKTOP=yes` and (when needed)
`PODMAN_DESKTOP_USER=<desktop-login>`.

When it finishes, the script prints everything needed to point an application
at these nodes: each onion address and port, the RPC username and password, the
authentication scheme, the wallet names, the wallet passphrases, and the default
receive addresses. The same text is saved to
`/etc/crypto-daemons/secrets/connection-details.txt` (mode 0600).

To print it again later without reinstalling:

```bash
sudo ./setup.sh --print-details
```

## Applying security updates

`setup.sh` installs; `update.sh` maintains. They are separate entry points on
purpose: `setup.sh` prints wallet recovery material every time it runs, which is
correct once at install time and wrong as a routine patching step. `update.sh`
never prints spend keys or RPC credentials — it cannot, since those functions
live in `setup.sh` — so it is safe to run where output is captured, including
from a timer whose stdout lands in the journal.

### Checking

```bash
sudo ./update.sh --check
```

Read-only. For each component it reports the pinned version against what
upstream currently offers, and for the three daemons it downloads the release
manifest and verifies its signatures before showing you the checksum:

```
  bitcoin   UPDATE       31.1 -> 31.2  (11 trusted sigs)
                         sha256:b80d9c3e04da78fb6f0569685673418cf686fadba9042d926d13fb87ff503f9e
  litecoin  current      0.21.5.6
  monero    current      0.18.5.1
  arti      current      2.5.1
  base      UPDATE       sha256:3a39a05… -> sha256:9c1e77b…
```

A release whose signature does not meet the threshold is reported `BLOCKED` and
its checksum is never printed, so an unverified hash cannot be copied into a pin
by hand either.

### Applying

```bash
sudo ./update.sh --apply bitcoin
```

Re-verifies, rewrites the version and checksum in the Containerfile, rebuilds
only what that component affects, restarts it, and waits for the daemon to
answer RPC again before reporting success. Components are `bitcoin`,
`litecoin`, `monero`, `arti`, `base` and `rust`; name more than one to do
several at once. There is deliberately no "apply everything" flag — see below.

Only components that actually moved are rebuilt and restarted; naming one that
turns out to be current reports it and leaves it running.

`sudo ./update.sh --redeploy` rebuilds and restarts from the pins exactly as
they stand, without consulting upstream. Use it after editing a Containerfile
by hand.

### How releases are trusted

`keys/fingerprints.txt` is the trust anchor: it lists the primary-key
fingerprint of every signer this bundle accepts, and how many must agree.
Key material itself is fetched from the projects' own repositories at check
time, but nothing is imported unless its fingerprint already appears in that
file, so the download does not have to be trusted — only the list, which is
reviewable in git. Keys go into a keyring under `/etc/crypto-daemons/keys`
rather than root's, so verifying a release never widens what the rest of the
system trusts.

Bitcoin Core requires four independent Guix builder signatures; Monero and
Litecoin publish one signature each. Litecoin's signing key is expired, and
`--check` prints `[signing key EXPIRED]` on every report rather than hiding it.
A *revoked* key is different: it is not counted toward the threshold at all, and
`--check` says so. One Bitcoin builder rotating a key therefore costs one
signature out of eleven rather than blocking the release.

Fingerprints are primary keys, not subkeys: several Bitcoin builders sign with
subkeys, and pinning one would break the moment it is rotated.

### What to automate, and what not to

`--check` is safe to run on a timer, and `setup.sh` installs one:
`crypto-update-check.timer` runs it daily with up to four hours of jitter, and
`Persistent=true` so a missed day is caught up rather than skipped.

```bash
systemctl list-timers crypto-update-check.timer
journalctl -u crypto-update-check.service
```

`setup.sh` enables the timer as its last step, and because `Persistent=true`
has no stamp file to read on a fresh install, the first check runs right then.
The unit records the path the bundle was installed from, so moving the bundle
breaks the timer — rerun `setup.sh` from the new location to repoint it. A
non-zero exit is deliberate signal rather than noise: it means a component was
unreachable, or that a new release failed its signature threshold and was
reported `BLOCKED`. Both show up in `systemctl --failed`.

Applying is a different question per component:

- **`base` and `rust`, plus host packages** — reasonable to apply on a schedule.
  This is where most CVEs are, the blast radius of a bad one is small, and it is
  the same class of change as `apt upgrade` on any other host.
- **`bitcoin`, `litecoin`, `monero`, `arti`** — apply deliberately. Signature
  checking is automatic and reliable, but consensus code can need a reindex or a
  migration, and an unattended restart that fails leaves a hot wallet down with
  nobody watching. Read the release notes.

One caveat specific to the container userland: while the base digest is
unchanged, the `apt-get` layers stay cached and a rebuild pulls in no package
updates. Patches for glibc, openssl and friends arrive only when the base pin
moves, which invalidates every layer beneath it. `--check` reports when that
digest has moved; treat it with the same urgency as Debian security updates on
a normal host.

The host itself is not managed here at all. `setup.sh` installs podman and its
dependencies but configures no `unattended-upgrades` and no timer. A rootful
podman vulnerability is a container-escape path on a machine holding spend keys,
so keep the host patched by whatever means you already trust.

## Wallet recovery material

After creating the wallets, `setup.sh` also prints and saves the material needed
to restore them, to `/etc/crypto-daemons/secrets/wallet-recovery.txt` (0600):

```bash
sudo ./setup.sh --print-recovery
```

**Only Monero has a mnemonic.** Bitcoin Core and Litecoin Core have never used
BIP39 seed phrases, so there is no 25-word backup to print for them. What the
script captures instead is the real equivalent:

| Chain | Recovery material | Saved to |
|---|---|---|
| Monero | 25-word mnemonic | `monero-default-wallet-recovery.txt` |
| Bitcoin | descriptors, each carrying the master private key | `bitcoin-wallet-descriptors.json` |
| Litecoin | wallet dump with the HD master key | `litecoin-wallet-dump.txt` |

Both Core exports require an unlocked wallet, so they are taken once at creation
time and the wallet is re-locked immediately afterwards. The Litecoin dump is
moved out of the chain data directory into the secrets directory, because
`dumpwallet` writes every private key in cleartext wherever it is told to.

This material is strictly more dangerous than the RPC credentials: it spends the
coins with no password at all. Until it is off the server, the wallet encryption
is decorative — the cleartext master keys sit in the same directory as the
wallets they protect. Copy it offline, verify that backup, then:

```bash
sudo ./setup.sh --shred-recovery
```

That shreds `wallet-recovery.txt`, `bitcoin-wallet-descriptors.json`,
`litecoin-wallet-dump.txt` and `monero-default-wallet-recovery.txt`, after
requiring you to type `SHRED`. It leaves the RPC credentials and wallet
passphrases alone, since the daemons need those to run.

Three things to know before you do it:

* **The Monero mnemonic exists nowhere else on the host.** Afterwards it can
  only be recovered from the wallet itself, using the wallet password from
  `rpc-credentials.env` with `monero-wallet-cli`.
* **The Bitcoin and Litecoin exports are derived from their wallets**, so a
  later full run of `setup.sh` recreates them. Shred again after any such run.
* `shred` cannot promise much on a copy-on-write or journalling filesystem, or
  on flash with wear levelling. Treat it as closing the obvious hole, not as
  forensic erasure.

## Reboots

The Quadlet units carry `WantedBy=multi-user.target`, and the generator wires
them into the boot target, so all five services start again by themselves after
a reboot. Arti keeps its onion addresses, because the service keys persist in
`/srv/crypto-daemons/arti`.

Two things do not survive a restart:

* **The Bitcoin and Litecoin wallets come back locked.** `walletpassphrase`
  keeps the key in memory only. Receiving and address generation still work,
  but a send needs the wallet unlocked again.
* **Any Monero wallet closed over RPC stays closed** unless
  `monero-wallet-rpc` was started with `--wallet-dir`; the shipped unit uses
  `--wallet-file`, which reopens the wallet automatically at start.

The wallets themselves are loaded automatically: `setup.sh` writes a
`wallet=default` line into each Core config once the wallet exists.

Use a Tor SOCKS proxy on the client and standard HTTP Basic authentication.
Bitcoin and Litecoin RPC are authenticated with the generated `rpcauth`
credentials. Monero has two endpoints: the daemon's restricted RPC and a
separate, authenticated, spend-capable wallet RPC service.

Default receive addresses are in
`/etc/crypto-daemons/secrets/default-wallet-addresses.env`. RPC credentials
and the BTC/LTC wallet passphrases are in
`/etc/crypto-daemons/secrets/rpc-credentials.env`. The generated Monero
mnemonic is stored only in
`/etc/crypto-daemons/secrets/monero-default-wallet-recovery.txt`; copy it to
offline storage and then securely remove that server-side recovery file if your
operating model permits. Never place any of these values in shell history.

## Security posture

What this deployment enforces, and what it does not.

Enforced:

* Arti's SOCKS proxy — the one listener here that takes no credentials — is
  bound to its internal-bridge address rather than to `0.0.0.0`, so it does not
  also appear on the egress network. Only Bitcoin and Monero proxy through it,
  and both are internal. On a host installed before this change, the deployed
  `arti.toml` keeps its old `socks_listen`; a re-run prints the diff to apply.
* No port is published to the host. Every listener exists only inside the
  private Podman networks; the only way in is an onion service.
* Bitcoin, Monero and the Monero wallet RPC have no route to the internet at
  all. `crypto.network` is created `--internal --disable-dns`, so their
  Tor-only posture survives a bad config rather than depending on one. Only
  Arti (which needs Tor) and Litecoin (which cannot use it) are on
  `crypto-egress.network`.
* Bitcoin and Litecoin accept RPC only from Arti's address on their bridge,
  not from the whole subnet. Core always permits loopback in addition, which is
  what each container's own health check uses.
* All four RPC endpoints require credentials. Bitcoin and Litecoin use salted
  `rpcauth` hashes (the plaintext password is never stored in a file the daemon
  reads); Monero's daemon and wallet RPC use HTTP digest auth. Unauthenticated
  and wrong-password requests are rejected with 401.
* Every container runs with all Linux capabilities dropped, `no-new-privileges`,
  and a read-only root filesystem. State exists only in the mounted volumes.
* Daemon binaries are built from upstream signed releases, not third-party
  images. See the provenance table above.
* Secrets are mode 0600 in a 0700 directory, and both the wallet directories
  and the chain data directories are 0700.
* Bitcoin's peers are onion-only; verify with `getpeerinfo`.

Not enforced, and worth understanding before funding anything:

* **This is a hot wallet.** The RPC credentials, the Bitcoin/Litecoin wallet
  passphrases and the Monero wallet password all sit on the same host as the
  wallets. Anyone with root on the server can spend the funds. No amount of
  container hardening changes that.
* **Containers run as uid 0 inside their namespace.** Capabilities are dropped
  and privilege escalation is blocked, but a container-escape vulnerability
  would land as root. Running each daemon under a dedicated unprivileged uid
  would be a further improvement.
* **The spend-capable wallet RPC cannot be IP-restricted.** Bitcoin's and
  Litecoin's RPC now admit only Arti's bridge address, but `monero-wallet-rpc`
  has no equivalent option, so anything on the internal network — bitcoind
  included — can reach its port and attempt authentication. Splitting it onto a
  network of its own would fix that, at the cost of a third bridge; it is
  credentials and Tor that protect it today.
* **The Monero wallet RPC is spend-capable for its whole lifetime.** It has no
  per-request confirmation. Anyone who obtains its onion address *and* its
  credentials can transfer the balance. Bitcoin and Litecoin are better off
  here: their wallets stay encrypted and a send needs an explicit unlock.
* **The onion layer is not access-controlled by default.** Anyone who learns an
  onion address can reach the RPC port and attempt authentication, so treat the
  addresses as secrets. Restricted discovery closes this and is shipped ready to
  turn on — see "Restricted discovery" below. It is off by default because
  enabling it without first authorizing a client locks you out of that service.
* **Podman bridges are routable from the host itself.** Nothing is published,
  so nothing is reachable from the LAN, but root on this host can reach every
  container listener directly by IP. That is not a new exposure — root here can
  spend the coins anyway — but `ss -ltnp` showing no listener is a statement
  about the host's own ports, not about unreachability.
* **The daily update check runs on the host, not in a container**, so it
  reaches bitcoincore.org, getmonero.org, GitHub, crates.io and Docker Hub over
  the clearnet from this host's own IP, on a schedule. It sends curl's default
  User-Agent rather than one naming this bundle, but the pattern of endpoints is
  itself distinctive. Disable the timer and
  run `--check` from elsewhere if that pattern matters to you.
* **Litecoin's provenance is weaker** than the other two (single signature,
  expired key), and its P2P traffic is not routed over Tor. Its DNS seed
  lookups leave the host in the clear too, through the egress network's DNS;
  `dnsseed=0` narrows that to the fixed seeds compiled in, at some cost to
  bootstrap reliability. Its node is the
  least trustworthy component in this bundle.

## Restricted discovery

By default an onion address is the only thing standing between the internet and
an RPC login prompt. Restricted discovery adds a real second gate: Arti encrypts
the service descriptor to a set of x25519 client keys, so a client without a key
cannot even find the service, let alone attempt to authenticate.

This bundle ships it ready but **off**, in two halves. `arti` is compiled with
the `restricted-discovery` cargo feature (see `containers/arti.Containerfile`),
and `config/arti.toml` carries the configuration commented out. Both halves
matter: Arti refuses to start on a configuration asking for client
authorization when the feature was not compiled in, which would take all four
services down at once. If your Arti image predates that Containerfile change,
rebuild before touching the config:

```bash
sudo ./update.sh --redeploy arti
```

Then authorize a client. The service names are `bitcoin-rpc`, `litecoin-rpc`,
`monero-rpc` and `monero-wallet-rpc`:

```bash
sudo ./setup.sh --add-rpc-client bitcoin-rpc laptop
```

That generates an x25519 keypair, records the public half in
`/srv/crypto-daemons/arti/authorized_clients/bitcoin-rpc/laptop.auth`, and
prints the private half once. The private key is never stored on the server;
capture it when it is printed. For a C-tor client it goes in
`ClientOnionAuthDir` as `<onion-address-without-.onion>:descriptor:x25519:<key>`.

Only then uncomment that service's `restricted_discovery.enabled` line and its
`key_dirs` block in `/etc/crypto-daemons/arti.toml`, and restart Arti. That file
is installed once and never reinstalled, so a later `setup.sh` run leaves your
edits in place.
**Enabling a service whose key directory is empty publishes a descriptor nobody
can decrypt, which locks you out of it.** Do one service, confirm you can still
reach it from a client holding the key, and only then do the rest.

The key format and directory layout follow C-tor's client-authorization
convention. Verify the first service end to end before converting the others,
and keep a way in — an unconverted service, or console access — while you do.

## Important operating notes

* Arti runs as root inside its container, with every capability dropped, a
  read-only root filesystem and `application.allow_running_as_root` set; it
  refuses to start otherwise.  `HOME` is pointed at its state volume because it
  writes a port-info file there. If you
  would rather it ran unprivileged, add a dedicated UID to the image, set `User=`
  in `arti.container`, and `chown` `/srv/crypto-daemons/arti` to match.
* Arti enforces filesystem permission checks. `/etc/crypto-daemons/arti.toml`
  must not be group-writable and `/srv/crypto-daemons/arti` must be no wider
  than 0755, or Arti exits at startup. `setup.sh` installs both correctly.
* Arti's onion-service implementation is still developing.  Keep its version
  pinned and test an upgrade against a copy of this configuration before
  changing production keys.
* Bitcoin and Monero are configured for Tor-only outbound peers; Litecoin peers
  over the clearnet for the reason given above.  None of them accept inbound
  P2P connections.  RPC remains unauthenticated at the onion layer
  but is protected by daemon authentication; treat an onion address as private
  and rotate credentials if it is shared unexpectedly.
* Bitcoin and Litecoin wallets are encrypted and start locked. A send requires
  an authenticated RPC call to unlock the selected wallet for a short period,
  then a send call, then `walletlock`. Monero wallet RPC remains a fully
  spend-capable hot wallet for its lifetime; protect its onion address and RPC
  credentials accordingly.
* The Bitcoin wallet is a descriptor wallet; the Litecoin wallet is a legacy
  wallet, because Litecoin Core 0.21 rejects descriptor wallets outright. Both
  are encrypted and both auto-load through a `wallet=default` line that
  `setup.sh` appends once the wallet exists.
* Pruned BTC/LTC nodes can only rescan as far back as the blocks they still
  hold -- roughly a month on Bitcoin and several months on Litecoin at the
  10 GB target. Do not import an older already-used key into these default
  wallets unless you have an appropriate rescan strategy or rebuild from an
  archival source.
* Each daemon container is given an explicit `--stop-timeout` (nine minutes for
  the three chains, four for the wallet RPC). Quadlet stops containers with
  `podman rm -f`, whose grace period is the container's own stop timeout —
  10 seconds by default — and *not* the unit's `TimeoutStopSec`, which only
  bounds how long systemd waits for that command. Without it both Core daemons
  are killed mid-flush on every restart and reboot and replay blocks on the way
  back up. If you add a daemon here, give it the same treatment.
* `setup.sh` and `update.sh` remove this bundle's own superseded
  `localhost/crypto-*` image tags after a successful restart. Nothing else is
  touched, and an image still in use is left alone. Dangling layers from the
  multi-stage builds are deliberately *not* swept: `podman image prune` cannot
  be scoped to one bundle, and this host may not be dedicated to it. Run it
  yourself if it is.
* Changing `prune` is not retroactive. Raising it keeps more from the restart
  onwards; blocks already deleted are gone, so a freshly raised target takes a
  full window to become useful. Lowering it prunes back down immediately.
  Neither direction needs a reindex, but going from pruned to unpruned does
  require a full re-sync. To change it on a running host, edit
  `/etc/crypto-daemons/{bitcoin,litecoin}.conf` and restart the two services;
  `update.sh` does not touch configs, and re-running `setup.sh` would reinstall
  them from this bundle.
* Back up `/srv/crypto-daemons/arti` as it holds the onion-service keys under
  `state/`, and any client authorizations under `authorized_clients/`.
  Back up daemon data only if the re-sync cost matters; do not back up it as a
  substitute for wallet-key backups.
* For an already-synced Monero data directory, `prune-blockchain=1` marks data
  prunable but does not immediately make its LMDB file smaller. Stop Monero and
  use the version-matched `monero-blockchain-prune` tool with a verified backup
  before expecting reclaimed host disk space.
* Every container carries a health check, and all of them are **report-only**:
  a failure shows in `podman ps` and `systemctl status` but restarts nothing.
  That is deliberate — a subtly wrong check that restarts a money-handling
  daemon is worse than no check at all. Once you have watched one be accurate
  on your host, add `HealthOnFailure=kill` to that unit to make it act. Bitcoin
  and Litecoin are checked with their own `-cli` against the cookie the daemon
  writes; Monero, its wallet RPC and Arti are checked with a TCP connect,
  because an RPC call there could fail on credentials and report a healthy
  daemon as sick.
* The daemon units order themselves `After=time-sync.target`, and `setup.sh`
  enables `systemd-time-wait-sync` so that target is actually reached — on its
  own the ordering is a no-op, because nothing pulls that target in by default.
  `setup.sh` also drops in a `TimeoutStartSec=5min` for that unit: it waits
  indefinitely by default, and since every container orders itself behind the
  target, an unreachable NTP server would otherwise hold the entire deployment
  at boot rather than starting it with a slightly wrong clock.
  If the host uses chrony or ntpsec instead of `systemd-timesyncd`, `setup.sh`
  says so and leaves clock synchronisation to you. Both Core daemons and Monero
  handle a badly skewed clock poorly.
* Review firewall rules separately.  This bundle publishes no ports, but it
  does not overwrite an existing host firewall.
* To update an image, stop the affected service cleanly, rerun the script with
  the reviewed immutable digest (recorded in `/etc/crypto-daemons/images.env`),
  and validate the chain's upgrade notes first.

## Checks

```bash
sudo systemctl status arti bitcoin litecoin monero monero-wallet-rpc
sudo podman ps --format 'table {{.Names}}\t{{.Status}}'
sudo ss -ltnp
sudo journalctl -u arti -u bitcoin -u litecoin -u monero -u monero-wallet-rpc -f
```

`ss` should show no listener added by this bundle on the host.  All listeners
exist only inside the private Podman networks.  `podman ps` shows each
container's health state alongside its uptime.

To confirm the internal network really has no way out — this should fail, and
the DNS lookup should fail too:

```bash
sudo podman exec bitcoin bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' ; echo "exit=$?"
```

To see which network each container is on:

```bash
sudo podman ps --format '{{.Names}}' | xargs -I{} sh -c 'printf "%-18s " {}; podman inspect {} --format "{{range \$k, \$v := .NetworkSettings.Networks}}{{\$k}} {{\$v.IPAddress}} {{end}}"; echo'
```
