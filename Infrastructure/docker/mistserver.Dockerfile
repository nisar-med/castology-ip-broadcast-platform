# Extends the official MistServer image with dependencies needed by cast-* scripts.
FROM ddvtech/mistserver:latest

RUN apk add --no-cache bash curl jq python3 util-linux

COPY mistserver-entrypoint.sh /castology-entrypoint.sh
RUN chmod +x /castology-entrypoint.sh

ENTRYPOINT ["/castology-entrypoint.sh"]
