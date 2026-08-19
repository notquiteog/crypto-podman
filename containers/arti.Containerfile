ARG RUST_IMAGE
ARG RUNTIME_IMAGE
FROM ${RUST_IMAGE} AS build
ARG ARTI_VERSION=2.5.1
RUN cargo install --locked arti --version "${ARTI_VERSION}" --features onion-service-service

FROM ${RUNTIME_IMAGE}
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/cargo/bin/arti /usr/local/bin/arti
ENTRYPOINT ["/usr/local/bin/arti"]
