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

NS=nocobase
INSTALL_MODE="${1:-full}"
deploy_validate_mode "$INSTALL_MODE" postgresql nocobase

# initial
#####################################
log_header "initial"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kube_secret_load "$NS" "nocobase-db" password=DB_PW
if deploy_mode_enabled "$INSTALL_MODE" nocobase; then
    kube_secret_load "$NS" "nocobase-secrets" \
        APP_KEY=APP_KEY \
        INIT_ROOT_EMAIL=INIT_ROOT_EMAIL \
        INIT_ROOT_PASSWORD=INIT_ROOT_PASSWORD
fi
if [ -z "$DB_PW" ] || (deploy_mode_enabled "$INSTALL_MODE" nocobase && ([ -z "$APP_KEY" ] || [ -z "$INIT_ROOT_PASSWORD" ])); then
    PASSWORD_SEED=$(prompt_required "please input seed for password." "password seed" "")
fi
[ -n "$DB_PW" ] || DB_PW=$(password_derive_sha1 "$PASSWORD_SEED@$NS@db" 32)
kube_secret_apply_vars "$NS" "nocobase-db" password=DB_PW

if deploy_mode_enabled "$INSTALL_MODE" nocobase; then
    [ -n "$APP_KEY" ] || APP_KEY=$(password_derive_sha256 "$PASSWORD_SEED@$NS@app" 48)
    [ -n "$INIT_ROOT_PASSWORD" ] || INIT_ROOT_PASSWORD=$(password_derive_sha1 "$PASSWORD_SEED@$NS@admin" 32)
    [ -n "$INIT_ROOT_EMAIL" ] || INIT_ROOT_EMAIL=$(prompt_with_default "please input nocobase admin config." "admin email" "admin@$DOMAIN")
    kube_secret_apply_vars "$NS" "nocobase-secrets" \
        APP_KEY=APP_KEY \
        INIT_ROOT_EMAIL=INIT_ROOT_EMAIL \
        INIT_ROOT_PASSWORD=INIT_ROOT_PASSWORD

    if [ "$INSTALL_MODE" == "reinstall" ]; then
        kube_configmap_load "$NS" "nocobase-install-version" image-tag=NOCOBASE_IMAGE_TAG
        if [ -z "$NOCOBASE_IMAGE_TAG" ]; then
            log_error "nocobase install version is missing; run install.sh full first."
            exit 1
        fi
    else
        NOCOBASE_IMAGE_TAG=$(curl -fsSL "https://hub.docker.com/v2/repositories/nocobase/nocobase/tags?page_size=100&name=full&ordering=last_updated" \
            | jq -er '[.results[].name | select(test("^[0-9]+[.][0-9]+[.][0-9]+-full$"))][0] // empty')
        NOCOBASE_IMAGE_TAG=$(prompt_with_default "please select nocobase version." "image tag" "$NOCOBASE_IMAGE_TAG")
    fi
    if [[ ! "$NOCOBASE_IMAGE_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-full)?$ ]]; then
        log_error "please use a pinned stable nocobase image tag, for example 2.2.23-full."
        exit 1
    fi
    deploy_render_values values-nocobase.yaml
fi
deploy_render_values values-postgresql.yaml

# install postgresql
#####################################
if deploy_mode_enabled "$INSTALL_MODE" postgresql; then
    log_header "install postgresql"
    helm_ensure_chart "bitnami" "oci://registry-1.docker.io/bitnamicharts" "postgresql" "temp" "16.7.27"
    helm upgrade --install -n "$NS" postgresql temp/postgresql --wait --timeout 600s -f temp/values-postgresql.yaml
fi

# install nocobase
#####################################
if deploy_mode_enabled "$INSTALL_MODE" nocobase; then
    log_header "install nocobase"
    helm_ensure_chart "bjw-s" "https://bjw-s-labs.github.io/helm-charts" "app-template" "temp" "$COMMON_CHART_VERSION"
    helm upgrade --install -n "$NS" nocobase temp/app-template --wait --timeout 1200s -f temp/values-nocobase.yaml
    kube_configmap_apply_vars "$NS" "nocobase-install-version" image-tag=NOCOBASE_IMAGE_TAG
fi

# done
#####################################
log_trace "install success!!!"
if deploy_mode_enabled "$INSTALL_MODE" nocobase; then
    log_reminder "   access: https://nb.${DOMAIN}"
    log_reminder "   initial admin email: $INIT_ROOT_EMAIL"
    log_reminder "   get initial admin password (only used on first initialization):"
    log_reminder "   kubectl -n $NS get secret nocobase-secrets -o jsonpath='{.data.INIT_ROOT_PASSWORD}' | base64 -d; printf '\\n'"
fi
