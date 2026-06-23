#!/bin/bash
set -e
cd "$(dirname "$0")"

source ../../../common.sh
source ../../../parameter.sh

NS=coder
RESULT_DIR=result
CONFIGMAP_NAME=coder-template-render-config

CONFIG_KEYS=(
    CODE_SERVER_MIRROR_URL
    STORAGE_CLASS_NAME
    WORKSPACE_IMAGE_REGISTRY_REPO
    WORKSPACE_IMAGE_BASIC_TAG
    WORKSPACE_IMAGE_CPP_TAG
    WORKSPACE_IMAGE_WEB_TAG
    AI_CONNECTOR_DISPLAY_NAME
)

RENDER_PLACEHOLDERS=(
    BRAND_PREFIX
    DOMAIN
    BRAND_DISPLAY_NAME
    CODE_SERVER_MIRROR_URL
    STORAGE_CLASS_NAME
    WORKSPACE_IMAGE_REGISTRY_REPO
    WORKSPACE_IMAGE_BASIC
    WORKSPACE_IMAGE_CPP
    WORKSPACE_IMAGE_WEB
    DEFAULT_REGISTRY_SERVER
    AI_CONNECTOR_DISPLAY_NAME
)

for PLACEHOLDER in "${CONFIG_KEYS[@]}"; do
    printf -v "$PLACEHOLDER" '%s' ""
done

BRAND_DISPLAY_NAME="${BRAND_PREFIX^}"

function namespace_is_available() {
    kubectl get namespace "$NS" >/dev/null 2>&1
}

function load_render_config() {
    local CONFIG_DATA=""
    local KEY=""
    local VALUE=""
    local PLACEHOLDER=""
    local LOADED=false

    if ! namespace_is_available; then
        log_warn "namespace $NS is not available, skip loading $CONFIGMAP_NAME."
        return
    fi

    CONFIG_DATA=$(kubectl -n "$NS" get configmap "$CONFIGMAP_NAME" -o go-template='{{range $key, $value := .data}}{{printf "%s\t%s\n" $key $value}}{{end}}' 2>/dev/null || true)
    if [ -z "$CONFIG_DATA" ]; then
        return
    fi

    while IFS=$'\t' read -r KEY VALUE; do
        for PLACEHOLDER in "${CONFIG_KEYS[@]}"; do
            if [ "$KEY" != "$PLACEHOLDER" ]; then
                continue
            fi
            if [ -n "${!PLACEHOLDER}" ]; then
                break
            fi
            if [ -n "$VALUE" ]; then
                printf -v "$PLACEHOLDER" '%s' "$VALUE"
                LOADED=true
            fi
            break
        done
    done <<<"$CONFIG_DATA"

    if [ "$LOADED" == true ]; then
        log_info "reuse existing configmap $CONFIGMAP_NAME."
    fi
}

function set_derived_defaults() {
    DEFAULT_CODE_SERVER_MIRROR_URL="https://bin.${DOMAIN}/artifactory/general/mirrors/code-server"
    DEFAULT_STORAGE_CLASS_NAME="$DEFAULT_STORAGE_CLASS"
    DEFAULT_WORKSPACE_IMAGE_REGISTRY_REPO="hub.bin.${DOMAIN}/${BRAND_PREFIX}/coder-workspace"
    DEFAULT_WORKSPACE_IMAGE_BASIC_TAG="basic"
    DEFAULT_WORKSPACE_IMAGE_CPP_TAG="cpp"
    DEFAULT_WORKSPACE_IMAGE_WEB_TAG="web"
    DEFAULT_AI_CONNECTOR_DISPLAY_NAME="${BRAND_DISPLAY_NAME} AI 连接令牌"
}

function prompt_render_config() {
    set_derived_defaults

    CODE_SERVER_MIRROR_URL="${CODE_SERVER_MIRROR_URL:-$(prompt_with_default "" "code-server mirror URL" "$DEFAULT_CODE_SERVER_MIRROR_URL")}"
    STORAGE_CLASS_NAME="${STORAGE_CLASS_NAME:-$(prompt_with_default "" "workspace storage class" "$DEFAULT_STORAGE_CLASS_NAME")}"
    WORKSPACE_IMAGE_REGISTRY_REPO="${WORKSPACE_IMAGE_REGISTRY_REPO:-$(prompt_with_default "" "workspace image registry repository" "$DEFAULT_WORKSPACE_IMAGE_REGISTRY_REPO")}"
    WORKSPACE_IMAGE_BASIC_TAG="${WORKSPACE_IMAGE_BASIC_TAG:-$(prompt_with_default "" "basic workspace image tag" "$DEFAULT_WORKSPACE_IMAGE_BASIC_TAG")}"
    WORKSPACE_IMAGE_BASIC="$WORKSPACE_IMAGE_REGISTRY_REPO:$WORKSPACE_IMAGE_BASIC_TAG"
    WORKSPACE_IMAGE_CPP_TAG="${WORKSPACE_IMAGE_CPP_TAG:-$(prompt_with_default "" "C++ workspace image tag" "$DEFAULT_WORKSPACE_IMAGE_CPP_TAG")}"
    WORKSPACE_IMAGE_CPP="$WORKSPACE_IMAGE_REGISTRY_REPO:$WORKSPACE_IMAGE_CPP_TAG"
    WORKSPACE_IMAGE_WEB_TAG="${WORKSPACE_IMAGE_WEB_TAG:-$(prompt_with_default "" "Web workspace image tag" "$DEFAULT_WORKSPACE_IMAGE_WEB_TAG")}"
    WORKSPACE_IMAGE_WEB="$WORKSPACE_IMAGE_REGISTRY_REPO:$WORKSPACE_IMAGE_WEB_TAG"
    DEFAULT_REGISTRY_SERVER=$(normalize_registry_host "$WORKSPACE_IMAGE_REGISTRY_REPO")
    AI_CONNECTOR_DISPLAY_NAME="${AI_CONNECTOR_DISPLAY_NAME:-$(prompt_with_default "" "AI connector parameter display name" "$DEFAULT_AI_CONNECTOR_DISPLAY_NAME")}"
}

function save_render_config() {
    if ! namespace_is_available; then
        log_warn "namespace $NS is not available, skip saving $CONFIGMAP_NAME."
        return
    fi

    apply_configmap_vars "$NS" "$CONFIGMAP_NAME" \
        CODE_SERVER_MIRROR_URL=CODE_SERVER_MIRROR_URL \
        STORAGE_CLASS_NAME=STORAGE_CLASS_NAME \
        WORKSPACE_IMAGE_REGISTRY_REPO=WORKSPACE_IMAGE_REGISTRY_REPO \
        WORKSPACE_IMAGE_BASIC_TAG=WORKSPACE_IMAGE_BASIC_TAG \
        WORKSPACE_IMAGE_CPP_TAG=WORKSPACE_IMAGE_CPP_TAG \
        WORKSPACE_IMAGE_WEB_TAG=WORKSPACE_IMAGE_WEB_TAG \
        AI_CONNECTOR_DISPLAY_NAME=AI_CONNECTOR_DISPLAY_NAME
}

function render_file() {
    local SRC="$1"
    local DEST="$2"
    local CONTENT=""
    local PLACEHOLDER=""
    local VALUE=""

    mkdir -p "$(dirname "$DEST")"
    CONTENT=$(<"$SRC")
    for PLACEHOLDER in "${RENDER_PLACEHOLDERS[@]}"; do
        VALUE="${!PLACEHOLDER}"
        CONTENT="${CONTENT//__${PLACEHOLDER}__/$VALUE}"
    done
    printf '%s\n' "$CONTENT" >"$DEST"
    if [ -x "$SRC" ]; then
        chmod +x "$DEST"
    fi
}

function render_templates() {
    local SRC=""
    local DEST=""

    rm -rf "$RESULT_DIR"
    mkdir -p "$RESULT_DIR"
    while IFS= read -r -d '' SRC; do
        DEST="$RESULT_DIR/$SRC"
        render_file "$SRC" "$DEST"
    done < <(find k8s -type f -print0 | sort -z)
}

load_render_config
prompt_render_config
save_render_config
render_templates
log_info "rendered templates to $RESULT_DIR"
