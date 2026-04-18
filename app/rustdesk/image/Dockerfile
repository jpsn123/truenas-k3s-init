##
## build license-server
FROM rust:1.93-slim AS rust-builder
WORKDIR /rust

RUN apt-get update && apt-get install -y --no-install-recommends build-essential ca-certificates && rm -rf /var/lib/apt/lists/*

COPY Cargo.toml Cargo.lock /rust
COPY src /rust/src

RUN cargo build --release && cp target/release/license-server license-server

##
## 
FROM rustdesk/rustdesk-server-pro:latest

ENV LICENSE_SERVER_CRT=/certs/server.crt
ENV LICENSE_SERVER_PRIV=/certs/server.key
ENV LICENSE_SIGNKEY_PUB=/certs/id_ed25519.pub
ENV LICENSE_SIGNKEY_PRIV=/certs/id_ed25519
ENV LICENSE=UlVTVERFU0tfTElDRU5TRQ==

COPY --from=rust-builder /rust/license-server /usr/bin/license-server
COPY original_ed25519.pub favicon.png favicon.svg patch.sh icon.png /tmp/assets/

# custom hbbs, use local license server
RUN cp -f /tmp/assets/favicon.png /usr/share/rustdesk-server/static/web/icons/Icon-192.png && \
    cp -f /tmp/assets/favicon.png /usr/share/rustdesk-server/static/web/icons/Icon-maskable-192.png && \
    cp -f /tmp/assets/icon.png /usr/share/rustdesk-server/static/web/icons/Icon-512.png && \
    cp -f /tmp/assets/icon.png /usr/share/rustdesk-server/static/web/icons/Icon-maskable-512.png && \
    cp -f /tmp/assets/favicon.png /usr/share/rustdesk-server/static/ && \
    cp -f /tmp/assets/favicon.svg /usr/share/rustdesk-server/static/web/ && \
    cp -f /tmp/assets/favicon.svg /usr/share/rustdesk-server/static/web/assets/assets/icon.svg && \
    cp -f /tmp/assets/favicon.svg /usr/share/rustdesk-server/static/logo.svg && \
    cp -f /tmp/assets/patch.sh / && \
    mkdir -p /certs && chmod 700 /certs && \
    cp -f /tmp/assets/original_ed25519.pub /certs/ && \
    chmod +x /usr/bin/license-server && \
    cd /certs && license-server --keygen && \
    HBBS_PATH=/usr/bin/hbbs \
    HBBS_BACKUP_PATH=/usr/bin/hbbs-official \
    ORIGINAL_KEY_PATH=/certs/original_ed25519.pub \
    NEW_KEY_PATH=/certs/id_ed25519.pub \
    license-server --patch && \
    chmod 600 /certs/* && \
    ln -s /certs/ca.crt /usr/local/share/ca-certificates/rustdesk.crt && \
    update-ca-certificates && \
    chmod +x /usr/bin/hbbs && \
    rm -f /certs/original_ed25519.pub && \
    rm -f /usr/bin/hbbs-official

# custom web client, use local resource and use jutze icon
RUN apt update && \
    apt install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/* && \
    bash /patch.sh
