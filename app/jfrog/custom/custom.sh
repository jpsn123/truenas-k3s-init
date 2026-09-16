#!/bin/sh
# JFrog 前端资源定制脚本。
# 由 frontend 容器 postStart 执行，把 ConfigMap 中的资源覆盖到前端 dist 目录。

set -e

CUSTOM_DIR="${CUSTOM_DIR:-/jfrog-custom}"
LOG_FILE="${LOG_FILE:-/tmp/jfrog-frontend-custom.log}"
BRAND_PREFIX="${BRAND_PREFIX:-jfrog}"
BRAND_NAME="$(printf '%s' "$BRAND_PREFIX" | cut -c1 | tr '[:lower:]' '[:upper:]')$(printf '%s' "$BRAND_PREFIX" | cut -c2-)"
BRAND_ARTIFACT="$BRAND_NAME Artifact"
BRAND_PLATFORM="$BRAND_NAME Artifact Platform"
BRAND_REGISTRY="$BRAND_NAME Container Registry"
HASH_PLACEHOLDER="00000000"

: > "$LOG_FILE" 2>/dev/null || true

log() {
    msg="[custom] $*"
    echo "$msg" >&2
    printf '%s\n' "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

resolve_dist_dir() {
    env_name="$1"
    shift
    eval "configured=\${$env_name:-}"

    if [ -n "$configured" ]; then
        if [ -d "$configured" ]; then
            printf '%s\n' "$configured"
            return 0
        fi
        log "warn: configured directory not found $env_name=$configured"
    fi

    for dir in "$@"; do
        if [ -d "$dir" ]; then
            printf '%s\n' "$dir"
            return 0
        fi
    done

    return 1
}

FE_CLIENT_DIST="$(resolve_dist_dir FE_CLIENT_DIST \
    /opt/jfrog/frontend/app/frontend/bin/client/dist \
    /opt/jfrog/artifactory/app/frontend/bin/client/dist)" || {
    log "error: frontend client dist directory not found"
    exit 1
}

FE_MFE_DIST="$(resolve_dist_dir FE_MFE_DIST \
    /opt/jfrog/frontend/app/frontend/bin/client-microfrontend/dist \
    /opt/jfrog/artifactory/app/frontend/bin/client-microfrontend/dist)" || {
    log "error: frontend microfrontend dist directory not found"
    exit 1
}

for candidate in \
    /opt/jfrog/frontend/app/third-party/node/bin/node \
    /opt/jfrog/artifactory/app/third-party/node/bin/node; do
    if [ -x "$candidate" ]; then
        NODE_BIN="$candidate"
        break
    fi
done

[ -n "${NODE_BIN:-}" ] || {
    log "error: bundled Node.js executable not found"
    exit 1
}

log "start frontend customization: BRAND_PREFIX=$BRAND_PREFIX, BRAND_NAME=$BRAND_NAME"
log "resolved frontend paths: client=$FE_CLIENT_DIST, microfrontend=$FE_MFE_DIST, node=$NODE_BIN"

copy_file() {
    src="$1"
    target="$2"

    if [ ! -f "$src" ]; then
        log "skip: source not found $src"
        return 0
    fi
    target_dir=$(dirname "$target")
    if [ ! -d "$target_dir" ]; then
        log "warn: target directory not found $target_dir"
        return 0
    fi
    if cmp -s "$src" "$target"; then
        log "unchanged: $target"
        return 0
    fi

    cp -f "$src" "$target"
    log "replaced: $target"
}

replace_brand_svg() {
    name="$1"
    src="$CUSTOM_DIR/$name.$HASH_PLACEHOLDER.svg"

    if [ ! -f "$src" ]; then
        log "skip: source not found $src"
        return 0
    fi

    case "$name" in
        jfrog)
            patterns="jfrog~*.svg"
            ;;
        logo)
            patterns="logo-*.svg logo.*.svg logo_*.svg"
            ;;
        login_logo)
            patterns="login_logo-*.svg login_logo.*.svg"
            ;;
        login_side)
            patterns="login_side-*.svg login_side.*.svg"
            ;;
    esac

    targets_file="/tmp/jfrog-frontend-custom.${name}.targets.$$"
    : > "$targets_file"
    trap 'rm -f "$targets_file"' EXIT HUP INT TERM

    for pattern in $patterns; do
        find "$FE_MFE_DIST" -type f -name "$pattern" -print >> "$targets_file" 2>/dev/null || true
    done

    if [ ! -s "$targets_file" ]; then
        log "warn: no target svg matched for $name in $FE_MFE_DIST"
        rm -f "$targets_file"
        trap - EXIT HUP INT TERM
        return 0
    fi

    sort -u "$targets_file" | while IFS= read -r target; do
        [ -n "$target" ] || continue
        copy_file "$src" "$target"
    done

    rm -f "$targets_file"
    trap - EXIT HUP INT TERM
}

replace_literal() {
    dir="$1"
    name="$2"
    from="$3"
    to="$4"

    files=$(find "$dir" -type f -name "$name" ! -name '*.map' 2>/dev/null || true)
    [ -n "$files" ] || {
        log "warn: no files matched $dir/$name"
        return 0
    }

    matched=0
    while IFS= read -r file; do
        [ -f "$file" ] || continue
        if grep -qF "$from" "$file"; then
            FROM="$from" TO="$to" FILE="$file" "$NODE_BIN" - <<'NODE'
const fs = require('fs');
const file = process.env.FILE;
const from = process.env.FROM;
const to = process.env.TO;
const value = fs.readFileSync(file, 'utf8');
fs.writeFileSync(file, value.split(from).join(to));
NODE
            log "patched text in $file: $from -> $to"
            matched=1
        fi
    done <<EOF
$files
EOF

    [ "$matched" -eq 1 ] || log "warn: text not found in $dir/$name: $from"
}

patch_footer_server_name() {
    files=$(find "$FE_MFE_DIST" -type f -name 'app-frontend*.js' ! -name '*.map' 2>/dev/null || true)
    [ -n "$files" ] || {
        log "warn: no app-frontend*.js found in $FE_MFE_DIST"
        return 0
    }

    matched=0
    while IFS= read -r file; do
        [ -f "$file" ] || continue
        set +e
        FILE="$file" BRAND_ARTIFACT="$BRAND_ARTIFACT" "$NODE_BIN" - <<'NODE'
const fs = require('fs');
const file = process.env.FILE;
const replacement = process.env.BRAND_ARTIFACT;
const value = fs.readFileSync(file, 'utf8');
const patterns = [
  /(GET_FOOTER[^;]{0,500}?\.serverName\)\s*!=\s*null\?[^:;]{0,80}:)"JFrog"/g,
  /(GET_FOOTER[^;]{0,500}?\.serverName\s*\?\?\s*)"JFrog"/g,
];
let output = value;
for (const pattern of patterns) {
  output = output.replace(pattern, `$1${JSON.stringify(replacement)}`);
}
if (output !== value) {
  fs.writeFileSync(file, output);
  process.exit(0);
}
process.exit(3);
NODE
        status=$?
        set -e
        if [ "$status" -eq 0 ]; then
            log "patched footer serverName fallback in $file"
            matched=1
        elif [ "$status" -ne 3 ]; then
            log "error: failed to patch footer serverName in $file"
            return "$status"
        fi
    done <<EOF
$files
EOF

    [ "$matched" -eq 1 ] || log "warn: footer serverName fallback pattern not found in $FE_MFE_DIST/app-frontend*.js"
}

for name in jfrog logo login_logo login_side; do
    replace_brand_svg "$name"
done

for dir in "$FE_CLIENT_DIST" "$FE_MFE_DIST"; do
    for asset in apple-touch-icon.png favicon-16x16.png favicon-32x32.png favicon.ico favicon.png jfrog.svg; do
        copy_file "$CUSTOM_DIR/$asset" "$dir/$asset"
    done
    replace_literal "$dir" 'index*.ejs' '<title>JFrog</title>' "<title>$BRAND_ARTIFACT</title>"
done

replace_literal "$FE_MFE_DIST" '*.js' 'Welcome to JFrog Container Registry' "Welcome to $BRAND_REGISTRY"
replace_literal "$FE_MFE_DIST" '*.js' 'Welcome To JFrog Platform' "Welcome to $BRAND_PLATFORM"
replace_literal "$FE_MFE_DIST" '*.js' '"Welcome to JFrog"' "\"Welcome to $BRAND_PLATFORM\""
replace_literal "$FE_CLIENT_DIST" '*.js' '"Welcome to JFrog"' "\"Welcome to $BRAND_PLATFORM\""
replace_literal "$FE_MFE_DIST" '*.js' 'the JFrog Platform!' "the $BRAND_PLATFORM!"
patch_footer_server_name

log "frontend customization done"
