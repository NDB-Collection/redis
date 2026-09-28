# ==========================================================
# Standalone Redis — based on official Alpine image
# ==========================================================
FROM redis:alpine

# Copy custom configuration
COPY redis.conf /usr/local/etc/redis/redis.conf

# Ensure data directory exists and is owned by the redis user
RUN mkdir -p /data && chown redis:redis /data

EXPOSE 6379

CMD ["redis-server", "/usr/local/etc/redis/redis.conf"]