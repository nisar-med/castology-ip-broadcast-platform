# MistServer API Reference

Derived from source: https://github.com/DDVTECH/mistserver  
Key files: `src/controller/controller_api.cpp`, `src/controller/controller_statistics.cpp`

---

## POST /api — Clients (Active Sessions)

```json
{ "clients": null }
```

Returns array-of-arrays. `fields` lists column names; `data` is rows in the same order.

| Field | Type | Description |
|---|---|---|
| `host` | string | Client IP address |
| `stream` | string | Stream name |
| `protocol` | string | e.g. `"INPUT:TSSRT"`, `"OUTPUT:TSSRT"`, `"OUTPUT:HLS"` |
| `conntime` | number | Connection duration in seconds |
| `position` | number | Media playback position (last second) |
| `down` | number | Total bytes downloaded by client |
| `up` | number | Total bytes uploaded by client |
| `downbps` | number | Download rate (bytes/sec) |
| `upbps` | number | Upload rate (bytes/sec) |
| `sessid` | string | Session ID |
| `pktcount` | number | Total packets sent |
| `pktlost` | number | Packets lost |
| `pktretransmit` | number | Packets retransmitted |

**Protocol field format:** `"DIRECTION:CONNECTOR"` — split on `:` to get direction (`INPUT`/`OUTPUT`) and connector (`TSSRT`, `HLS`, `HTTP`, etc.)

**Packet loss ratio:** `pktlost / pktcount`

---

## POST /api — Active Streams

```json
{ "active_streams": null }
```

Returns a list of currently online stream names.

---

## Prometheus Endpoint

`GET /{prometheus_passphrase}` on port 4242

### Gauges (current state)

| Metric | Labels | Description |
|---|---|---|
| `mist_cpu` | — | CPU usage (tenths of a percent) |
| `mist_mem_total` / `mist_mem_used` | — | System memory (KiB) |
| `mist_shm_total` / `mist_shm_used` | — | Shared memory (KiB) |
| `mist_bw_limit` | — | Bandwidth ceiling |
| `mist_sessions_total` | `sessType` | Active sessions: `viewers`, `incoming`, `outgoing`, `unspecified` |
| `mist_sessions` | `stream`, `sessType` | Active sessions per stream per type |
| `mist_outputs` | `output` | Active viewer count per output protocol |

### Counters (cumulative since startup)

| Metric | Labels | Description |
|---|---|---|
| `mist_logs` | — | Total log messages |
| `mist_sessions_count` | `sessType` | Lifetime unique sessions |
| `mist_bw_total` | `direction` (`up`/`down`) | Lifetime bytes |
| `mist_bw` | `stream`, `direction` | Bytes per stream |
| `mist_packets_total` | `pkttype` (`sent`/`lost`/`retransmit`) | Server-wide packet counters |
| `mist_packets` | `stream`, `pkttype` | Packets per stream |
| `mist_viewcount` | `stream` | Cumulative unique viewers (NOT concurrent) |
| `mist_viewseconds` | `stream` | Cumulative viewer-seconds |
| `mist_viewseconds_total` | — | Server-wide viewer-seconds |

### Trigger stats (per trigger name)

| Metric | Labels |
|---|---|
| `mist_trigger_count` | `trigger` |
| `mist_trigger_time` | `trigger` |
| `mist_trigger_fail` | `trigger` |

---

## Notes

- `mist_viewcount` is cumulative (counter since startup), **not** concurrent viewers. Use `mist_sessions{sessType="viewers"}` for current concurrent count.
- `mist_sessions_total{sessType="outgoing"}` = current outgoing (operator) sessions server-wide.
- Stats collection runs at ~1Hz. Sessions inactive for >10 minutes are dropped (`STAT_CUTOFF`).
- The `clients` API requires `POST` with `Content-Type: application/json`. `GET /api2?clients` does not return session data.
