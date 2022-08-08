#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/liblog.sh"
source "$SCRIPT_DIR/lib/libjfrog.sh"
source "$SCRIPT_DIR/mirror.sh"

# Entry scripts own the working directory and its cleanup; libraries never do.
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

: "${JFROG_ARTIFACTORY_URL:?}" "${JFROG_TOKEN:?}" "${MIRROR_PATH:?}" "${KEEP_VERSIONS:?}" "${REQUEST_TIMEOUT:?}"
: "${RELEASE_API:?}" "${PUBLISHER:?}" "${MAX_DOWNLOAD:?}" "${MAX_UNPACKED:?}"
JFROG_ARTIFACTORY_URL="${JFROG_ARTIFACTORY_URL%/}"
mirror_validate_config "$JFROG_ARTIFACTORY_URL" "$JFROG_TOKEN" "$MIRROR_PATH" "$KEEP_VERSIONS" "$REQUEST_TIMEOUT" || exit 1
if [[ ! "$RELEASE_API" =~ ^https://api\.github\.com/repos/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+/releases/latest$ ]] ||
    [[ ! "$PUBLISHER" =~ ^[a-z0-9][a-z0-9-]*$ ]] ||
    [[ ! "$MAX_DOWNLOAD" =~ ^[1-9][0-9]*$ ]] || [[ ! "$MAX_UNPACKED" =~ ^[1-9][0-9]*$ ]]; then
    log_error "invalid release API, publisher or archive size limits."
    exit 1
fi
# Reuse this exact release document in the patcher so upstream cannot change between queries.
curl -fsSL --proto '=https' --proto-redir '=https' --max-time "$REQUEST_TIMEOUT" \
    -H 'Accept: application/vnd.github+json' -H 'User-Agent: mirror-jobs-gitlens' \
    -o "$WORK_DIR/release.json" "$RELEASE_API"
TAG=$(jq -er 'select(.draft == false and .prerelease == false) | .tag_name' "$WORK_DIR/release.json")
VERSION="${TAG#v}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log_error "latest GitLens release is not a stable version: $VERSION"
    exit 1
fi
FILE="$PUBLISHER.gitlens-$VERSION.vsix"
# 0 exists; 1 only a definitive 404; 2 is a real error and must abort.
if jfrog_exists "$JFROG_ARTIFACTORY_URL" "$JFROG_TOKEN" "$MIRROR_PATH/$FILE" "$REQUEST_TIMEOUT"; then
    log_info "$FILE already exists in JFrog; skip download and patch."
else
    EXISTS_RC=$?
    if [ "$EXISTS_RC" -ne 1 ]; then
        log_error "artifact existence check failed for $FILE."
        exit "$EXISTS_RC"
    fi
    python3 "$SCRIPT_DIR/gitlens-patch.py" --publisher "$PUBLISHER" \
        --release-file "$WORK_DIR/release.json" --output-dir "$WORK_DIR/output"
    [ -s "$WORK_DIR/output/$FILE" ] || { log_error "patcher did not produce $FILE"; exit 1; }
    log_info "uploading $FILE"
    jfrog_upload "$JFROG_ARTIFACTORY_URL" "$JFROG_TOKEN" "$MIRROR_PATH/$FILE" "$WORK_DIR/output/$FILE" "$REQUEST_TIMEOUT"
fi
mirror_publish_properties "$JFROG_ARTIFACTORY_URL" "$JFROG_TOKEN" "$MIRROR_PATH" "$REQUEST_TIMEOUT" \
    "$FILE" "$VERSION" gitlens
mirror_cleanup_versions "$JFROG_ARTIFACTORY_URL" "$JFROG_TOKEN" "$MIRROR_PATH" "$REQUEST_TIMEOUT" \
    "$KEEP_VERSIONS" "$FILE" "^$PUBLISHER\\.gitlens-(?<version>[0-9]+\\.[0-9]+\\.[0-9]+)\\.vsix$"
log_info "GitLens $VERSION ($PUBLISHER.gitlens) is ready in JFrog."
