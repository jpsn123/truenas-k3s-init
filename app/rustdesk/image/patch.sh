#!/bin/bash
set -e

SCRIPT_DIR="/usr/share/rustdesk-server/static/web"
WEB_DIR="${1:-$SCRIPT_DIR}"
FONT_CDN="https://fonts.gstatic.com/s"

echo "=== RustDesk Web Intranet Patcher ==="
echo "Web directory: $WEB_DIR"

for f in flutter_bootstrap.js flutter.js main.dart.js index.html; do
    if [ ! -f "$WEB_DIR/$f" ]; then
        echo "ERROR: $f not found in $WEB_DIR"
        exit 1
    fi
done

# ---------- 1 & 2. flutter_bootstrap.js + flutter.js ----------
# Replace CanvasKit CDN fallback with local path.
# Stable anchor: the URL "https://www.gstatic.com/flutter-canvaskit" and ".engineRevision"
# Variable names are dynamic - use regex wildcards instead.
echo "[1/4] Patching flutter_bootstrap.js + flutter.js (CanvasKit -> local)..."

sed -E -i 's/\?([a-zA-Z_]+)\("https:\/\/www\.gstatic\.com\/flutter-canvaskit",([a-zA-Z_]+)\.engineRevision\):"canvaskit"/:"canvaskit"/g' \
    "$WEB_DIR/flutter_bootstrap.js" "$WEB_DIR/flutter.js"

# ---------- 3. main.dart.js ----------
# CanvasKit: the hash after flutter-canvaskit/ is dynamic per build.
# Font URLs: variable names are dynamic, only match the fixed URL strings.
echo "[2/4] Patching main.dart.js (CanvasKit + Font URLs -> local)..."

sed -E -i 's|"https://www\.gstatic\.com/flutter-canvaskit/[^/]+/"|"canvaskit/"|g' \
    "$WEB_DIR/main.dart.js"

sed -E -i 's|"https://fonts\.gstatic\.com/s/a/"|"fonts/"|g' \
    "$WEB_DIR/main.dart.js"

sed -E -i 's|"https://fonts\.gstatic\.com/s/"|"fonts/"|g' \
    "$WEB_DIR/main.dart.js"

# ---------- 4. index.html ----------
echo "[3/4] Patching index.html (remove Firebase, add fetch interceptor)..."

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

# ---------- 5. Fonts ----------
# Dynamically extract all font paths from main.dart.js (names change per build)
echo "[4/4] Downloading fonts..."
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
echo "=== Verify CanvasKit ==="
for f in canvaskit/chromium/canvaskit.js canvaskit/chromium/canvaskit.wasm; do
    [ -f "$WEB_DIR/$f" ] && [ -s "$WEB_DIR/$f" ] && echo "  OK: $f" || echo "  MISSING: $f"
done

echo ""
echo "=== All done ==="
