#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./ocr_client.sh [options] PDF_FILE

Options:
  -s, --server URL       OCR API URL (default: $OCR_API_URL or http://127.0.0.1:3001)
  -o, --output DIR       Output directory (default: ocr_result_TIMESTAMP)
  -i, --interval SEC     Polling interval (default: 2)
  -t, --timeout SEC      Timeout per page (default: 600)
  -h, --help             Show this help

Examples:
  ./ocr_client.sh -s http://192.0.2.10:3001 document.pdf
  ./ocr_client.sh -s 'http://[2001:db8::10]:3001' -o output document.pdf
EOF
}

SERVER_URL="${OCR_API_URL:-http://127.0.0.1:3001}"
OUTPUT_DIR=""
POLL_INTERVAL=2
TIMEOUT=600

while [ "$#" -gt 0 ]; do
    case "$1" in
        -s|--server)
            [ "$#" -ge 2 ] || { echo "Error: $1 requires a value" >&2; exit 2; }
            SERVER_URL="$2"
            shift 2
            ;;
        -o|--output)
            [ "$#" -ge 2 ] || { echo "Error: $1 requires a value" >&2; exit 2; }
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -i|--interval)
            [ "$#" -ge 2 ] || { echo "Error: $1 requires a value" >&2; exit 2; }
            POLL_INTERVAL="$2"
            shift 2
            ;;
        -t|--timeout)
            [ "$#" -ge 2 ] || { echo "Error: $1 requires a value" >&2; exit 2; }
            TIMEOUT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "Error: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            break
            ;;
    esac
done

[ "$#" -eq 1 ] || { usage >&2; exit 2; }
PDF_FILE="$1"
SERVER_URL="${SERVER_URL%/}"
OUTPUT_DIR="${OUTPUT_DIR:-ocr_result_$(date +%Y%m%d_%H%M%S)}"

command -v curl >/dev/null || { echo "Error: curl is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "Error: jq is required" >&2; exit 1; }
[ -f "$PDF_FILE" ] || { echo "Error: file not found: $PDF_FILE" >&2; exit 1; }
PDF_FILE_LOWER="$(printf '%s' "$PDF_FILE" | tr '[:upper:]' '[:lower:]')"
case "$PDF_FILE_LOWER" in
    *.pdf) ;;
    *) echo "Error: input must be a PDF file" >&2; exit 1 ;;
esac
[[ "$POLL_INTERVAL" =~ ^[0-9]+$ ]] || { echo "Error: interval must be an integer" >&2; exit 2; }
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || { echo "Error: timeout must be an integer" >&2; exit 2; }

mkdir -p "$OUTPUT_DIR"
UPLOAD_JSON="$OUTPUT_DIR/upload.json"

echo "Uploading: $PDF_FILE"
curl --fail-with-body --silent --show-error \
    -X POST "$SERVER_URL/upload" \
    -F "file=@$PDF_FILE;type=application/pdf" \
    > "$UPLOAD_JSON"

PAGE_FILES=()
while IFS= read -r line; do
    PAGE_FILES+=("$line")
done < <(jq -er '.processed_files[]' "$UPLOAD_JSON")
[ "${#PAGE_FILES[@]}" -gt 0 ] || { echo "Error: no pages returned by server" >&2; exit 1; }
echo "Queued ${#PAGE_FILES[@]} page(s)"

urlencode() {
    jq -rn --arg value "$1" '$value | @uri'
}

for index in "${!PAGE_FILES[@]}"; do
    page_file="${PAGE_FILES[$index]}"
    page_number=$((index + 1))
    encoded_page="$(urlencode "$page_file")"
    started_at="$(date +%s)"

    echo "Waiting for page $page_number/${#PAGE_FILES[@]}: $page_file"
    while :; do
        status_json="$(curl --fail-with-body --silent --show-error \
            "$SERVER_URL/status/$encoded_page")"
        status="$(jq -r '.status' <<< "$status_json")"

        case "$status" in
            completed) break ;;
            pending|processing|not_found) ;;
            *)
                echo "Error: unexpected status '$status' for $page_file" >&2
                exit 1
                ;;
        esac

        if [ $(( $(date +%s) - started_at )) -ge "$TIMEOUT" ]; then
            echo "Error: timed out waiting for $page_file" >&2
            exit 1
        fi
        sleep "$POLL_INTERVAL"
    done

    result_json="$OUTPUT_DIR/page_$(printf '%03d' "$page_number").json"
    curl --fail-with-body --silent --show-error \
        "$SERVER_URL/result/$encoded_page?result_type=both" \
        > "$result_json"

    csv_name="$(jq -er '.result_csv' "$result_json")"
    image_name="$(jq -er '.processed_image' "$result_json")"
    curl --fail-with-body --silent --show-error \
        "$SERVER_URL/download/csv/$(urlencode "$csv_name")" \
        -o "$OUTPUT_DIR/page_$(printf '%03d' "$page_number").csv"
    curl --fail-with-body --silent --show-error \
        "$SERVER_URL/download/image/$(urlencode "$image_name")" \
        -o "$OUTPUT_DIR/page_$(printf '%03d' "$page_number").png"
    echo "Saved page $page_number"
done

echo "Completed. Results: $OUTPUT_DIR"
