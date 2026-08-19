# Bitcoin, Litecoin, Monero over Arti / Tor

This bundle deploys three **outbound-Tor-only** full nodes and exposes their
restricted RPC interfaces only as separate v3 onion services.  No TCP port is
published on the Debian host.  Podman Quadlet keeps the four containers under
systemd.

All three chains are configured to retain the least historical block data their
supported safe pruning modes permit: Bitcoin Core and Litecoin Core use the
550 MiB automatic block/undo target, and Monero uses pruned-block sync. They
still fully validate the chain, but cannot provide old blocks, historical
transaction lookups, rescans, or full initial-sync service to other peers.

## Before installing

1. Use a fresh, supported Debian 13 host with enough fast, redundant storage.
   A non-pruned Bitcoin node alone currently needs hundreds of GB; plan disk
   capacity and backups before syncing.
2. Choose and pin the three daemon images by immutable digest.  The bundle
   intentionally refuses mutable tags: these daemons validate money, so image
   provenance is a security boundary.  The `setup.sh` usage message shows the
   exact environment variables.
   Each image must provide the standard `bitcoind`, `litecoind`, or `monerod`
   executable and accept the configuration path passed by its Quadlet.
3. This is a node-only deployment.  Do **not** put wallet keys in these data
   directories.  The generated RPC passwords are sensitive; the script prints
   them once and writes a root-readable credentials file.

## Install

Copy this directory to the server, pin your reviewed images, then run:

```bash
sudo BITCOIN_IMAGE='docker.io/…@sha256:…' \
     LITECOIN_IMAGE='docker.io/…@sha256:…' \
     MONERO_IMAGE='docker.io/…@sha256:…' \
     ARTI_RUST_IMAGE='docker.io/rust:…@sha256:…' \
     ARTI_RUNTIME_IMAGE='docker.io/debian:…@sha256:…' \
     ./setup.sh
```

The script is idempotent: rerunning it preserves data, RPC credentials, and
Arti onion-service keys.  It builds `localhost/crypto-arti:2.5.1` from the
pinned `arti` crate with onion-service support, installs Quadlets into
`/etc/containers/systemd`, then starts `arti`, `bitcoin`, `litecoin`, and
`monero`.

During an interactive run it asks whether to install Podman Desktop through
Flathub for the login that invoked `sudo`; choose **No** on a headless server.
For noninteractive use, set `INSTALL_PODMAN_DESKTOP=yes` and (when needed)
`PODMAN_DESKTOP_USER=<desktop-login>`.

To display the three onion RPC endpoints after Arti has bootstrapped:

```bash
sudo podman exec crypto-arti arti --config /etc/arti/arti.toml hss \
  --nickname bitcoin-rpc onion-address
sudo podman exec crypto-arti arti --config /etc/arti/arti.toml hss \
  --nickname litecoin-rpc onion-address
sudo podman exec crypto-arti arti --config /etc/arti/arti.toml hss \
  --nickname monero-rpc onion-address
```

Use a Tor SOCKS proxy on the client and standard HTTP Basic authentication.
Bitcoin and Litecoin RPC are authenticated with the generated `rpcauth`
credentials; Monero's only exposed interface is its restricted RPC port.

## Important operating notes

* Arti's onion-service implementation is still developing.  Keep its version
  pinned and test an upgrade against a copy of this configuration before
  changing production keys.
* The daemons are configured for Tor-only outbound peers.  They do not provide
  P2P service to the clearnet.  RPC remains unauthenticated at the onion layer
  but is protected by daemon authentication; treat an onion address as private
  and rotate credentials if it is shared unexpectedly.
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
sudo systemctl status arti bitcoin litecoin monero
sudo podman ps --format 'table {{.Names}}\t{{.Status}}'
sudo ss -ltnp
sudo journalctl -u arti -u bitcoin -u litecoin -u monero -f
```

`ss` should show no listener added by this bundle on the host.  All listeners
exist only inside the private Podman network.
