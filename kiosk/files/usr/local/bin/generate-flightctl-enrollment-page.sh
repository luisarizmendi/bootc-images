#!/usr/bin/env bash
#
# Wait for the Flight Control enrollment QR and URL in the journal.
# Generate the kiosk HTML page once both have been detected, then exit.
#

set -Eeuo pipefail

KIOSK_USER="kiosk"
OUTPUT_HTML="/var/home/kiosk/.config/flightctl-enrollment-page.html"
OUTPUT_DIR="$(dirname "$OUTPUT_HTML")"

if (( EUID != 0 )); then
  echo "ERROR: Run this script as root." >&2
  exit 1
fi

if ! id "$KIOSK_USER" >/dev/null 2>&1; then
  echo "ERROR: User '$KIOSK_USER' does not exist." >&2
  exit 1
fi

if ! command -v journalctl >/dev/null 2>&1; then
  echo "ERROR: journalctl was not found." >&2
  exit 1
fi

install -d \
  --owner="$KIOSK_USER" \
  --group="$KIOSK_USER" \
  --mode=0755 \
  "$OUTPUT_DIR"

html_escape() {
  sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g'
}

write_page() {
  local url_escaped
  local qr_escaped
  local html_tmp

  url_escaped="$(printf '%s' "$ENROLLMENT_URL" | html_escape)"
  qr_escaped="$(printf '%s' "$QR_TEXT" | html_escape)"
  html_tmp="$(mktemp "${OUTPUT_DIR}/.flightctl-enrollment-page.html.XXXXXX")"

  cat >"$html_tmp" <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Ready to be enrolled!</title>

  <style>
    * {
      box-sizing: border-box;
    }

    body {
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: #ffffff;
      color: #202124;
    }

    main {
      width: min(680px, calc(100% - 3rem));
      padding: 2rem;
      text-align: center;
    }

    .check {
      width: 112px;
      height: 112px;
      margin: 0 auto 1.5rem;
      display: grid;
      place-items: center;
      border-radius: 50%;
      background: #e8f5e9;
    }

    .check svg {
      width: 76px;
      height: 76px;
      fill: none;
      stroke: #198754;
      stroke-width: 3;
      stroke-linecap: round;
      stroke-linejoin: round;
    }

    h1 {
      margin: 0;
      font-size: clamp(2rem, 5vw, 3.25rem);
      font-weight: 700;
      letter-spacing: -0.04em;
    }

    p {
      margin: 1rem auto 0;
      max-width: 42rem;
      font-size: clamp(1.05rem, 2vw, 1.35rem);
      line-height: 1.55;
      color: #5f6368;
    }

    .status {
      display: inline-block;
      margin-top: 2rem;
      padding: 0.6rem 1rem;
      border-radius: 999px;
      background: #f1f3f4;
      color: #3c4043;
      font-size: 0.95rem;
      font-weight: 600;
    }

    .enrollment {
      margin-top: 2rem;
      padding-top: 2rem;
      border-top: 1px solid #dadce0;
    }

    .qr-wrapper {
      max-width: 100%;
      overflow-x: auto;
      margin: 1.25rem 0;
      padding: 1rem;
      border-radius: 0.75rem;
      background: #ffffff;
    }

    .qr {
      display: inline-block;
      margin: 0;
      color: #000000;
      background: #ffffff;
      font-family: "DejaVu Sans Mono", "Liberation Mono", monospace;
      font-size: clamp(5px, 1.15vw, 12px);
      font-weight: 700;
      line-height: 0.86;
      letter-spacing: 0;
      text-align: left;
      white-space: pre;
    }

    .enroll-button {
      display: inline-block;
      margin-top: 0.5rem;
      padding: 0.85rem 1.3rem;
      border-radius: 0.55rem;
      background: #0b57d0;
      color: #ffffff;
      font-size: 1rem;
      font-weight: 700;
      text-decoration: none;
    }

    .enroll-button:focus,
    .enroll-button:hover {
      background: #0842a0;
    }

    .enrollment-url {
      display: block;
      margin-top: 1rem;
      overflow-wrap: anywhere;
      color: #0b57d0;
      font-size: 0.85rem;
      text-decoration: none;
    }
  </style>
</head>

<body>
  <main>
    <div class="check" aria-label="Ready">
      <svg viewBox="0 0 24 24" role="img" aria-hidden="true">
        <path d="M5 12.5l4.2 4.2L19.5 6.5"></path>
      </svg>
    </div>

    <h1>Ready to be enrolled!</h1>

    <section class="enrollment" aria-labelledby="enrollment-title">
      <p id="enrollment-title">Scan the QR code or open the enrollment link.</p>

      <div class="qr-wrapper">
        <pre class="qr" aria-label="Flight Control enrollment QR code">${qr_escaped}</pre>
      </div>

      <a class="enroll-button" href="${url_escaped}">
        Open enrollment URL
      </a>

      <a class="enrollment-url" href="${url_escaped}">
        ${url_escaped}
      </a>
    </section>
  </main>
</body>
</html>
EOF

  chown "$KIOSK_USER:$KIOSK_USER" "$html_tmp"
  chmod 0644 "$html_tmp"
  mv -f "$html_tmp" "$OUTPUT_HTML"

  if command -v restorecon >/dev/null 2>&1; then
    restorecon -F "$OUTPUT_HTML" 2>/dev/null || true
  fi

  echo "Flight Control enrollment page generated:"
  echo "  HTML: $OUTPUT_HTML"
  echo "  URL:  $ENROLLMENT_URL"
}

QR_CANDIDATE=""
QR_TEXT=""
ENROLLMENT_URL=""
COLLECTING_QR=0

echo "Waiting for Flight Control enrollment QR and URL..."

# Reads current-boot entries first, then follows new Flight Control log lines.
# The script exits immediately after obtaining one complete QR and URL pair.
while IFS= read -r line; do
  # The QR begins with a full line of █ characters.
  # Do not restart parsing on full █ rows inside an already captured QR.
  if (( ! COLLECTING_QR )) && [[ "$line" =~ ^█+$ ]]; then
    QR_CANDIDATE="${line}"$'\n'
    QR_TEXT=""
    ENROLLMENT_URL=""
    COLLECTING_QR=1
    continue
  fi

  if (( COLLECTING_QR )); then
    if [[ "$line" == "Enroll your device to flightctl"* ]]; then
      QR_TEXT="$QR_CANDIDATE"
      COLLECTING_QR=0
    else
      QR_CANDIDATE+="${line}"$'\n'
    fi
  fi

  if [[ "$line" =~ (https://[^[:space:]]+/edge/enroll/[^[:space:]]+) ]]; then
    ENROLLMENT_URL="${BASH_REMATCH[1]}"
  fi

  if [[ -n "$QR_TEXT" && -n "$ENROLLMENT_URL" ]]; then
    write_page
    exit 0
  fi
done < <(
  journalctl \
    --unit=flightctl-agent.service \
    --boot \
    --lines=250 \
    --follow \
    --no-pager \
    --output=cat
)