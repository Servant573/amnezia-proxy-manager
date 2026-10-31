FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    make bash coreutils util-linux iproute2 nftables procps findutils grep sed gawk python3 curl openssl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY apm apm-gui amnezia-proxy-manager config.example ./
COPY bin/ bin/
COPY lib/ lib/
COPY tests/ tests/
COPY scripts/ scripts/
COPY docs/ docs/
COPY Makefile README.md AUDIT.md LICENSE CHANGELOG.md ./
RUN chmod -R go-w /app && chmod +x amnezia-proxy-manager bin/amnezia-proxy
CMD ["bash", "tests/docker-entrypoint.sh"]
