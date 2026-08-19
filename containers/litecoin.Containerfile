# Litecoin Core from the project's official release tarball.
# The pinned digest is from the GitHub release SHA256SUMS.asc.  Note that its
# only signature is made with an expired key; see the README.
ARG FETCH_IMAGE
ARG RUNTIME_IMAGE
FROM ${FETCH_IMAGE} AS fetch
ARG LITECOIN_VERSION=0.21.5.6
ARG LITECOIN_SHA256=3c0a217651a431ef446641669a0b74ce7dbcd9b9ed1a118fc830b8f6779ee83f
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /dl
RUN set -eux; \
    tarball="litecoin-${LITECOIN_VERSION}-x86_64-linux-gnu.tar.gz"; \
    curl -fsSLO "https://download.litecoin.org/litecoin-${LITECOIN_VERSION}/linux/${tarball}"; \
    printf '%s  %s\n' "${LITECOIN_SHA256}" "${tarball}" | sha256sum -c -; \
    tar -xzf "${tarball}"; \
    install -d /out; \
    install -m 0755 "litecoin-${LITECOIN_VERSION}/bin/litecoind" "litecoin-${LITECOIN_VERSION}/bin/litecoin-cli" /out/

FROM ${RUNTIME_IMAGE}
RUN apt-get update && apt-get install -y --no-install-recommends libstdc++6 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=fetch /out/litecoind /out/litecoin-cli /usr/local/bin/
