FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    iptables \
    iproute2 \
    procps \
    && rm -rf /var/lib/apt/lists/*

COPY tun2socks /usr/local/bin/tun2socks
RUN chmod +x /usr/local/bin/tun2socks

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]