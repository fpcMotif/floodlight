# syntax=docker/dockerfile:1
FROM --platform=linux/amd64 debian:bookworm-slim AS bombadil
ARG BOMBADIL_VERSION=0.7.4
ARG BOMBADIL_SHA256=92d4e296e49acc487348bcee788fc81cc1f6f7dca80bd85367d018d40dd2a286
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && curl --fail --location --silent --show-error \
        "https://github.com/antithesishq/bombadil/releases/download/v${BOMBADIL_VERSION}/bombadil-x86_64-linux" \
        --output /bombadil \
    && echo "${BOMBADIL_SHA256}  /bombadil" | sha256sum --check --strict

FROM --platform=linux/amd64 rust:1.89-bookworm AS builder
WORKDIR /src
COPY testing/fff-contracts/ testing/fff-contracts/
RUN testing/fff-contracts/materialize.sh /src/fff-swift
RUN cargo build --manifest-path /src/fff-swift/Vendor/fff/Cargo.toml \
    -p fff-test-harness --release --locked

FROM --platform=linux/amd64 debian:bookworm-slim
ENV NO_COLOR=1
COPY --from=bombadil /bombadil /usr/local/bin/bombadil
COPY --from=builder /src/fff-swift/Vendor/fff/target/release/fff-terminal-harness /usr/local/bin/fff-terminal-harness
COPY testing/fff-exploration/specification.ts /opt/floodlight/specification.ts
COPY testing/fff-exploration/antithesis/setup.sh /usr/local/bin/fff-antithesis-setup
COPY testing/fff-exploration/antithesis/test-command.sh /opt/antithesis/test/v1/fff/singleton_driver_explore
RUN chmod 0555 /usr/local/bin/bombadil \
    /usr/local/bin/fff-terminal-harness \
    /usr/local/bin/fff-antithesis-setup \
    /opt/antithesis/test/v1/fff/singleton_driver_explore
ENTRYPOINT ["/usr/local/bin/fff-antithesis-setup"]
