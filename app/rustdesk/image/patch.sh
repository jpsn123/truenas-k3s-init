#!/bin/bash
set -e

SCRIPT_DIR="/usr/share/rustdesk-server/static/web"
WEB_DIR="${1:-$SCRIPT_DIR}"
FONT_CDN="https://fonts.gstatic.com/s"

echo "=== RustDesk Web Intranet Patcher ==="
echo "Web directory: $WEB_DIR"

function find_resource_dir() {
    local PREFIX="$1"
    local DIR MATCH=""

    for DIR in "$WEB_DIR/$PREFIX-"*; do
        if [ -d "$DIR" ] && [[ "${DIR##*/}" =~ ^${PREFIX}-[0-9a-f]+$ ]]; then
            if [ -n "$MATCH" ]; then
                printf 'ERROR: Multiple %s resource directories in %s\n' "$PREFIX" "$WEB_DIR" >&2
                return 1
            fi
            MATCH="${DIR##*/}"
        fi
    done
    if [ -z "$MATCH" ]; then
        printf 'ERROR: No %s resource directory in %s\n' "$PREFIX" "$WEB_DIR" >&2
        return 1
    fi
    printf '%s\n' "$MATCH"
}

ASSETS_DIR=$(find_resource_dir assets)
CANVASKIT_DIR=$(find_resource_dir canvaskit)

for FILE in main.dart.js index.html favicon.svg "$ASSETS_DIR/assets/assets/icon.svg" \
    "$CANVASKIT_DIR"/{,chromium/}canvaskit.{js,wasm}; do
    if [ ! -f "$WEB_DIR/$FILE" ] || [ ! -s "$WEB_DIR/$FILE" ]; then
        printf 'ERROR: %s missing or empty in %s\n' "$FILE" "$WEB_DIR" >&2
        exit 1
    fi
done

cp -f "$WEB_DIR/favicon.svg" "$WEB_DIR/$ASSETS_DIR/assets/assets/icon.svg"

# ---------- 1. main.dart.js ----------
# Use the CanvasKit directory discovered in this image.
# Font URLs: variable names are dynamic, only match the fixed URL strings.
echo "[1/3] Patching main.dart.js (CanvasKit + Font URLs -> local)..."

sed -E -i 's|"https://www\.gstatic\.com/flutter-canvaskit/[^/]+/"|"'"$CANVASKIT_DIR"'/"|g' \
    "$WEB_DIR/main.dart.js"
grep -Fq "\"$CANVASKIT_DIR/\"" "$WEB_DIR/main.dart.js" || {
    printf 'ERROR: CanvasKit path replacement failed in %s/main.dart.js\n' "$WEB_DIR" >&2
    exit 1
}

sed -E -i 's|"https://fonts\.gstatic\.com/s/a/"|"fonts/"|g' \
    "$WEB_DIR/main.dart.js"

sed -E -i 's|"https://fonts\.gstatic\.com/s/"|"fonts/"|g' \
    "$WEB_DIR/main.dart.js"

# ---------- 2. index.html ----------
echo "[2/3] Patching index.html (remove Firebase, add fetch interceptor)..."

sed -i '/<script src="libs\/firebase-app\.js/d' "$WEB_DIR/index.html"
sed -i '/<script src="libs\/firebase-analytics\.js/d' "$WEB_DIR/index.html"

sed -i '/const firebaseConfig/,/firebase\.analytics();/d' "$WEB_DIR/index.html"

INTERCEPTOR_FILE=$(mktemp)
trap 'rm -f "$INTERCEPTOR_FILE"' EXIT
cat > "$INTERCEPTOR_FILE" << 'INJECT'
    <script>
      const _origFetch = window.fetch;
      window.fetch = function(url, ...args) {
        if (typeof url === 'string') {
          if (url.includes('googletagmanager.com') ||
              url.includes('firebaseinstallations.googleapis.com') ||
              url.includes('firebase.googleapis.com')) {
            return Promise.resolve(new Response('{}', {
              status: 200,
              headers: { 'Content-Type': 'application/json' }
            }));
          }
        }
        return _origFetch.call(this, url, ...args);
      };
    </script>
INJECT

if ! grep -q '_origFetch' "$WEB_DIR/index.html"; then
    awk -v injector="$INTERCEPTOR_FILE" '
    BEGIN { while ((getline line < injector) > 0) inject = inject "\n" line }
    /<\/body>/ { printf "%s", inject }
    { print }
    ' "$WEB_DIR/index.html" > "$WEB_DIR/index.html.tmp"
    mv "$WEB_DIR/index.html.tmp" "$WEB_DIR/index.html"
fi

# ---------- 3. Fonts ----------
# Dynamically extract all font paths from main.dart.js (names change per build)
echo "[3/3] Downloading fonts..."
mkdir -p "$WEB_DIR/fonts"

FONT_PATHS=$(grep -oE '"([a-z0-9]+/)+[a-zA-Z0-9_-]+\.ttf"' "$WEB_DIR/main.dart.js" | tr -d '"' | sort -u)

count=0
total=0
for font_path in $FONT_PATHS; do
    total=$((total + 1))
    local_path="$WEB_DIR/fonts/$font_path"
    if [ -f "$local_path" ] && [ -s "$local_path" ]; then
        continue
    fi
    mkdir -p "$(dirname "$local_path")"
    url="$FONT_CDN/$font_path"
    echo "  downloading: $font_path"
    if curl -sfL "$url" -o "$local_path"; then
        count=$((count + 1))
    else
        echo "  FAILED: $font_path"
        rm -f "$local_path"
    fi
done

echo "  Done: $count new, $((total - count)) cached"

echo ""
echo "=== All done ==="
