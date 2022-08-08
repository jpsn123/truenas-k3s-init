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
: "${UPSTREAM_URL:?}" "${CODE_SERVER_OS:?}" "${CODE_SERVER_ARCH:?}"
JFROG_ARTIFACTORY_URL="${JFROG_ARTIFACTORY_URL%/}"
mirror_validate_config "$JFROG_ARTIFACTORY_URL" "$JFROG_TOKEN" "$MIRROR_PATH" "$KEEP_VERSIONS" "$REQUEST_TIMEOUT" || exit 1
if [[ ! "$UPSTREAM_URL" =~ ^https://github\.com/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]] ||
    [[ ! "$CODE_SERVER_OS" =~ ^[a-zA-Z0-9]+$ ]] || [[ ! "$CODE_SERVER_ARCH" =~ ^[a-zA-Z0-9]+$ ]]; then
    log_error "invalid upstream repository or target platform."
    exit 1
fi
LATEST_URL=$(curl -fsSLI --proto '=https' --proto-redir '=https' --max-time "$REQUEST_TIMEOUT" \
    -o /dev/null -w '%{url_effective}' "$UPSTREAM_URL/releases/latest")
if [[ "$LATEST_URL" != "$UPSTREAM_URL/releases/tag/"* ]]; then
    log_error "failed to resolve the latest release tag."
    exit 1
fi
VERSION="${LATEST_URL#"$UPSTREAM_URL/releases/tag/"}"
VERSION="${VERSION#v}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log_error "latest release is not a stable version: $VERSION"
    exit 1
fi
FILE="code-server-$VERSION-$CODE_SERVER_OS-$CODE_SERVER_ARCH.tar.gz"
# 0 exists; 1 only a definitive 404; 2 is a real error and must abort.
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
        -o "$WORK_DIR/$FILE" "$UPSTREAM_URL/releases/download/v$VERSION/$FILE"
    [ -s "$WORK_DIR/$FILE" ] || { log_error "downloaded artifact is empty."; exit 1; }
    log_info "uploading $FILE"
    jfrog_upload "$JFROG_ARTIFACTORY_URL" "$JFROG_TOKEN" "$MIRROR_PATH/$FILE" "$WORK_DIR/$FILE" "$REQUEST_TIMEOUT"
fi
mirror_publish_properties "$JFROG_ARTIFACTORY_URL" "$JFROG_TOKEN" "$MIRROR_PATH" "$REQUEST_TIMEOUT" \
    "$FILE" "$VERSION" code_server
mirror_cleanup_versions "$JFROG_ARTIFACTORY_URL" "$JFROG_TOKEN" "$MIRROR_PATH" "$REQUEST_TIMEOUT" \
    "$KEEP_VERSIONS" "$FILE" "^code-server-(?<version>[0-9]+\\.[0-9]+\\.[0-9]+)-$CODE_SERVER_OS-$CODE_SERVER_ARCH\\.tar\\.gz$"
log_info "code-server v$VERSION is ready in JFrog."
