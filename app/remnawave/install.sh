#!/bin/bash
set -e

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

NS=remnawave
INSTALL_MODE="${1:-full}"
deploy_validate_mode "$INSTALL_MODE" postgresql remnawave

# initial
#####################################
log_header "initial"
kubectl create namespace $NS 2>/dev/null || true
kube_secret_load "$NS" "remnawave-db" password=DB_PW
kube_secret_load "$NS" "remnawave-secrets" \
    jwt-auth-secret=APP_SECRET \
    metrics-pass=METRICS_PASS \
    webhook-secret-header=WEBHOOK_SECRET_HEADER \
    remnawave-api-token=REMNAWAVE_API_TOKEN
if (deploy_mode_enabled "$INSTALL_MODE" postgresql && [ -z "$DB_PW" ]) \
    || (deploy_mode_enabled "$INSTALL_MODE" remnawave && ([ -z "$DB_PW" ] || [ -z "$APP_SECRET" ] || [ -z "$METRICS_PASS" ] || [ -z "$WEBHOOK_SECRET_HEADER" ])); then
    PASSWORD_SEED=$(prompt_required "please input seed for password." "password seed" "")
fi
if deploy_mode_enabled "$INSTALL_MODE" remnawave && [ -z "$REMNAWAVE_API_TOKEN" ]; then
    REMNAWAVE_API_TOKEN=$(prompt_required "please input Remnawave API token. Create it in Remnawave Dashboard -> Remnawave Settings -> API Tokens." "Remnawave API token" -s)
fi
if (deploy_mode_enabled "$INSTALL_MODE" postgresql || deploy_mode_enabled "$INSTALL_MODE" remnawave) && [ -z "$DB_PW" ]; then
    DB_PW=$(password_derive_sha1 "$PASSWORD_SEED@$NS@db" 32)
fi
if deploy_mode_enabled "$INSTALL_MODE" remnawave && [ -z "$APP_SECRET" ]; then
    APP_SECRET=$(password_derive_sha256 "$PASSWORD_SEED@$NS@jwt-auth" 50)
fi
if deploy_mode_enabled "$INSTALL_MODE" remnawave && [ -z "$METRICS_PASS" ]; then
    METRICS_PASS=$(password_derive_sha1 "$PASSWORD_SEED@$NS@metrics" 32)
fi
if deploy_mode_enabled "$INSTALL_MODE" remnawave && [ -z "$WEBHOOK_SECRET_HEADER" ]; then
    WEBHOOK_SECRET_HEADER=$(echo -n "$PASSWORD_SEED@$NS@webhook" | sha256sum | awk '{print $1}')
fi
if deploy_mode_enabled "$INSTALL_MODE" remnawave; then
    DATABASE_URL="postgresql://remnawave:$DB_PW@postgresql:5432/remnawave"
    kube_secret_apply_vars "$NS" "remnawave-db" \
        password=DB_PW \
        url=DATABASE_URL
    kube_secret_apply_vars "$NS" "remnawave-secrets" \
        jwt-auth-secret=APP_SECRET \
        metrics-pass=METRICS_PASS \
        webhook-secret-header=WEBHOOK_SECRET_HEADER \
        remnawave-api-token=REMNAWAVE_API_TOKEN
fi

# render
#####################################
log_header "render values"
deploy_render_values values-*.yaml

# install postgresql
#####################################
if deploy_mode_enabled "$INSTALL_MODE" postgresql; then
    log_header "install postgresql"
    helm_ensure_chart "bitnami" "oci://registry-1.docker.io/bitnamicharts" "postgresql" "temp" "16.7.27"
    helm upgrade --install -n $NS postgresql temp/postgresql --wait --timeout 600s -f temp/values-postgresql.yaml \
        --set global.postgresql.auth.postgresPassword=$DB_PW \
        --set global.postgresql.auth.password=$DB_PW \
        --set auth.replicationPassword=$DB_PW
fi

# install remnawave
#####################################
if deploy_mode_enabled "$INSTALL_MODE" remnawave; then
    log_header "install remnawave"
    helm_ensure_chart "bjw-s" "https://bjw-s-labs.github.io/helm-charts" "app-template" "temp" "$COMMON_CHART_VERSION"
    helm upgrade --install -n $NS remnawave temp/app-template --wait --timeout 600s -f temp/values-remnawave.yaml
fi

# done
#####################################
log_trace "install success!!!"
log_reminder "   access: https://fq.${DOMAIN}"
