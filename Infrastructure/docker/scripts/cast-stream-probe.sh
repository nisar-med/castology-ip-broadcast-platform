#!/usr/bin/env bash
# Monitors one MistServer SRT stream with TSduck and writes Prometheus metrics.
# Usage: cast-stream-probe.sh <stream_name> <srt_port>

STREAM="$1"
PORT="$2"
METRICS_FILE="/var/lib/prometheus/tsduck/${STREAM}.prom"
TMPFILE="${METRICS_FILE}.tmp"

mkdir -p /var/lib/prometheus/tsduck

while true; do
  # Run tsp for 15 seconds, collect continuity + PCR + bitrate stats
  RESULT=$(tsp     -I srt --local-port "$PORT" --listener --latency 300     -P continuity --no-fix --json-line     -P pcrverify --json-line     -P bitrate_monitor --periodic-bitrate 5 --json-line     -O drop     --realtime 2>&1 | head -n 50 || true)

  # Parse and write Prometheus metrics
  CC_ERRORS=$(echo "$RESULT" | grep -c '"cc_error"' 2>/dev/null || echo 0)
  PCR_ERRORS=$(echo "$RESULT" | grep -c '"pcr_error"' 2>/dev/null || echo 0)

  cat > "$TMPFILE" << EOF
# HELP tsduck_cc_errors_total Continuity counter errors detected in MPEG-TS stream
# TYPE tsduck_cc_errors_total counter
tsduck_cc_errors_total{stream="$STREAM"} $CC_ERRORS
# HELP tsduck_pcr_errors_total PCR timing errors detected in MPEG-TS stream
# TYPE tsduck_pcr_errors_total counter
tsduck_pcr_errors_total{stream="$STREAM"} $PCR_ERRORS
EOF
  mv "$TMPFILE" "$METRICS_FILE"
  sleep 5
done
