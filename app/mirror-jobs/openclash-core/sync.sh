#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/liblog.sh"
source "$SCRIPT_DIR/lib/libjfrog.sh"
source "$SCRIPT_DIR/mirror.sh"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

: "${JFROG_ARTIFACTORY_URL:?}" "${JFROG_TOKEN:?}" "${MIRROR_PATH:?}" "${REQUEST_TIMEOUT:?}"
: "${UPSTREAM_URL:?}"
CORE_GROUP="${CORE_GROUP:-master}"
JFROG_ARTIFACTORY_URL="${JFROG_ARTIFACTORY_URL%/}"
# Cores use mutable filenames rather than a numeric version retention policy.
mirror_validate_config "$JFROG_ARTIFACTORY_URL" "$JFROG_TOKEN" "$MIRROR_PATH" 1 "$REQUEST_TIMEOUT" || exit 1
if [[ ! "$UPSTREAM_URL" =~ ^https://github\.com/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]] ||
    [[ ! "$CORE_GROUP" =~ ^(master|dev)$ ]]; then
    log_error "invalid upstream repository or core group (master/dev required)."
    exit 1
fi
REPOSITORY="${UPSTREAM_URL#https://github.com/}"
# Pin the branch once so the file listing, version file and archives share a snapshot.
curl -fsSL --proto '=https' --proto-redir '=https' --max-time "$REQUEST_TIMEOUT" \
    -H 'Accept: application/vnd.github+json' -H 'User-Agent: mirror-jobs-openclash-core' \
    -o "$WORK_DIR/commit.json" "https://api.github.com/repos/$REPOSITORY/commits/core"
COMMIT=$(jq -er '.sha | select(type == "string" and test("^[0-9a-f]{40}$"))' "$WORK_DIR/commit.json")
TREE=$(jq -er '.commit.tree.sha | select(type == "string" and test("^[0-9a-f]{40}$"))' "$WORK_DIR/commit.json")
curl -fsSL --proto '=https' --proto-redir '=https' --max-time "$REQUEST_TIMEOUT" \
    -H 'Accept: application/vnd.github+json' -H 'User-Agent: mirror-jobs-openclash-core' \
    -o "$WORK_DIR/tree.json" "https://api.github.com/repos/$REPOSITORY/git/trees/$TREE?recursive=1"
jq -er --arg group "$CORE_GROUP" --arg tree "$TREE" '
    if .sha == $tree and .truncated == false and (.tree | type == "array") then .tree
    else error("invalid or truncated core tree") end |
    [.[] | select(.path == ($group + "/core_version") or
        .path == ($group + "/meta/clash-linux-arm64.tar.gz"))] |
    if length == 2 and (map(.path) | unique | length) == length and
        all(.[]; .type == "blob" and .mode == "100644" and
            (.sha | type == "string" and test("^[0-9a-f]{40}$")) and
            (.size | type == "number" and . > 0 and . == floor))
    then .[] | [.path, .sha, .size] | @tsv
    else error("missing or invalid core group files") end
' "$WORK_DIR/tree.json" >"$WORK_DIR/files.tsv"

# Validate every download before publishing anything; Git blob SHA-1 includes a header.
function download_core_file() {
    local FILE="$1" SHA="$2" SIZE="$3" ACTUAL_SHA=""
    mkdir -p "$WORK_DIR/${FILE%/*}" || return 1
    log_info "downloading $FILE"
    curl -fsSL --proto '=https' --proto-redir '=https' --max-time "$REQUEST_TIMEOUT" \
        -o "$WORK_DIR/$FILE" "https://raw.githubusercontent.com/$REPOSITORY/$COMMIT/$FILE" || return 1
    if [ "$(wc -c <"$WORK_DIR/$FILE")" -ne "$SIZE" ]; then
        log_error "downloaded core size mismatch: $FILE"
        return 1
    fi
    ACTUAL_SHA=$({ printf 'blob %s\0' "$SIZE"; cat "$WORK_DIR/$FILE"; } | sha1sum) || return 1
    if [ "${ACTUAL_SHA%% *}" != "$SHA" ]; then
        log_error "downloaded core checksum mismatch: $FILE"
        return 1
    fi
}

# Read the small version file first; do not fetch the archive until it is needed.
while IFS=$'\t' read -r FILE SHA SIZE; do
    if [ "$FILE" = "$CORE_GROUP/core_version" ]; then
        download_core_file "$FILE" "$SHA" "$SIZE"
    else
        CORE_SHA="$SHA"
        CORE_SIZE="$SIZE"
    fi
done <"$WORK_DIR/files.tsv"

# Upstream core_version lists Meta first, then Smart; only Meta is mirrored.
VERSION=""
IFS= read -r VERSION <"$WORK_DIR/$CORE_GROUP/core_version" || [ -n "$VERSION" ]
VERSION="${VERSION%$'\r'}"
if [[ ! "$VERSION" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ ]]; then
    log_error "invalid Meta core version."
    exit 1
fi

REMOTE_VERSION=""
REMOTE_SHA=""
EXISTS_RC=0
jfrog_exists "$JFROG_ARTIFACTORY_URL" "$JFROG_TOKEN" "$MIRROR_PATH/clash-linux-arm64.tar.gz" \
    "$REQUEST_TIMEOUT" || EXISTS_RC=$?
if [ "$EXISTS_RC" -eq 0 ]; then
    PROPERTIES=$(jfrog_get_properties "$JFROG_ARTIFACTORY_URL" "$JFROG_TOKEN" \
        "$MIRROR_PATH/clash-linux-arm64.tar.gz" "$REQUEST_TIMEOUT")
    REMOTE_VERSION=$(jq -r '.openclash_core_version[0] // ""' <<<"$PROPERTIES")
    REMOTE_SHA=$(jq -r '.openclash_core_blob_sha[0] // ""' <<<"$PROPERTIES")
    if [ -z "$REMOTE_VERSION" ]; then
        PROPERTIES=$(jfrog_get_properties "$JFROG_ARTIFACTORY_URL" "$JFROG_TOKEN" \
            "$MIRROR_PATH" "$REQUEST_TIMEOUT")
        REMOTE_VERSION=$(jq -r '.last_version[0] // ""' <<<"$PROPERTIES")
    fi
    if [[ -n "$REMOTE_VERSION" && ! "$REMOTE_VERSION" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ ]] ||
        [[ -n "$REMOTE_SHA" && ! "$REMOTE_SHA" =~ ^[0-9a-f]{40}$ ]]; then
        log_error "invalid stored Meta core version or blob SHA."
        exit 1
    fi
elif [ "$EXISTS_RC" -ne 1 ]; then
    exit 1
fi

# Legacy artifacts may only have a version; once recorded, also check the blob SHA
# so a same-version rebuild or a different core group cannot be mistaken for a match.
if [ "$REMOTE_VERSION" = "$VERSION" ] && [[ -z "$REMOTE_SHA" || "$REMOTE_SHA" = "$CORE_SHA" ]]; then
    log_info "Meta core $VERSION is already mirrored, skipping archive download and upload."
else
    download_core_file "$CORE_GROUP/meta/clash-linux-arm64.tar.gz" "$CORE_SHA" "$CORE_SIZE"
    jfrog_upload "$JFROG_ARTIFACTORY_URL" "$JFROG_TOKEN" "$MIRROR_PATH/clash-linux-arm64.tar.gz" \
        "$WORK_DIR/$CORE_GROUP/meta/clash-linux-arm64.tar.gz" "$REQUEST_TIMEOUT"
fi
if [ "$REMOTE_SHA" != "$CORE_SHA" ]; then
    jfrog_set_properties "$JFROG_ARTIFACTORY_URL" "$JFROG_TOKEN" "$MIRROR_PATH/clash-linux-arm64.tar.gz" \
        "$REQUEST_TIMEOUT" "openclash_core_blob_sha=$CORE_SHA"
fi
mirror_publish_properties "$JFROG_ARTIFACTORY_URL" "$JFROG_TOKEN" "$MIRROR_PATH" "$REQUEST_TIMEOUT" \
    clash-linux-arm64.tar.gz "$VERSION" openclash_core
log_info "OpenClash Meta core ($CORE_GROUP, linux-arm64, $VERSION) is ready in JFrog."
