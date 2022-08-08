#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/liblog.sh"
source "$SCRIPT_DIR/lib/libjfrog.sh"
source "$SCRIPT_DIR/mirror.sh"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

: "${JFROG_ARTIFACTORY_URL:?}" "${JFROG_TOKEN:?}" "${MIRROR_PATH:?}" "${KEEP_VERSIONS:?}" "${REQUEST_TIMEOUT:?}"
: "${RELEASE_API:?}"
JFROG_ARTIFACTORY_URL="${JFROG_ARTIFACTORY_URL%/}"
mirror_validate_config "$JFROG_ARTIFACTORY_URL" "$JFROG_TOKEN" "$MIRROR_PATH" "$KEEP_VERSIONS" "$REQUEST_TIMEOUT" || exit 1
if [[ ! "$RELEASE_API" =~ ^https://api\.github\.com/repos/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+/releases/latest$ ]]; then
    log_error "invalid release API."
    exit 1
fi
curl -fsSL --proto '=https' --proto-redir '=https' --max-time "$REQUEST_TIMEOUT" \
    -H 'Accept: application/vnd.github+json' -H 'User-Agent: mirror-jobs-openclash' \
    -o "$WORK_DIR/release.json" "$RELEASE_API"
TAG=$(jq -er 'select(.draft == false and .prerelease == false) | .tag_name' "$WORK_DIR/release.json")
VERSION="${TAG#v}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log_error "latest OpenClash release is not a stable version: $VERSION"
    exit 1
fi
REPOSITORY="${RELEASE_API#https://api.github.com/repos/}"
REPOSITORY="${REPOSITORY%/releases/latest}"
FILES=("luci-app-openclash_${VERSION}_all.ipk" "luci-app-openclash-${VERSION}.apk")
# Validate both assets from the same release document before writing to the mirror.
jq -er --arg ipk "${FILES[0]}" --arg apk "${FILES[1]}" \
    --arg base "https://github.com/$REPOSITORY/releases/download/$TAG/" '
    [.assets[] | select(.name == $ipk or .name == $apk)] |
    if length == 2 and (map(.name) | unique | length) == 2 and
        all(.[]; .state == "uploaded" and (.size | type == "number" and . > 0) and
            .browser_download_url == ($base + .name))
    then .[] | [.name, .browser_download_url] | @tsv
    else error("missing or invalid OpenClash release assets") end
' "$WORK_DIR/release.json" >"$WORK_DIR/assets.tsv"
while IFS=$'\t' read -r FILE URL; do
    if jfrog_exists "$JFROG_ARTIFACTORY_URL" "$JFROG_TOKEN" "$MIRROR_PATH/$FILE" "$REQUEST_TIMEOUT"; then
        log_info "$FILE already exists in JFrog."
    else
        EXISTS_RC=$?
        if [ "$EXISTS_RC" -ne 1 ]; then
            log_error "artifact existence check failed for $FILE."
            exit "$EXISTS_RC"
        fi
        log_info "downloading $FILE"
        curl -fsSL --proto '=https' --proto-redir '=https' --max-time "$REQUEST_TIMEOUT" \
            -o "$WORK_DIR/$FILE" "$URL"
        [ -s "$WORK_DIR/$FILE" ] || { log_error "downloaded artifact is empty."; exit 1; }
        jfrog_upload "$JFROG_ARTIFACTORY_URL" "$JFROG_TOKEN" "$MIRROR_PATH/$FILE" "$WORK_DIR/$FILE" "$REQUEST_TIMEOUT"
    fi
done <"$WORK_DIR/assets.tsv"
for FILE in "${FILES[@]}"; do
    mirror_publish_properties "$JFROG_ARTIFACTORY_URL" "$JFROG_TOKEN" "$MIRROR_PATH" "$REQUEST_TIMEOUT" \
        "$FILE" "$VERSION" openclash
done
mirror_cleanup_versions "$JFROG_ARTIFACTORY_URL" "$JFROG_TOKEN" "$MIRROR_PATH" "$REQUEST_TIMEOUT" \
    "$KEEP_VERSIONS" "${FILES[0]}" '^luci-app-openclash_(?<version>[0-9]+\.[0-9]+\.[0-9]+)_all\.ipk$'
mirror_cleanup_versions "$JFROG_ARTIFACTORY_URL" "$JFROG_TOKEN" "$MIRROR_PATH" "$REQUEST_TIMEOUT" \
    "$KEEP_VERSIONS" "${FILES[1]}" '^luci-app-openclash-(?<version>[0-9]+\.[0-9]+\.[0-9]+)\.apk$'
log_info "OpenClash v$VERSION (ipk/apk) is ready in JFrog."
