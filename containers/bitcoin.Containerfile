# Bitcoin Core from the project's official release tarball.
# The pinned digest below was taken from bitcoincore.org's SHA256SUMS, whose
# detached signature was verified against Guix builder keys (see README).
ARG FETCH_IMAGE
ARG RUNTIME_IMAGE
FROM ${FETCH_IMAGE} AS fetch
ARG BITCOIN_VERSION=31.1
ARG BITCOIN_SHA256=b80d9c3e04da78fb6f0569685673418cf686fadba9042d926d13fb87ff503f9e
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /dl
RUN set -eux; \
    tarball="bitcoin-${BITCOIN_VERSION}-x86_64-linux-gnu.tar.gz"; \
    curl -fsSLO "https://bitcoincore.org/bin/bitcoin-core-${BITCOIN_VERSION}/${tarball}"; \
    printf '%s  %s\n' "${BITCOIN_SHA256}" "${tarball}" | sha256sum -c -; \
    tar -xzf "${tarball}"; \
    install -d /out; \
    install -m 0755 "bitcoin-${BITCOIN_VERSION}/bin/bitcoind" "bitcoin-${BITCOIN_VERSION}/bin/bitcoin-cli" /out/

FROM ${RUNTIME_IMAGE}
RUN apt-get update && apt-get install -y --no-install-recommends libstdc++6 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=fetch /out/bitcoind /out/bitcoin-cli /usr/local/bin/
