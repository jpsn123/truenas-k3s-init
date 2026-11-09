#!/bin/bash
set -e
set -o pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../scripts/deploy/paths.sh"
source "$DEPLOY_ROOT/scripts/deploy/install-mode.sh"
source "$DEPLOY_ROOT/scripts/deploy/values.sh"
source "$DEPLOY_LIB_DIR/liblog.sh"
source "$DEPLOY_LIB_DIR/libprompt.sh"
source "$DEPLOY_LIB_DIR/libpassword.sh"
source "$DEPLOY_LIB_DIR/libkubernetes.sh"
source "$DEPLOY_LIB_DIR/libhelm.sh"
source "$DEPLOY_ROOT/parameter.sh"
cd "$SCRIPT_DIR"

NS=openproject
INSTALL_MODE="${1:-full}"
deploy_validate_mode "$INSTALL_MODE" postgresql openproject

## function openproject_ensure_enterprise_token. 复用或生成公私钥和 token 并保存到 Secret。
## $1: namespace
function openproject_ensure_enterprise_token() (
    local NS="$1"
    local PRIVATE_KEY=""
    local PUBLIC_KEY=""
    local TOKEN=""
    local KEY_DIR=""
    local DERIVED_PUBLIC_KEY=""

    kube_secret_load "$NS" "openproject-enterprise-keys" \
        private.pem=PRIVATE_KEY public.pem=PUBLIC_KEY || return 1
    kube_secret_load "$NS" "openproject-enterprise" token=TOKEN || return 1
    if [ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ] && [ -n "${TOKEN//[[:space:]]/}" ]; then
        return 0
    fi
    if [ -n "$PRIVATE_KEY" ] || [ -n "$PUBLIC_KEY" ] || [ -n "${TOKEN//[[:space:]]/}" ]; then
        if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
            log_error "enterprise credentials are incomplete; restore the key pair before continuing"
            return 1
        fi
    fi

    mkdir -p "$SCRIPT_DIR/temp" || return 1
    KEY_DIR=$(mktemp -d "$SCRIPT_DIR/temp/enterprise.XXXXXX") || return 1
    trap 'rm -rf -- "$KEY_DIR"' EXIT
    umask 077
    if [ -n "$PRIVATE_KEY" ]; then
        printf '%s\n' "$PRIVATE_KEY" > "$KEY_DIR/private.pem" || return 1
        printf '%s\n' "$PUBLIC_KEY" > "$KEY_DIR/public.pem" || return 1
        PUBLIC_KEY=$(openssl pkey -pubin -in "$KEY_DIR/public.pem" -pubout) || return 1
    fi
    TOKEN=$(python3 -I "$SCRIPT_DIR/make_token.py" --domain "pm.${DOMAIN}" --key-dir "$KEY_DIR" --no-expiry ) || return 1
    if [ ! -s "$KEY_DIR/private.pem" ] || [ ! -s "$KEY_DIR/public.pem" ] || [ -z "${TOKEN//[[:space:]]/}" ]; then
        log_error "make_token.py must provide non-empty private.pem, public.pem and token"
        return 1
    fi
    if [ -n "$PRIVATE_KEY" ] && [ "$PRIVATE_KEY" != "$(< "$KEY_DIR/private.pem")" ]; then
        log_error "make_token.py replaced the existing private key; restore the saved token instead"
        return 1
    fi
    DERIVED_PUBLIC_KEY=$(openssl pkey -in "$KEY_DIR/private.pem" -passin pass: -pubout) || return 1
    [ -n "$PUBLIC_KEY" ] || PUBLIC_KEY=$(openssl pkey -pubin -in "$KEY_DIR/public.pem" -pubout) || return 1
    if [ "$DERIVED_PUBLIC_KEY" != "$PUBLIC_KEY" ]; then
        log_error "generated private.pem and public.pem do not match"
        return 1
    fi
    if [ -z "$PRIVATE_KEY" ]; then
        kube_apply_secret "$NS" "openproject-enterprise-keys" \
            --from-file=private.pem="$KEY_DIR/private.pem" \
            --from-file=public.pem="$KEY_DIR/public.pem" || return 1
    fi
    kube_secret_apply_vars "$NS" "openproject-enterprise" token=TOKEN
)

# initial
#####################################
log_header "initial"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kube_secret_load "$NS" "openproject-db" password=DB_PW
if deploy_mode_enabled "$INSTALL_MODE" openproject; then
    kube_secret_load "$NS" "openproject-secrets" \
        secret-key-base=SECRET_KEY_BASE \
        admin-password=ADMIN_PASSWORD \
        hocuspocus-secret=HOCUSPOCUS_SECRET
fi
if [ -z "$DB_PW" ] || (deploy_mode_enabled "$INSTALL_MODE" openproject && ([ -z "$SECRET_KEY_BASE" ] || [ -z "$ADMIN_PASSWORD" ] || [ -z "$HOCUSPOCUS_SECRET" ])); then
    PASSWORD_SEED=$(prompt_required "please input seed for password." "password seed" "")
fi
[ -n "$DB_PW" ] || DB_PW=$(password_derive_sha1 "$PASSWORD_SEED@$NS@db" 32)
kube_secret_apply_vars "$NS" "openproject-db" password=DB_PW

if deploy_mode_enabled "$INSTALL_MODE" openproject; then
    [ -n "$SECRET_KEY_BASE" ] || SECRET_KEY_BASE=$(password_derive_sha256 "$PASSWORD_SEED@$NS@secret-key-base" 64)
    [ -n "$ADMIN_PASSWORD" ] || ADMIN_PASSWORD=$(password_derive_sha1 "$PASSWORD_SEED@$NS@admin" 32)
    [ -n "$HOCUSPOCUS_SECRET" ] || HOCUSPOCUS_SECRET=$(password_derive_sha256 "$PASSWORD_SEED@$NS@hocuspocus" 64)
    kube_secret_apply_vars "$NS" "openproject-secrets" \
        secret-key-base=SECRET_KEY_BASE \
        admin-password=ADMIN_PASSWORD \
        hocuspocus-secret=HOCUSPOCUS_SECRET

    openproject_ensure_enterprise_token "$NS"
fi

deploy_render_values values-*.yaml

# install postgresql
#####################################
if deploy_mode_enabled "$INSTALL_MODE" postgresql; then
    log_header "install postgresql"
    helm_ensure_chart "bitnami" "oci://registry-1.docker.io/bitnamicharts" "postgresql" "temp" "16.7.27"
    helm upgrade --install -n "$NS" postgresql temp/postgresql --wait --timeout 600s -f temp/values-postgresql.yaml
fi

# install openproject
#####################################
if deploy_mode_enabled "$INSTALL_MODE" openproject; then
    log_header "install openproject"
    if [ "$INSTALL_MODE" == "reinstall" ]; then
        helm_ensure_chart "openproject" "https://charts.openproject.org" "openproject" "temp"
        VERSION_PAIR=$(helm_chart_versions_local "temp/openproject")
        read -r OPENPROJECT_CHART_VERSION OPENPROJECT_APP_VERSION <<<"$VERSION_PAIR"
    else
        VERSION_PAIR=$(helm_chart_versions "openproject" "https://charts.openproject.org" "openproject")
        read -r OPENPROJECT_CHART_VERSION DEFAULT_OPENPROJECT_APP_VERSION <<<"$VERSION_PAIR"
        OPENPROJECT_APP_VERSION=$(prompt_with_default "" "openproject app version" "$DEFAULT_OPENPROJECT_APP_VERSION")
        if [ "$OPENPROJECT_APP_VERSION" != "$DEFAULT_OPENPROJECT_APP_VERSION" ]; then
            VERSION_PAIR=$(helm_chart_versions "openproject" "https://charts.openproject.org" "openproject" "$OPENPROJECT_APP_VERSION")
            read -r OPENPROJECT_CHART_VERSION OPENPROJECT_APP_VERSION <<<"$VERSION_PAIR"
        fi
        helm_ensure_chart "openproject" "https://charts.openproject.org" "openproject" "temp" "$OPENPROJECT_CHART_VERSION"
    fi
    OPENPROJECT_RELEASE=$(helm list -n "$NS" --deployed --filter '^openproject$' -q)
    if [ -z "$OPENPROJECT_RELEASE" ]; then
        # Do not start Rails migration checks until the seeder has initialized the schema.
        helm upgrade --install -n "$NS" openproject temp/openproject --wait --wait-for-jobs --timeout 1800s -f temp/values-openproject.yaml \
            --set replicaCount=0,backgroundReplicaCount=0,workers.default.replicaCount=0 \
            --set cron.enabled=false,autoscaling.enabled=false
    fi
    helm upgrade --install -n "$NS" openproject temp/openproject --reset-values -f temp/values-openproject.yaml
fi

# done
#####################################
log_trace "install success!!!"
if deploy_mode_enabled "$INSTALL_MODE" openproject; then
    log_reminder "   access: https://pm.${DOMAIN}"
    log_reminder "   initial admin login: admin"
    log_reminder "   get initial admin password (only used on first initialization):"
    log_reminder "   kubectl -n $NS get secret openproject-secrets -o jsonpath='{.data.admin-password}' | base64 -d; printf '\\n'"
    log_reminder "   enterprise token saved to Secret; apply it manually in the OpenProject administration UI"
    log_reminder "   get enterprise token (keep it secret):"
    log_reminder "   kubectl -n $NS get secret openproject-enterprise -o jsonpath='{.data.token}' | base64 -d; printf '\\n'"
fi
