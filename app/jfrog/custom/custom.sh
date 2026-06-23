#!/bin/sh
# JFrog 前端资源定制脚本。
# 由 frontend 容器 postStart 执行，把 ConfigMap 中的资源覆盖到前端 dist 目录。

set -e

CUSTOM_DIR="${CUSTOM_DIR:-/jfrog-custom}"
FE_CLIENT_DIST="${FE_CLIENT_DIST:-/opt/jfrog/artifactory/app/frontend/bin/client/dist}"
FE_MFE_DIST="${FE_MFE_DIST:-/opt/jfrog/artifactory/app/frontend/bin/client-microfrontend/dist}"

FIXED_ASSETS="apple-touch-icon.png favicon-16x16.png favicon-32x32.png favicon.ico favicon.png jfrog.svg"
HASHED_SVG_NAMES="jfrog logo login_logo login_side"
HASH_PLACEHOLDER="00000000"
LOG_FILE="${LOG_FILE:-/tmp/jfrog-frontend-custom.log}"
BRAND_PREFIX="${BRAND_PREFIX:-jfrog}"
BRAND_NAME="$(printf '%s' "$BRAND_PREFIX" | cut -c1 | tr '[:lower:]' '[:upper:]')$(printf '%s' "$BRAND_PREFIX" | cut -c2-)"
BRAND_ARTIFACT="$BRAND_NAME Artifact"
BRAND_PLATFORM="$BRAND_NAME Artifact Platform"
BRAND_REGISTRY="$BRAND_NAME Container Registry"

: > "$LOG_FILE" 2>/dev/null || true

log() {
    msg="[custom] $*"
    echo "$msg" >&2
    printf '%s\n' "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

copy_file() {
    src="$1"
    target="$2"

    if [ ! -f "$src" ]; then
        log "skip: source not found $src"
        return 0
    fi
    if [ ! -f "$target" ]; then
        log "warn: target not found $target"
        return 0
    fi

    cp -f "$src" "$target"
    log "replaced: $target"
}

replace_hashed_svg() {
    name="$1"
    src="$CUSTOM_DIR/$name.$HASH_PLACEHOLDER.svg"

    if [ ! -f "$src" ]; then
        log "skip: source not found $src"
        return 0
    fi

    found=0
    for sep in . _ - ~; do
        targets=$(find "$FE_MFE_DIST" -type f -name "$name$sep*.svg" 2>/dev/null || true)
        [ -n "$targets" ] || continue

        echo "$targets" | while read -r target; do
            [ -n "$target" ] || continue
            cp -f "$src" "$target"
            log "replaced: $target"
        done
        found=1
    done

    [ "$found" -eq 1 ] || log "warn: no target svg matched for $name in $FE_MFE_DIST"
}

replace_text() {
    dir="$1"
    name="$2"
    from="$3"
    to="$4"

    files=$(find "$dir" -type f -name "$name" 2>/dev/null || true)
    [ -n "$files" ] || {
        log "warn: no files matched $dir/$name"
        return 0
    }

    matched=0
    for file in $files; do
        [ -f "$file" ] || continue
        if grep -qF "$from" "$file"; then
            sed -i "s|$from|$to|g" "$file"
            log "patched text in $file: $from -> $to"
            matched=1
        fi
    done

    [ "$matched" -eq 1 ] || log "warn: text not found in $dir/$name: $from"
}

replace_footer_server_name() {
    files=$(find "$FE_MFE_DIST" -type f -name 'app-frontend*.js' 2>/dev/null || true)
    [ -n "$files" ] || {
        log "warn: no app-frontend*.js found in $FE_MFE_DIST"
        return 0
    }

    matched=0
    for file in $files; do
        [ -f "$file" ] || continue
        if grep -q 'GET_FOOTER' "$file" && grep -q 'serverName' "$file" && grep -q '"JFrog"' "$file"; then
            sed -i -E "s/(GET_FOOTER[^;]{0,300}serverName[^;]{0,300}:)\"JFrog\"/\\1\"$BRAND_ARTIFACT\"/g" "$file"
            log "patched footer serverName in $file"
            matched=1
        fi
    done

    [ "$matched" -eq 1 ] || log "warn: footer serverName pattern not found in $FE_MFE_DIST/app-frontend*.js"
}

log "start frontend customization: BRAND_PREFIX=$BRAND_PREFIX, BRAND_NAME=$BRAND_NAME"

for name in $HASHED_SVG_NAMES; do
    replace_hashed_svg "$name"
done

for asset in $FIXED_ASSETS; do
    copy_file "$CUSTOM_DIR/$asset" "$FE_CLIENT_DIST/$asset"
done

replace_text "$FE_CLIENT_DIST" 'index*' '<title>JFrog</title>' "<title>$BRAND_ARTIFACT</title>"
replace_text "$FE_MFE_DIST" '*.js' 'Welcome to JFrog Container Registry' "Welcome to $BRAND_REGISTRY"
replace_text "$FE_MFE_DIST" '*.js' 'Welcome To JFrog Platform' "Welcome to $BRAND_PLATFORM"
replace_text "$FE_MFE_DIST" '*.js' '"Welcome to JFrog"' "\"Welcome to $BRAND_PLATFORM\""
replace_text "$FE_CLIENT_DIST" '*.js' '"Welcome to JFrog"' "\"Welcome to $BRAND_PLATFORM\""
replace_text "$FE_MFE_DIST" '*.js' 'the JFrog Platform!' "$BRAND_PLATFORM!"
replace_footer_server_name

log "frontend customization done"
