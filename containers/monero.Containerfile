# Monero from the project's official release tarball.  This single image
# provides monerod, monero-wallet-rpc and monero-wallet-cli.
# The pinned digest is from getmonero.org's hashes.txt, PGP-clearsigned by
# binaryFate (fingerprint in the README).
ARG FETCH_IMAGE
ARG RUNTIME_IMAGE
FROM ${FETCH_IMAGE} AS fetch
ARG MONERO_VERSION=0.18.5.1
ARG MONERO_SHA256=22a7dda7b0cb699fdd6b7674c3b4a4465b337cc98a54983523b759e1e7cc9958
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates bzip2 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /dl
RUN set -eux; \
    tarball="monero-linux-x64-v${MONERO_VERSION}.tar.bz2"; \
    curl -fsSLO "https://downloads.getmonero.org/cli/${tarball}"; \
    printf '%s  %s\n' "${MONERO_SHA256}" "${tarball}" | sha256sum -c -; \
    install -d /out; \
    tar -xjf "${tarball}" --strip-components=1 -C /out \
        --wildcards '*/monerod' '*/monero-wallet-rpc' '*/monero-wallet-cli'; \
    chmod 0755 /out/monerod /out/monero-wallet-rpc /out/monero-wallet-cli

FROM ${RUNTIME_IMAGE}
COPY --from=fetch /out/monerod /out/monero-wallet-rpc /out/monero-wallet-cli /usr/local/bin/
