ARG BASE_IMAGE
FROM ${BASE_IMAGE}

RUN apk add --no-cache bash ca-certificates curl jq python3 nodejs \
    && addgroup -g 1000 mirror \
    && adduser -D -u 1000 -G mirror mirror
WORKDIR /opt/mirror
COPY mirror.sh sync.sh gitlens-patch.py ./
COPY lib/ lib/
USER 1000:1000
ENTRYPOINT ["/bin/bash", "/opt/mirror/sync.sh"]
