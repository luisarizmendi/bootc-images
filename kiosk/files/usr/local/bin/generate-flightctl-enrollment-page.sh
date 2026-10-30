#!/usr/bin/env bash
#
# Wait for the Flight Control enrollment QR and URL in the journal.
# Create a kiosk HTML page and a QR SVG from the QR emitted by flightctl-agent.
# No qrencode package is required.
#

set -Eeuo pipefail

KIOSK_USER="kiosk"
OUTPUT_HTML="/var/home/kiosk/.config/flightctl-enrollment-page.html"
OUTPUT_DIR="$(dirname "$OUTPUT_HTML")"
OUTPUT_QR_SVG="${OUTPUT_DIR}/flightctl-enrollment-qr.svg"

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

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required to render the QR as SVG." >&2
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

generate_qr_svg() {
  local svg_tmp

  svg_tmp="$(mktemp "${OUTPUT_DIR}/.flightctl-enrollment-qr.svg.XXXXXX")"

  # Flight Control's terminal QR uses:
  #   █ = black upper and lower modules
  #   ▀ = black upper module
  #   ▄ = black lower module
  #     = white upper and lower modules
  #
  # Convert it into a standard SVG made of rectangles, avoiding font issues.
  PYTHONIOENCODING=utf-8 python3 -c '
import sys

rows = [row.rstrip("\r") for row in sys.stdin.read().splitlines()]

if not rows:
    raise SystemExit("No QR rows received")

width = max(len(row) for row in rows)
height = len(rows) * 2
modules = []

for row_number, row in enumerate(rows):
    for column, character in enumerate(row):
        top = row_number * 2
        bottom = top + 1

        if character in ("█", "▀"):
            modules.append(f"M{column} {top}h1v1h-1z")

        if character in ("█", "▄"):
            modules.append(f"M{column} {bottom}h1v1h-1z")

path = "".join(modules)

print(f"""<svg xmlns="http://www.w3.org/2000/svg"
  viewBox="0 0 {width} {height}"
  role="img"
  aria-label="Flight Control enrollment QR code"
  shape-rendering="crispEdges">
  <rect width="{width}" height="{height}" fill="#ffffff"/>
  <path d="{path}" fill="#000000"/>
</svg>""")
' >"$svg_tmp" <<<"$QR_TEXT"

  chown "$KIOSK_USER:$KIOSK_USER" "$svg_tmp"
  chmod 0644 "$svg_tmp"
  mv -f "$svg_tmp" "$OUTPUT_QR_SVG"

  if command -v restorecon >/dev/null 2>&1; then
    restorecon -F "$OUTPUT_QR_SVG" 2>/dev/null || true
  fi
}

write_page() {
  local url_escaped
  local html_tmp

  url_escaped="$(printf '%s' "$ENROLLMENT_URL" | html_escape)"

  generate_qr_svg

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

    .enrollment {
      margin-top: 2rem;
      padding-top: 2rem;
      border-top: 1px solid #dadce0;
    }

    .qr-wrapper {
      width: min(100%, 360px);
      margin: 1.5rem auto;
      padding: 0.75rem;
      background: #ffffff;
    }

    .qr {
      display: block;
      width: 100%;
      height: auto;
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

    <section class="enrollment" aria-labelledby="enrollment-title">
      <div class="qr-wrapper">
        <img
          class="qr"
          src="flightctl-enrollment-qr.svg"
          alt="Flight Control enrollment QR code">
      </div>

      <a class="enroll-button" href="${url_escaped}">
        Open enrollment URL
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
  echo "  QR:   $OUTPUT_QR_SVG"
  echo "  URL:  $ENROLLMENT_URL"
}

QR_CANDIDATE=""
QR_TEXT=""
ENROLLMENT_URL=""
COLLECTING_QR=0

echo "Waiting for Flight Control enrollment QR and URL..."

while IFS= read -r line; do
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