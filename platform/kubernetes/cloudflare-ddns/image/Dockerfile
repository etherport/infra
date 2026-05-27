# Cloudflare DDNS image — minimal, no aws-cli.
#
# Migrated 2026-05-27 from the public.ecr.aws/aws-cli base (~200MB)
# to alpine + curl + jq + bind-tools after the script switched to
# writing Cloudflare records over HTTPS (no AWS calls remain).
FROM alpine:3.21

RUN apk add --no-cache \
    bash \
    curl \
    jq \
    bind-tools \
    coreutils \
    && rm -rf /var/cache/apk/*

# Run as non-root (CronJob securityContext expects uid 1000)
RUN addgroup -g 1000 -S ddns && adduser -u 1000 -S -G ddns ddns

# Copy update script
COPY scripts/update-cf-dns.sh /scripts/update-cf-dns.sh
RUN chmod +x /scripts/update-cf-dns.sh

USER 1000:1000

# Default command
CMD ["/scripts/update-cf-dns.sh"]
