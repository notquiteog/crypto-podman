# Bitcoin, Litecoin, Monero over Arti / Tor

This bundle deploys three full nodes, encrypted default wallets, and
authenticated v3 onion-service RPC endpoints. No TCP port is published on the
Debian host. Podman Quadlet keeps the five containers under systemd.

Bitcoin and Monero reach the network **only over Tor**. Litecoin is the
exception and peers over the clearnet: Tor exit relays reject port 9333, and
the three onion addresses compiled into Litecoin Core are unreachable, so an
onion-only Litecoin node never finds a peer and never syncs. All three RPC
endpoints, Litecoin's included, are reachable only through an authenticated
onion service.

All three chains are configured to retain the least historical block data their
supported safe pruning modes permit: Bitcoin Core and Litecoin Core use the
550 MiB automatic block/undo target, and Monero uses pruned-block sync. They
still fully validate the chain, but cannot provide old blocks, historical
transaction lookups, rescans, or full initial-sync service to other peers.

## Before installing

1. Use a fresh, supported Debian 13 host with enough fast, redundant storage.
   A non-pruned Bitcoin node alone currently needs hundreds of GB; plan disk
   capacity and backups before syncing.
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

Three scripts make up the bundle: `setup.sh` installs, `update.sh` maintains
(see "Applying security updates"), and `lib.sh` holds what they share — the
pins, the image build steps, and the Quadlet install.  `lib.sh` is sourced, not
run.

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
31.1.0, Litecoin Core 0.21.5.5, and Monero 0.18.4.6. Review them yourself
before trusting them with funds. If you substitute others, note that the
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

Fingerprints are primary keys, not subkeys: several Bitcoin builders sign with
subkeys, and pinning one would break the moment it is rotated.

### What to automate, and what not to

`--check` is safe to run on a timer. Applying is a different question per
component:

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
coins with no password at all. Copy it offline and delete the server-side files
once you have.

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

* No port is published to the host. Every listener exists only inside the
  private Podman network; the only way in is an onion service.
* All four RPC endpoints require credentials. Bitcoin and Litecoin use salted
  `rpcauth` hashes (the plaintext password is never stored in a file the daemon
  reads); Monero's daemon and wallet RPC use HTTP digest auth. Unauthenticated
  and wrong-password requests are rejected with 401.
* Every container runs with all Linux capabilities dropped, `no-new-privileges`,
  and a read-only root filesystem. State exists only in the mounted volumes.
* Daemon binaries are built from upstream signed releases, not third-party
  images. See the provenance table above.
* Secrets are mode 0600 in a 0700 directory, and wallet directories are 0700.
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
* **The Monero wallet RPC is spend-capable for its whole lifetime.** It has no
  per-request confirmation. Anyone who obtains its onion address *and* its
  credentials can transfer the balance. Bitcoin and Litecoin are better off
  here: their wallets stay encrypted and a send needs an explicit unlock.
* **The onion layer itself is not access-controlled.** Anyone who learns an
  onion address can reach the RPC port and attempt authentication. Treat the
  addresses as secrets. Arti supports restricted discovery (client
  authorization) if you later want a second gate.
* **Litecoin's provenance is weaker** than the other two (single signature,
  expired key), and its P2P traffic is not routed over Tor. Its node is the
  least trustworthy component in this bundle.

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
* Pruned BTC/LTC nodes cannot rescan arbitrarily old blocks. Do not import an
  already-used key into these default wallets unless you have an appropriate
  rescan strategy or rebuild from an archival source.
* Back up `/srv/crypto-daemons/arti/state` as it holds the onion-service keys.
  Back up daemon data only if the re-sync cost matters; do not back up it as a
  substitute for wallet-key backups.
* For an already-synced Monero data directory, `prune-blockchain=1` marks data
  prunable but does not immediately make its LMDB file smaller. Stop Monero and
  use the version-matched `monero-blockchain-prune` tool with a verified backup
  before expecting reclaimed host disk space.
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
exist only inside the private Podman network.
