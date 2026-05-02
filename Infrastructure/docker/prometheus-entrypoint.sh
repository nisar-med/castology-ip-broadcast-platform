#!/bin/sh
set -e
sed "s|\${PROMETHEUS_PASSPHRASE}|${PROMETHEUS_PASSPHRASE}|g" \
    /etc/prometheus/prometheus.yml.tpl > /tmp/prometheus.yml
exec /bin/prometheus \
    --config.file=/tmp/prometheus.yml \
    --storage.tsdb.path=/prometheus \
    --storage.tsdb.retention.time=30d
