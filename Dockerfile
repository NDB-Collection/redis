# ==========================================================
# Standalone Redis — based on official Alpine image
# ==========================================================
FROM redis:alpine

# Pull in Alpine security fixes newer than the base image (openssl, util-linux, zlib)
RUN apk upgrade --no-cache

# Copy custom configuration
COPY redis.conf /usr/local/etc/redis/redis.conf

# Ensure data directory exists and is owned by the redis user
RUN mkdir -p /data && chown redis:redis /data

EXPOSE 6379

CMD ["redis-server", "/usr/local/etc/redis/redis.conf"]