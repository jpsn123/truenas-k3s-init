#!/bin/bash
set -e

cd $(dirname $0)
source ../../common.sh
source ../../parameter.sh

NS=ai-gateway
SUB_DOMAIN=llm
IMAGE_REPOSITORY=hub.bin.jutze.cn/jutze/ai-gateway

## initial
#####################################
log_header "initial"
kubectl create namespace $NS 2>/dev/null || true
load_secret_vars "$NS" "postgresql" password=DB_PW
load_secret_vars "$NS" "ai-gateway" \
    auth-token-signing-key=AUTH_TOKEN_SIGNING_KEY \
    config-encryption-key=CONFIG_ENCRYPTION_KEY
if [ -z "$DB_PW" ] || [ -z "$AUTH_TOKEN_SIGNING_KEY" ] || [ -z "$CONFIG_ENCRYPTION_KEY" ]; then
    PASSWORD_SEED=$(prompt_required "please input seed for password." "password seed" "")
fi
if [ -z "$DB_PW" ]; then
    DB_PW=$(derive_password_sha1 "$PASSWORD_SEED" "$NS@db" 32)
fi
if [ -z "$AUTH_TOKEN_SIGNING_KEY" ]; then
    AUTH_TOKEN_SIGNING_KEY=$(derive_password_sha256_hex "$PASSWORD_SEED" "$NS@auth-token-signing-key" 32)
fi
if [ -z "$CONFIG_ENCRYPTION_KEY" ]; then
    CONFIG_ENCRYPTION_KEY=$(echo -n "$PASSWORD_SEED@$NS" | openssl dgst -sha256 -binary | base64)
fi
apply_secret_vars "$NS" "postgresql" password=DB_PW
apply_secret_vars "$NS" "ai-gateway" \
    auth-token-signing-key=AUTH_TOKEN_SIGNING_KEY \
    config-encryption-key=CONFIG_ENCRYPTION_KEY

IMAGE_TAG=$(prompt_with_default "please input ai-gateway image config." "ai-gateway image tag" "$(get_latest_image_tag "$IMAGE_REPOSITORY")")
render_values_file_to_temp values-*.yaml

## install postgresql
#####################################
log_header "install postgresql"
ensure_helm_repo_chart "bitnami" "oci://registry-1.docker.io/bitnamicharts" "postgresql" "16.7.27"
helm upgrade --install -n $NS postgresql temp/postgresql --wait --timeout 600s -f temp/values-postgresql.yaml \
    --set global.postgresql.auth.postgresPassword=$DB_PW \
    --set global.postgresql.auth.password=$DB_PW \
    --set auth.replicationPassword=$DB_PW \
    --set primary.service.type=LoadBalancer

## install ai-gateway
#####################################
log_header "install ai-gateway"
ensure_helm_repo_chart "bjw-s" "https://bjw-s-labs.github.io/helm-charts" "app-template" "$COMMON_CHART_VERSION"
helm upgrade --install -n $NS ai-gateway temp/app-template --wait --timeout 900s -f temp/values-ai-gateway.yaml

## done
#####################################
log_trace "install success!!!"
log_reminder "   access: https://${SUB_DOMAIN}.${DOMAIN}"
