#!/usr/bin/env bash
# PocketBase — installs latest release, sets up collections and systemd service.
# Idempotent — safe to re-run.
set -euo pipefail

PB_ADMIN_EMAIL="${PB_ADMIN_EMAIL:?PB_ADMIN_EMAIL must be set}"
PB_ADMIN_PASSWORD="${PB_ADMIN_PASSWORD:?PB_ADMIN_PASSWORD must be set}"
STREAMING_PUBLIC_IP="${STREAMING_PUBLIC_IP:?STREAMING_PUBLIC_IP must be set}"
SRT_INGEST_PORT="${SRT_INGEST_PORT:-1235}"
SRT_OUTPUT_PORTS="${SRT_OUTPUT_PORTS:-1236,1238}"

PB_DIR="/opt/pocketbase"
PB_BIN="${PB_DIR}/pocketbase"
PB_DATA="${PB_DIR}/pb_data"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl jq unzip

# ---------------------------------------------------------------------------
# Install PocketBase
# ---------------------------------------------------------------------------
if [ ! -f "${PB_BIN}" ]; then
  echo "==> Installing PocketBase"
  mkdir -p "${PB_DIR}"

  LATEST=$(curl -sf https://api.github.com/repos/pocketbase/pocketbase/releases/latest \
    | jq -r '.tag_name' | tr -d 'v')
  ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
  URL="https://github.com/pocketbase/pocketbase/releases/download/v${LATEST}/pocketbase_${LATEST}_linux_${ARCH}.zip"

  curl -fsSL "${URL}" -o /tmp/pocketbase.zip
  unzip -q /tmp/pocketbase.zip -d "${PB_DIR}"
  chmod +x "${PB_BIN}"
  rm /tmp/pocketbase.zip
  echo "==> PocketBase ${LATEST} installed"
else
  echo "==> PocketBase already installed — skipping download"
fi

# ---------------------------------------------------------------------------
# Systemd service
# ---------------------------------------------------------------------------
cat > /etc/systemd/system/pocketbase.service << EOF
[Unit]
Description=PocketBase
After=network.target

[Service]
Type=simple
WorkingDirectory=${PB_DIR}
ExecStart=${PB_BIN} serve --http=127.0.0.1:8090 --dir=${PB_DATA}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable pocketbase
systemctl restart pocketbase

echo "==> Waiting for PocketBase to start..."
for i in $(seq 1 20); do
  if curl -sf http://127.0.0.1:8090/api/health > /dev/null 2>&1; then
    echo "==> PocketBase is up"
    break
  fi
  sleep 2
done

# ---------------------------------------------------------------------------
# Bootstrap superadmin — PocketBase v0.23+ uses CLI (not API) for superusers
# ---------------------------------------------------------------------------
${PB_BIN} superuser upsert "${PB_ADMIN_EMAIL}" "${PB_ADMIN_PASSWORD}" --dir="${PB_DATA}"
echo "==> Superadmin upserted"

# Get auth token for schema setup — v0.23+ endpoint
TOKEN=$(curl -sf -X POST http://127.0.0.1:8090/api/collections/_superusers/auth-with-password \
  -H "Content-Type: application/json" \
  -d "{\"identity\":\"${PB_ADMIN_EMAIL}\",\"password\":\"${PB_ADMIN_PASSWORD}\"}" \
  | jq -r '.token')

if [ -z "${TOKEN}" ] || [ "${TOKEN}" = "null" ]; then
  echo "ERROR: Could not authenticate to PocketBase" >&2
  exit 1
fi

AUTH="Authorization: Bearer ${TOKEN}"

# ---------------------------------------------------------------------------
# Collections
# ---------------------------------------------------------------------------

# operators collection
echo "==> Creating operators collection..."
curl -sf -X POST http://127.0.0.1:8090/api/collections \
  -H "Content-Type: application/json" \
  -H "${AUTH}" \
  -d '{
    "name": "operators",
    "type": "auth",
    "schema": [
      {"name":"company_name","type":"text","required":true},
      {"name":"contact_name","type":"text","required":true},
      {"name":"phone","type":"text"},
      {"name":"active","type":"bool","required":true,"options":{"default":true}}
    ],
    "listRule": "@request.auth.id != \"\"",
    "viewRule": "@request.auth.id != \"\"",
    "createRule": null,
    "updateRule": null,
    "deleteRule": null
  }' | jq -r '"operators collection: \(.id // .message)"' || echo "==> operators collection may already exist"

# Get operators collection id
OPERATORS_ID=$(curl -sf http://127.0.0.1:8090/api/collections/operators \
  -H "${AUTH}" | jq -r '.id')

# stream_assignments collection
echo "==> Creating stream_assignments collection..."
curl -sf -X POST http://127.0.0.1:8090/api/collections \
  -H "Content-Type: application/json" \
  -H "${AUTH}" \
  -d "{
    \"name\": \"stream_assignments\",
    \"type\": \"base\",
    \"schema\": [
      {\"name\":\"operator\",\"type\":\"relation\",\"required\":true,\"options\":{\"collectionId\":\"${OPERATORS_ID}\",\"cascadeDelete\":true,\"maxSelect\":1}},
      {\"name\":\"stream_name\",\"type\":\"text\",\"required\":true},
      {\"name\":\"stream_token\",\"type\":\"text\",\"required\":true},
      {\"name\":\"srt_passphrase\",\"type\":\"text\",\"required\":true},
      {\"name\":\"output_port\",\"type\":\"number\",\"required\":true},
      {\"name\":\"enabled\",\"type\":\"bool\",\"required\":true,\"options\":{\"default\":true}},
      {\"name\":\"notes\",\"type\":\"text\"}
    ],
    \"listRule\": \"@request.auth.id = operator.id\",
    \"viewRule\": \"@request.auth.id = operator.id\",
    \"createRule\": null,
    \"updateRule\": null,
    \"deleteRule\": null
  }" | jq -r '"stream_assignments collection: \(.id // .message)"' || echo "==> stream_assignments may already exist"

echo "==> PocketBase schema configured"

# ---------------------------------------------------------------------------
# Operator portal static frontend
# ---------------------------------------------------------------------------
mkdir -p /var/www/onboard

cat > /var/www/onboard/index.html << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Castology — Operator Portal</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: #0f1117;
      color: #e2e8f0;
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
    }

    .card {
      background: #1a1d27;
      border: 1px solid #2d3148;
      border-radius: 12px;
      padding: 2.5rem;
      width: 100%;
      max-width: 420px;
    }

    .logo {
      text-align: center;
      margin-bottom: 2rem;
    }

    .logo h1 {
      font-size: 1.5rem;
      font-weight: 700;
      color: #fff;
      letter-spacing: -0.5px;
    }

    .logo p {
      color: #64748b;
      font-size: 0.875rem;
      margin-top: 0.25rem;
    }

    label {
      display: block;
      font-size: 0.8rem;
      font-weight: 500;
      color: #94a3b8;
      margin-bottom: 0.4rem;
      text-transform: uppercase;
      letter-spacing: 0.05em;
    }

    input {
      width: 100%;
      padding: 0.65rem 0.9rem;
      background: #0f1117;
      border: 1px solid #2d3148;
      border-radius: 6px;
      color: #e2e8f0;
      font-size: 0.95rem;
      margin-bottom: 1.2rem;
      outline: none;
      transition: border-color 0.15s;
    }

    input:focus { border-color: #6366f1; }

    button {
      width: 100%;
      padding: 0.75rem;
      background: #6366f1;
      color: #fff;
      border: none;
      border-radius: 6px;
      font-size: 1rem;
      font-weight: 600;
      cursor: pointer;
      transition: background 0.15s;
    }

    button:hover { background: #4f46e5; }
    button:disabled { background: #374151; cursor: not-allowed; }

    .error {
      background: #2d1515;
      border: 1px solid #7f1d1d;
      color: #fca5a5;
      border-radius: 6px;
      padding: 0.65rem 0.9rem;
      font-size: 0.875rem;
      margin-bottom: 1rem;
      display: none;
    }

    /* Dashboard */
    #dashboard { display: none; }

    .welcome {
      font-size: 1.1rem;
      font-weight: 600;
      color: #fff;
      margin-bottom: 0.25rem;
    }

    .subtitle {
      color: #64748b;
      font-size: 0.875rem;
      margin-bottom: 2rem;
    }

    .stream-card {
      background: #0f1117;
      border: 1px solid #2d3148;
      border-radius: 8px;
      padding: 1.25rem;
      margin-bottom: 1rem;
    }

    .stream-card h3 {
      font-size: 0.9rem;
      font-weight: 600;
      color: #a5b4fc;
      margin-bottom: 1rem;
      text-transform: uppercase;
      letter-spacing: 0.05em;
    }

    .stream-field {
      margin-bottom: 0.75rem;
    }

    .stream-field label {
      margin-bottom: 0.2rem;
      font-size: 0.75rem;
    }

    .uri-box {
      display: flex;
      gap: 0.5rem;
      align-items: center;
    }

    .uri-box input {
      margin-bottom: 0;
      font-family: "SF Mono", "Fira Code", monospace;
      font-size: 0.78rem;
      flex: 1;
    }

    .copy-btn {
      width: auto;
      padding: 0.5rem 0.9rem;
      font-size: 0.8rem;
      background: #1e293b;
      border: 1px solid #334155;
      white-space: nowrap;
    }

    .copy-btn:hover { background: #334155; }

    .status-badge {
      display: inline-block;
      padding: 0.2rem 0.6rem;
      border-radius: 9999px;
      font-size: 0.75rem;
      font-weight: 600;
    }

    .status-active   { background: #14532d; color: #86efac; }
    .status-inactive { background: #450a0a; color: #fca5a5; }

    .logout-btn {
      background: transparent;
      border: 1px solid #2d3148;
      color: #94a3b8;
      margin-top: 1.5rem;
      font-weight: 400;
    }

    .logout-btn:hover { background: #1e293b; }

    .no-streams {
      text-align: center;
      color: #64748b;
      padding: 2rem 0;
      font-size: 0.9rem;
    }
  </style>
</head>
<body>

<!-- Login -->
<div class="card" id="login-card">
  <div class="logo">
    <h1>Castology</h1>
    <p>Operator Portal</p>
  </div>
  <div class="error" id="login-error"></div>
  <div>
    <label for="email">Email</label>
    <input type="email" id="email" placeholder="operator@example.com" autocomplete="username">
    <label for="password">Password</label>
    <input type="password" id="password" placeholder="••••••••" autocomplete="current-password">
    <button id="login-btn" onclick="login()">Sign In</button>
  </div>
</div>

<!-- Dashboard -->
<div class="card" id="dashboard">
  <div class="logo" style="text-align:left; margin-bottom:1rem;">
    <h1>Castology</h1>
  </div>
  <div class="welcome" id="welcome-name"></div>
  <div class="subtitle">Your stream connection details</div>
  <div id="streams-container"></div>
  <button class="logout-btn" onclick="logout()">Sign out</button>
</div>

<script>
  const PB_URL = '/api';
  const STREAMING_IP = '${STREAMING_PUBLIC_IP}';
  const SRT_INGEST_PORT = ${SRT_INGEST_PORT};
  const SRT_OUTPUT_PORTS = [$(echo "${SRT_OUTPUT_PORTS}" | sed 's/,/, /g')];

  let token = localStorage.getItem('pb_token');
  let userData = null;

  if (token) tryAutoLogin();

  async function login() {
    const email = document.getElementById('email').value.trim();
    const password = document.getElementById('password').value;
    const btn = document.getElementById('login-btn');
    const err = document.getElementById('login-error');

    err.style.display = 'none';
    btn.disabled = true;
    btn.textContent = 'Signing in...';

    try {
      const res = await fetch(PB_URL + '/collections/operators/auth-with-password', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ identity: email, password })
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.message || 'Invalid credentials');

      token = data.token;
      userData = data.record;
      localStorage.setItem('pb_token', token);
      showDashboard();
    } catch (e) {
      err.textContent = e.message;
      err.style.display = 'block';
    } finally {
      btn.disabled = false;
      btn.textContent = 'Sign In';
    }
  }

  async function tryAutoLogin() {
    try {
      const res = await fetch(PB_URL + '/collections/operators/auth-refresh', {
        method: 'POST',
        headers: { 'Authorization': token }
      });
      if (!res.ok) { localStorage.removeItem('pb_token'); return; }
      const data = await res.json();
      token = data.token;
      userData = data.record;
      localStorage.setItem('pb_token', token);
      showDashboard();
    } catch { localStorage.removeItem('pb_token'); }
  }

  async function showDashboard() {
    document.getElementById('login-card').style.display = 'none';
    document.getElementById('dashboard').style.display = 'block';
    document.getElementById('welcome-name').textContent =
      'Welcome, ' + (userData.company_name || userData.email);

    if (!userData.active) {
      document.getElementById('streams-container').innerHTML =
        '<div class="no-streams">Your account is currently inactive. Please contact support.</div>';
      return;
    }

    // Fetch stream assignments
    const res = await fetch(
      PB_URL + '/collections/stream_assignments/records?expand=operator&perPage=50', {
      headers: { 'Authorization': token }
    });
    const data = await res.json();
    renderStreams(data.items || []);
  }

  function buildSrtUri(assignment) {
    const port = assignment.output_port;
    const streamId = encodeURIComponent(assignment.stream_name + '/' + assignment.stream_token);
    let uri = 'srt://' + STREAMING_IP + ':' + port
      + '?streamid=' + streamId
      + '&latency=1000'
      + '&mode=caller';
    if (assignment.srt_passphrase) {
      uri += '&pbkeylen=16&passphrase=' + encodeURIComponent(assignment.srt_passphrase);
    }
    return uri;
  }

  function renderStreams(assignments) {
    const container = document.getElementById('streams-container');
    if (assignments.length === 0) {
      container.innerHTML = '<div class="no-streams">No streams assigned yet.<br>Please contact support.</div>';
      return;
    }

    container.innerHTML = assignments.map(a => {
      const uri = buildSrtUri(a);
      const statusClass = a.enabled ? 'status-active' : 'status-inactive';
      const statusText = a.enabled ? 'Active' : 'Disabled';
      return \`
        <div class="stream-card">
          <h3>\${a.stream_name} <span class="status-badge \${statusClass}">\${statusText}</span></h3>
          \${!a.enabled ? '<p style="color:#fca5a5;font-size:0.85rem;margin-bottom:0.75rem;">This stream is currently disabled.</p>' : ''}
          <div class="stream-field">
            <label>SRT Stream URL</label>
            <div class="uri-box">
              <input type="text" value="\${uri}" readonly onclick="this.select()">
              <button class="copy-btn" onclick="copyText('\${uri}', this)">Copy</button>
            </div>
          </div>
          <div class="stream-field">
            <label>Host</label>
            <div class="uri-box">
              <input type="text" value="\${STREAMING_IP}" readonly onclick="this.select()">
              <button class="copy-btn" onclick="copyText('\${STREAMING_IP}', this)">Copy</button>
            </div>
          </div>
          <div class="stream-field">
            <label>Port</label>
            <div class="uri-box">
              <input type="text" value="\${a.output_port}" readonly onclick="this.select()">
            </div>
          </div>
          <div class="stream-field">
            <label>Stream ID</label>
            <div class="uri-box">
              <input type="text" value="\${a.stream_name}/\${a.stream_token}" readonly onclick="this.select()">
              <button class="copy-btn" onclick="copyText('\${a.stream_name}/\${a.stream_token}', this)">Copy</button>
            </div>
          </div>
          \${a.srt_passphrase ? \`
          <div class="stream-field">
            <label>Passphrase</label>
            <div class="uri-box">
              <input type="password" value="\${a.srt_passphrase}" readonly onclick="this.type='text';this.select()">
              <button class="copy-btn" onclick="copyText('\${a.srt_passphrase}', this)">Copy</button>
            </div>
          </div>\` : ''}
        </div>
      \`;
    }).join('');
  }

  async function copyText(text, btn) {
    await navigator.clipboard.writeText(text);
    const orig = btn.textContent;
    btn.textContent = 'Copied!';
    setTimeout(() => btn.textContent = orig, 1500);
  }

  function logout() {
    localStorage.removeItem('pb_token');
    token = null;
    userData = null;
    document.getElementById('dashboard').style.display = 'none';
    document.getElementById('login-card').style.display = 'block';
  }

  // Allow Enter key to submit login
  document.addEventListener('keydown', e => {
    if (e.key === 'Enter' && document.getElementById('login-card').style.display !== 'none') {
      login();
    }
  });
</script>
</body>
</html>
HTMLEOF

echo "==> Operator portal deployed to /var/www/onboard"
echo "==> PocketBase admin UI: http://localhost:8090/_/"
echo "==> PocketBase setup complete"
