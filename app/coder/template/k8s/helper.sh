#!/bin/bash
set -e

NS=coder
SERVICE_ACCOUNT_NAME=coder-workspace
TOKEN_SECRET_NAME=coder-workspace-token
HELPER_CONFIGMAP_NAME=coder-workspace-helper
DEFAULT_WORKSPACE_IMAGE_REGISTRY_SECRET_NAME=coder-workspace-image-registry
DEFAULT_REGISTRY_SERVER=__DEFAULT_REGISTRY_SERVER__

function log_error() {
    printf '\033[31m%s\033[0m\n' "$1"
}

function log_info() {
    printf '\033[32m%s\033[0m\n' "$1"
}

function log_header() {
    printf '\033[42;30m%s\n\033[0m\n' "$1"
}

function log_reminder() {
    printf '\033[35m%s\n\033[0m\n' "$1"
}

function prompt_with_default() {
    local REMINDER_TEXT="$1"
    local PROMPT_TEXT="$2"
    local DEFAULT_VALUE="$3"
    local INPUT_VALUE=""

    if [ -n "$REMINDER_TEXT" ]; then
        log_reminder "$REMINDER_TEXT" >&2
    fi
    if [ -n "$DEFAULT_VALUE" ]; then
        read -p "$PROMPT_TEXT [$DEFAULT_VALUE]: " INPUT_VALUE
        if [ -z "$INPUT_VALUE" ]; then
            INPUT_VALUE="$DEFAULT_VALUE"
        fi
    else
        read -p "$PROMPT_TEXT: " INPUT_VALUE
    fi
    printf '%s' "$INPUT_VALUE"
}

function prompt_required() {
    local REMINDER_TEXT="$1"
    local PROMPT_TEXT="$2"
    local READ_OPT="$3"
    local INPUT_VALUE=""

    if [ -n "$REMINDER_TEXT" ]; then
        log_reminder "$REMINDER_TEXT" >&2
    fi
    while [ -z "$INPUT_VALUE" ]; do
        if [ "$READ_OPT" == "-s" ]; then
            read -s -p "$PROMPT_TEXT: " INPUT_VALUE
            printf '\n' >&2
        else
            read -p "$PROMPT_TEXT: " INPUT_VALUE
        fi
    done
    printf '%s' "$INPUT_VALUE"
}

function apply_configmap() {
    local NS="$1"
    local NAME="$2"
    local TEMP_FILE=""
    local RESULT=0
    shift 2

    TEMP_FILE=$(mktemp) || return 1
    kubectl -n "$NS" create configmap "$NAME" "$@" --dry-run=client -o yaml >"$TEMP_FILE" || { rm -f "$TEMP_FILE"; return 1; }
    kubectl apply --server-side --force-conflicts -f "$TEMP_FILE" || RESULT=$?
    rm -f "$TEMP_FILE"
    return $RESULT
}

function apply_configmap_vars() {
    local NS="$1"
    local NAME="$2"
    local ITEM=""
    local KEY=""
    local VAR=""
    local VALUE=""
    local ARGS=()
    shift 2

    for ITEM in "$@"; do
        KEY="${ITEM%%=*}"
        VAR="${ITEM#*=}"
        VALUE="${!VAR}"
        ARGS+=(--from-literal="$KEY=$VALUE")
    done
    apply_configmap "$NS" "$NAME" "${ARGS[@]}"
}

function get_configmap_value() {
    local NS="$1"
    local NAME="$2"
    local KEY="$3"
    kubectl -n "$NS" get configmap "$NAME" -o go-template="{{ with index .data \"$KEY\" }}{{ . }}{{ end }}" 2>/dev/null || true
}

function load_configmap_vars() {
    local NS="$1"
    local NAME="$2"
    local ITEM=""
    local KEY=""
    local VAR=""
    local VALUE=""
    local LOADED=false
    shift 2

    for ITEM in "$@"; do
        KEY="${ITEM%%=*}"
        VAR="${ITEM#*=}"
        VALUE=$(get_configmap_value "$NS" "$NAME" "$KEY")
        if [ -n "$VALUE" ]; then
            printf -v "$VAR" '%s' "$VALUE"
            LOADED=true
        fi
    done
    if [ "$LOADED" == true ]; then
        log_info "reuse existing configmap $NAME."
    fi
}

function apply_docker_registry_secret() {
    local NS="$1"
    local NAME="$2"
    local SERVER="$3"
    local USERNAME="$4"
    local PASSWORD="$5"
    local TEMP_FILE=""
    local RESULT=0

    TEMP_FILE=$(mktemp) || return 1
    kubectl -n "$NS" create secret docker-registry "$NAME" \
        --docker-server="$SERVER" \
        --docker-username="$USERNAME" \
        --docker-password="$PASSWORD" \
        --dry-run=client -o yaml >"$TEMP_FILE" || { rm -f "$TEMP_FILE"; return 1; }
    kubectl apply --server-side --force-conflicts -f "$TEMP_FILE" || RESULT=$?
    rm -f "$TEMP_FILE"
    return $RESULT
}

function get_current_cluster_server() {
    kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true
}

function ensure_namespace() {
    kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
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
        TOKEN=$(kubectl -n "$NS" get secret "$TOKEN_SECRET_NAME" -o go-template='{{ with index .data "token" }}{{ . | base64decode }}{{ end }}' 2>/dev/null || true)
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

    CLUSTER_SERVER=""
    load_configmap_vars "$NS" "$HELPER_CONFIGMAP_NAME" cluster-server=CLUSTER_SERVER >&2
    if [ -z "$CLUSTER_SERVER" ]; then
        CURRENT_CLUSTER_SERVER=$(get_current_cluster_server)
        if [ -n "$CURRENT_CLUSTER_SERVER" ]; then
            CLUSTER_SERVER=$(prompt_with_default "please input target cluster kubeconfig info." "kubernetes api server" "$CURRENT_CLUSTER_SERVER")
        else
            CLUSTER_SERVER=$(prompt_required "please input target cluster kubeconfig info." "kubernetes api server" "")
        fi
        apply_configmap_vars "$NS" "$HELPER_CONFIGMAP_NAME" cluster-server=CLUSTER_SERVER >&2
    fi
}

function secret_has_docker_config() {
    local SECRET_NAME="$1"
    local DOCKER_CONFIG=""

    DOCKER_CONFIG=$(kubectl -n "$NS" get secret "$SECRET_NAME" -o go-template='{{ with index .data ".dockerconfigjson" }}{{ . }}{{ end }}' 2>/dev/null || true)
    [ -n "$DOCKER_CONFIG" ]
}

function ensure_workspace_image_registry_secret() {
    WORKSPACE_IMAGE_REGISTRY_SECRET_NAME=""
    load_configmap_vars "$NS" "$HELPER_CONFIGMAP_NAME" workspace-image-registry-secret-name=WORKSPACE_IMAGE_REGISTRY_SECRET_NAME >&2
    if [ -z "$WORKSPACE_IMAGE_REGISTRY_SECRET_NAME" ]; then
        if secret_has_docker_config "$DEFAULT_WORKSPACE_IMAGE_REGISTRY_SECRET_NAME"; then
            WORKSPACE_IMAGE_REGISTRY_SECRET_NAME="$DEFAULT_WORKSPACE_IMAGE_REGISTRY_SECRET_NAME"
        else
            WORKSPACE_IMAGE_REGISTRY_SECRET_NAME=$(prompt_with_default "please input workspace image registry config." "workspace image registry secret name" "$DEFAULT_WORKSPACE_IMAGE_REGISTRY_SECRET_NAME")
        fi
    fi

    if secret_has_docker_config "$WORKSPACE_IMAGE_REGISTRY_SECRET_NAME"; then
        log_info "reuse existing secret $WORKSPACE_IMAGE_REGISTRY_SECRET_NAME." >&2
        apply_configmap_vars "$NS" "$HELPER_CONFIGMAP_NAME" \
            cluster-server=CLUSTER_SERVER \
            workspace-image-registry-secret-name=WORKSPACE_IMAGE_REGISTRY_SECRET_NAME >&2
        return
    fi

    REGISTRY_SERVER=$(prompt_with_default "" "workspace image registry server" "$DEFAULT_REGISTRY_SERVER")
    REGISTRY_USERNAME=$(prompt_required "" "workspace image registry username" "")
    REGISTRY_PASSWORD=$(prompt_required "" "workspace image registry password or token" -s)
    apply_docker_registry_secret "$NS" "$WORKSPACE_IMAGE_REGISTRY_SECRET_NAME" "$REGISTRY_SERVER" "$REGISTRY_USERNAME" "$REGISTRY_PASSWORD" >&2
    apply_configmap_vars "$NS" "$HELPER_CONFIGMAP_NAME" \
        cluster-server=CLUSTER_SERVER \
        workspace-image-registry-secret-name=WORKSPACE_IMAGE_REGISTRY_SECRET_NAME >&2
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

    print_kubeconfig "$TOKEN" "$CA_DATA" | base64 | tr -d '\r\n'
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
