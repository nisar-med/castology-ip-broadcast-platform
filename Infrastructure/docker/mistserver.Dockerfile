# Extends the official MistServer image with dependencies needed by cast-* scripts.
FROM ddvtech/mistserver:latest

RUN apk add --no-cache bash curl jq python3 util-linux

COPY mistserver-entrypoint.sh /castology-entrypoint.sh
COPY scripts/cast-mist-stream-auth.sh /usr/local/bin/cast-mist-stream-auth.sh
COPY scripts/cast-r2-writer /usr/local/bin/cast-r2-writer
COPY scripts/cast-hls-clean.py /usr/local/bin/cast-hls-clean.py
RUN chmod +x /castology-entrypoint.sh /usr/local/bin/cast-mist-stream-auth.sh /usr/local/bin/cast-r2-writer /usr/local/bin/cast-hls-clean.py

ENTRYPOINT ["/castology-entrypoint.sh"]
