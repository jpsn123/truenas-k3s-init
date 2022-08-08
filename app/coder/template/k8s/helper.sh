#!/bin/bash
set -e
set -o pipefail

NS=coder
SERVICE_ACCOUNT_NAME=coder-workspace
TOKEN_SECRET_NAME=coder-workspace-token
HELPER_CONFIGMAP_NAME=coder-workspace-helper
DEFAULT_WORKSPACE_IMAGE_REGISTRY_SECRET_NAME=coder-workspace-image-registry
DEFAULT_REGISTRY_SERVER=__DEFAULT_REGISTRY_SERVER__

# 单文件分发，仅内置本工具所需的辅助函数，不依赖部署仓库。
function log_message() {
    local COLOR="$1"
    shift
    if [ -t 2 ]; then
        printf '\033[%sm%s\033[0m\n' "$COLOR" "$*" >&2
    else
        printf '%s\n' "$*" >&2
    fi
}

function log_error() { log_message 31 "$@"; }
function log_info() { log_message 32 "$@"; }
function log_header() { log_message '42;30' "$@"; }
function log_reminder() { log_message 35 "$@"; }

function prompt_with_default() {
    local REMINDER_TEXT="$1"
    local PROMPT_TEXT="$2"
    local DEFAULT_VALUE="${3:-}"
    local INPUT_VALUE=""

    if [ -n "$REMINDER_TEXT" ]; then
        log_reminder "$REMINDER_TEXT"
    fi
    read -r -p "$PROMPT_TEXT${DEFAULT_VALUE:+ [$DEFAULT_VALUE]}: " INPUT_VALUE || {
        log_error "end of input."
        return 1
    }
    printf '%s' "${INPUT_VALUE:-$DEFAULT_VALUE}"
}

function prompt_required() {
    local REMINDER_TEXT="$1"
    local PROMPT_TEXT="$2"
    local READ_OPT="${3:-}"
    local INPUT_VALUE=""
    local READ_ARGS=()

    if [ -n "$READ_OPT" ]; then
        [ "$READ_OPT" == -s ] || { log_error "unsupported read option: $READ_OPT"; return 1; }
        READ_ARGS=(-s)
    fi
    if [ -n "$REMINDER_TEXT" ]; then
        log_reminder "$REMINDER_TEXT"
    fi
    while [ -z "$INPUT_VALUE" ]; do
        read -r "${READ_ARGS[@]}" -p "$PROMPT_TEXT: " INPUT_VALUE || {
            log_error "end of input."
            return 1
        }
        if [ "$READ_OPT" == -s ]; then
            printf '\n' >&2
        fi
    done
    printf '%s' "$INPUT_VALUE"
}

# 先生成 manifest 再 apply；不删除既有资源，也不掩盖 dry-run 失败。
function kube_apply_generated() {
    local TEMP_FILE=""
    local RESULT=0

    TEMP_FILE=$(mktemp) || return 1
    if ! "$@" --dry-run=client -o yaml >"$TEMP_FILE"; then
        rm -f "$TEMP_FILE"
        return 1
    fi
    kubectl apply --server-side --force-conflicts -f "$TEMP_FILE" >/dev/null || RESULT=$?
    rm -f "$TEMP_FILE"
    return "$RESULT"
}

function kube_configmap_get() {
    kubectl -n "$NS" get configmap "$HELPER_CONFIGMAP_NAME" --ignore-not-found \
        -o "go-template={{ with index .data \"$1\" }}{{ . }}{{ end }}"
}

function save_helper_config() {
    local ARGS=(--from-literal="cluster-server=$CLUSTER_SERVER")
    if [ -n "${WORKSPACE_IMAGE_REGISTRY_SECRET_NAME:-}" ]; then
        ARGS+=(--from-literal="workspace-image-registry-secret-name=$WORKSPACE_IMAGE_REGISTRY_SECRET_NAME")
    fi
    kube_apply_generated kubectl -n "$NS" create configmap "$HELPER_CONFIGMAP_NAME" "${ARGS[@]}"
}

function get_current_cluster_server() {
    kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}'
}

function ensure_namespace() {
    kube_apply_generated kubectl create namespace "$NS"
}

function ensure_rbac() {
    kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $SERVICE_ACCOUNT_NAME
  namespace: $NS
---
apiVersion: v1
kind: Secret
metadata:
  name: $TOKEN_SECRET_NAME
  namespace: $NS
  annotations:
    kubernetes.io/service-account.name: $SERVICE_ACCOUNT_NAME
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: $SERVICE_ACCOUNT_NAME
  namespace: $NS
rules:
  - apiGroups:
      - "*"
    resources:
      - "*"
    verbs:
      - "*"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: $SERVICE_ACCOUNT_NAME
  namespace: $NS
subjects:
  - kind: ServiceAccount
    name: $SERVICE_ACCOUNT_NAME
    namespace: $NS
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: $SERVICE_ACCOUNT_NAME
EOF
}

function wait_service_account_token() {
    local TOKEN=""
    local INDEX=0

    while [ "$INDEX" -lt 30 ]; do
        TOKEN=$(kubectl -n "$NS" get secret "$TOKEN_SECRET_NAME" --ignore-not-found \
            -o go-template='{{ with index .data "token" }}{{ . | base64decode }}{{ end }}') || return 1
        if [ -n "$TOKEN" ]; then
            printf '%s' "$TOKEN"
            return 0
        fi
        INDEX=$((INDEX + 1))
        sleep 1
    done

    log_error "failed to wait service account token." >&2
    return 1
}

function get_service_account_ca_data() {
    kubectl -n "$NS" get secret "$TOKEN_SECRET_NAME" -o jsonpath='{.data.ca\.crt}'
}

function ensure_cluster_server_config() {
    local CURRENT_CLUSTER_SERVER=""

    CLUSTER_SERVER=$(kube_configmap_get cluster-server) || return 1
    if [ -z "$CLUSTER_SERVER" ]; then
        CURRENT_CLUSTER_SERVER=$(get_current_cluster_server) || return 1
        if [ -n "$CURRENT_CLUSTER_SERVER" ]; then
            CLUSTER_SERVER=$(prompt_with_default "please input target cluster kubeconfig info." "kubernetes api server" "$CURRENT_CLUSTER_SERVER") || return 1
        else
            CLUSTER_SERVER=$(prompt_required "please input target cluster kubeconfig info." "kubernetes api server" "") || return 1
        fi
        save_helper_config || return 1
    fi
}

function secret_has_docker_config() {
    local SECRET_NAME="$1"
    local DOCKER_CONFIG=""

    DOCKER_CONFIG=$(kubectl -n "$NS" get secret "$SECRET_NAME" --ignore-not-found \
        -o go-template='{{ with index .data ".dockerconfigjson" }}{{ . }}{{ end }}') || return 2
    [ -n "$DOCKER_CONFIG" ]
}

function ensure_workspace_image_registry_secret() {
    local RESULT=0
    local REGISTRY_SERVER=""
    local REGISTRY_USERNAME=""
    local REGISTRY_PASSWORD=""

    WORKSPACE_IMAGE_REGISTRY_SECRET_NAME=$(kube_configmap_get workspace-image-registry-secret-name) || return 1
    if [ -z "$WORKSPACE_IMAGE_REGISTRY_SECRET_NAME" ]; then
        if secret_has_docker_config "$DEFAULT_WORKSPACE_IMAGE_REGISTRY_SECRET_NAME"; then
            WORKSPACE_IMAGE_REGISTRY_SECRET_NAME="$DEFAULT_WORKSPACE_IMAGE_REGISTRY_SECRET_NAME"
        else
            RESULT=$?
            [ "$RESULT" -eq 1 ] || return "$RESULT"
            WORKSPACE_IMAGE_REGISTRY_SECRET_NAME=$(prompt_with_default "please input workspace image registry config." "workspace image registry secret name" "$DEFAULT_WORKSPACE_IMAGE_REGISTRY_SECRET_NAME") || return 1
        fi
    fi

    if secret_has_docker_config "$WORKSPACE_IMAGE_REGISTRY_SECRET_NAME"; then
        log_info "reuse existing secret $WORKSPACE_IMAGE_REGISTRY_SECRET_NAME."
        save_helper_config
        return $?
    else
        RESULT=$?
        [ "$RESULT" -eq 1 ] || return "$RESULT"
    fi

    REGISTRY_SERVER=$(prompt_with_default "" "workspace image registry server" "$DEFAULT_REGISTRY_SERVER") || return 1
    REGISTRY_USERNAME=$(prompt_required "" "workspace image registry username" "") || return 1
    REGISTRY_PASSWORD=$(prompt_required "" "workspace image registry password or token" -s) || return 1
    kube_apply_generated kubectl -n "$NS" create secret docker-registry "$WORKSPACE_IMAGE_REGISTRY_SECRET_NAME" \
        --docker-server="$REGISTRY_SERVER" \
        --docker-username="$REGISTRY_USERNAME" \
        --docker-password="$REGISTRY_PASSWORD" || return 1
    save_helper_config
}

function print_kubeconfig() {
    local TOKEN="$1"
    local CA_DATA="$2"

    cat <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: coder-workspace
    cluster:
      server: $CLUSTER_SERVER
      certificate-authority-data: $CA_DATA
contexts:
  - name: coder-workspace
    context:
      cluster: coder-workspace
      namespace: $NS
      user: coder-workspace
current-context: coder-workspace
users:
  - name: coder-workspace
    user:
      token: $TOKEN

EOF
}

function print_kubeconfig_base64() {
    local TOKEN="$1"
    local CA_DATA="$2"

    print_kubeconfig "$TOKEN" "$CA_DATA" | base64 | tr -d '\r\n' || return 1
    printf '\n'
}

log_header "initial" >&2
ensure_namespace

log_header "create coder workspace rbac" >&2
ensure_rbac
TOKEN=$(wait_service_account_token)
CA_DATA=$(get_service_account_ca_data)
ensure_cluster_server_config

log_header "create workspace image registry secret" >&2
ensure_workspace_image_registry_secret

log_header "kubeconfig" >&2
log_reminder "copy the following base64 kubeconfig into the template kubeconfig variable when use_kubeconfig is true." >&2
print_kubeconfig_base64 "$TOKEN" "$CA_DATA"
