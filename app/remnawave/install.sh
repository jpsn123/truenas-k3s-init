#!/bin/bash
set -e

cd $(dirname $0)
source ../../common.sh
source ../../parameter.sh

NS=remnawave
INSTALL_MODE="${1:-full}"
validate_install_mode "$INSTALL_MODE" postgresql remnawave

# initial
#####################################
log_header "initial"
kubectl create namespace $NS 2>/dev/null || true
load_secret_vars "$NS" "remnawave-db" password=DB_PW
load_secret_vars "$NS" "remnawave-secrets" \
    jwt-auth-secret=JWT_AUTH_SECRET \
    jwt-api-tokens-secret=JWT_API_TOKENS_SECRET \
    metrics-pass=METRICS_PASS \
    webhook-secret-header=WEBHOOK_SECRET_HEADER
if (install_mode_enabled "$INSTALL_MODE" postgresql && [ -z "$DB_PW" ]) \
    || (install_mode_enabled "$INSTALL_MODE" remnawave && ([ -z "$DB_PW" ] || [ -z "$JWT_AUTH_SECRET" ] || [ -z "$JWT_API_TOKENS_SECRET" ] || [ -z "$METRICS_PASS" ] || [ -z "$WEBHOOK_SECRET_HEADER" ])); then
    PASSWORD_SEED=$(prompt_required "please input seed for password." "password seed" "")
fi
if (install_mode_enabled "$INSTALL_MODE" postgresql || install_mode_enabled "$INSTALL_MODE" remnawave) && [ -z "$DB_PW" ]; then
    DB_PW=$(derive_password_sha1 "$PASSWORD_SEED" "$NS@db" 32)
fi
if install_mode_enabled "$INSTALL_MODE" remnawave && [ -z "$JWT_AUTH_SECRET" ]; then
    JWT_AUTH_SECRET=$(derive_password_sha256 "$PASSWORD_SEED" "$NS@jwt-auth" 50)
fi
if install_mode_enabled "$INSTALL_MODE" remnawave && [ -z "$JWT_API_TOKENS_SECRET" ]; then
    JWT_API_TOKENS_SECRET=$(derive_password_sha256 "$PASSWORD_SEED" "$NS@jwt-api" 50)
fi
if install_mode_enabled "$INSTALL_MODE" remnawave && [ -z "$METRICS_PASS" ]; then
    METRICS_PASS=$(derive_password_sha1 "$PASSWORD_SEED" "$NS@metrics" 32)
fi
if install_mode_enabled "$INSTALL_MODE" remnawave && [ -z "$WEBHOOK_SECRET_HEADER" ]; then
    WEBHOOK_SECRET_HEADER=$(echo -n "$PASSWORD_SEED@$NS@webhook" | sha256sum | awk '{print $1}')
fi
if install_mode_enabled "$INSTALL_MODE" remnawave; then
    DATABASE_URL="postgresql://remnawave:$DB_PW@postgresql:5432/remnawave"
    apply_secret_vars "$NS" "remnawave-db" \
        password=DB_PW \
        url=DATABASE_URL
    apply_secret_vars "$NS" "remnawave-secrets" \
        jwt-auth-secret=JWT_AUTH_SECRET \
        jwt-api-tokens-secret=JWT_API_TOKENS_SECRET \
        metrics-pass=METRICS_PASS \
        webhook-secret-header=WEBHOOK_SECRET_HEADER
fi

# render
#####################################
log_header "render values"
render_values_file_to_temp values-*.yaml

# install postgresql
#####################################
if install_mode_enabled "$INSTALL_MODE" postgresql; then
    log_header "install postgresql"
    ensure_helm_repo_chart "bitnami" "oci://registry-1.docker.io/bitnamicharts" "postgresql" "16.7.27"
    helm upgrade --install -n $NS postgresql temp/postgresql --wait --timeout 600s -f temp/values-postgresql.yaml \
        --set global.postgresql.auth.postgresPassword=$DB_PW \
        --set global.postgresql.auth.password=$DB_PW \
        --set auth.replicationPassword=$DB_PW
fi

# install remnawave
#####################################
if install_mode_enabled "$INSTALL_MODE" remnawave; then
    log_header "install remnawave"
    ensure_helm_repo_chart "bjw-s" "https://bjw-s-labs.github.io/helm-charts" "app-template" "$COMMON_CHART_VERSION"
    helm upgrade --install -n $NS remnawave temp/app-template --wait --timeout 600s -f temp/values-remnawave.yaml
fi

# done
#####################################
log_trace "install success!!!"
log_reminder "   access: https://fq.${DOMAIN}"
