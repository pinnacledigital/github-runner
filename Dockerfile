FROM myoung34/github-runner:latest

ENV DEBIAN_FRONTEND=noninteractive

# Lifecycle dependencies (jq and openssl are already in base, but we ensure they are present)
RUN apt-get update && \
    apt-get install -y jq curl openssl && \
    rm -rf /var/lib/apt/lists/*

# Token rotation entrypoint
COPY token-entrypoint.sh /token-entrypoint.sh
RUN chmod +x /token-entrypoint.sh

# State directory for token cache
RUN mkdir -p /var/run/github-runner && chmod 777 /var/run/github-runner

HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD pgrep -f "Runner.Listener" || exit 1

ENTRYPOINT ["/token-entrypoint.sh"]
CMD ["./run.sh"]
