# ==========================================================
# Standalone Redis — based on official Alpine image
# ==========================================================
FROM redis:alpine

# Pull in Alpine security fixes newer than the base image (openssl, util-linux, zlib)
RUN apk upgrade --no-cache

# Copy custom configuration
COPY --chown=redis:redis redis.conf /usr/local/etc/redis/redis.conf

# Ensure data directory exists and is owned by the redis user
RUN mkdir -p /data && chown redis:redis /data

# Run as non-root
USER redis

EXPOSE 6379

# Auth is applied only when REDIS_PASSWORD is set, so existing clients keep working until it is rolled out
HEALTHCHECK --interval=10s --timeout=5s --retries=5 \
  CMD redis-cli ${REDIS_PASSWORD:+-a "$REDIS_PASSWORD" --no-auth-warning} ping | grep -q PONG || exit 1

CMD ["sh", "-c", "exec redis-server /usr/local/etc/redis/redis.conf ${REDIS_PASSWORD:+--requirepass \"$REDIS_PASSWORD\"}"]
