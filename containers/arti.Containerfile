ARG RUST_IMAGE
ARG RUNTIME_IMAGE
FROM ${RUST_IMAGE} AS build
ARG ARTI_VERSION=2.5.1
# restricted-discovery is compiled in but left off in config/arti.toml.  The
# feature is gated at build time, so without it here Arti refuses to start on
# a config that asks for client authorization at all.
RUN cargo install --locked arti --version "${ARTI_VERSION}" \
    --features onion-service-service,restricted-discovery

FROM ${RUNTIME_IMAGE}
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/cargo/bin/arti /usr/local/bin/arti
ENTRYPOINT ["/usr/local/bin/arti"]
