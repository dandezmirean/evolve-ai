#!/usr/bin/env bash
# core/inbox/sources/webhook.sh — Webhook listener adapter for evolve-ai
# Starts a simple HTTP listener that accepts POST requests and writes body
# to inbox/pending/.

# ---------------------------------------------------------------------------
# source_webhook_start <port> <output_dir> [auth_token]
# Starts a lightweight HTTP listener using Python's http.server.
# Accepts POST requests and writes body to output_dir.
# This is a minimal implementation — production use would need something
# more robust (e.g., a proper HTTP server).
# ---------------------------------------------------------------------------
source_webhook_start() {
    local port="$1"
    local output_dir="$2"
    local auth_token="${3:-}"

    mkdir -p "$output_dir"

    echo "[source:webhook] Starting webhook listener on port $port"
    echo "[source:webhook] Output directory: $output_dir"

    # Use a Python one-liner for the HTTP server
    python3 -c "
import http.server
import json
import os
import datetime

class WebhookHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        auth_token = '$auth_token'
        if auth_token:
            provided = self.headers.get('Authorization', '')
            if provided != 'Bearer ' + auth_token:
                self.send_response(401)
                self.end_headers()
                self.wfile.write(b'Unauthorized')
                return

        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length).decode('utf-8')

        if body.strip():
            now = datetime.datetime.utcnow()
            ts = now.strftime('%Y-%m-%d-%H%M%S')
            name = self.path.strip('/') or 'webhook'
            name = name.replace('/', '-')
            filename = f'{name}-{ts}.md'
            filepath = os.path.join('$output_dir', filename)

            with open(filepath, 'w') as f:
                f.write(f'# {name} — Webhook Payload\n')
                f.write(f'Source: {name} (webhook)\n')
                f.write(f'Date: {now.isoformat()}Z\n\n')
                f.write(body)
                f.write('\n')

            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'OK')
        else:
            self.send_response(204)
            self.end_headers()

    def log_message(self, format, *args):
        pass  # Suppress default logging

server = http.server.HTTPServer(('0.0.0.0', $port), WebhookHandler)
print(f'[source:webhook] Listening on port $port')
server.serve_forever()
" &

    echo $!
}

# ---------------------------------------------------------------------------
# source_webhook_handle <request_body> <name> <output_dir>
# Processes a single webhook payload, writes to file.
# ---------------------------------------------------------------------------
source_webhook_handle() {
    local request_body="$1"
    local name="$2"
    local output_dir="$3"

    mkdir -p "$output_dir"

    if [[ -z "$request_body" ]]; then
        echo "[source:webhook] Empty request body — skipping" >&2
        return 0
    fi

    local timestamp
    timestamp="$(date +%Y-%m-%d-%H%M%S)"
    local iso_date
    iso_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    local out_file="$output_dir/${name}-${timestamp}.md"
    cat > "$out_file" <<EOF
# ${name} — Webhook Payload
Source: ${name} (webhook)
Date: ${iso_date}

${request_body}
EOF

    echo "[source:webhook] Wrote payload from '$name' to $out_file"
}
