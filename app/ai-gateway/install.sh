#!/bin/bash
set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../scripts/deploy/paths.sh"
source "$DEPLOY_ROOT/scripts/deploy/values.sh"
source "$DEPLOY_LIB_DIR/liblog.sh"
source "$DEPLOY_LIB_DIR/libprompt.sh"
source "$DEPLOY_LIB_DIR/libpassword.sh"
source "$DEPLOY_LIB_DIR/libkubernetes.sh"
source "$DEPLOY_LIB_DIR/libhelm.sh"
source "$DEPLOY_LIB_DIR/libregistry.sh"
source "$DEPLOY_ROOT/parameter.sh"
cd "$SCRIPT_DIR"

NS=ai-gateway
SUB_DOMAIN=llm

## initial
#####################################
log_header "initial"
kubectl create namespace $NS 2>/dev/null || true
kube_secret_load "$NS" "postgresql" password=DB_PW
kube_secret_load "$NS" "ai-gateway" \
    auth-token-signing-key=AUTH_TOKEN_SIGNING_KEY \
    config-encryption-key=CONFIG_ENCRYPTION_KEY \
    chat-oauth-bridge-token=CHAT_OAUTH_BRIDGE_TOKEN
kube_configmap_load "$NS" "ai-gateway" \
    image-repository=IMAGE_REPOSITORY \
    chat-agent-image-repository=CHAT_AGENT_IMAGE_REPOSITORY
if [ -z "$DB_PW" ] || [ -z "$AUTH_TOKEN_SIGNING_KEY" ] || [ -z "$CONFIG_ENCRYPTION_KEY" ] || [ -z "$CHAT_OAUTH_BRIDGE_TOKEN" ]; then
    PASSWORD_SEED=$(prompt_required "please input seed for password." "password seed" "")
fi
if [ -z "$DB_PW" ]; then
    DB_PW=$(password_derive_sha1 "$PASSWORD_SEED@$NS@db" 32)
fi
if [ -z "$AUTH_TOKEN_SIGNING_KEY" ]; then
    AUTH_TOKEN_SIGNING_KEY=$(password_derive_sha256_hex "$PASSWORD_SEED@$NS@auth-token-signing-key" 32)
fi
if [ -z "$CONFIG_ENCRYPTION_KEY" ]; then
    CONFIG_ENCRYPTION_KEY=$(echo -n "$PASSWORD_SEED@$NS" | openssl dgst -sha256 -binary | base64)
fi
if [ -z "$CHAT_OAUTH_BRIDGE_TOKEN" ]; then
    CHAT_OAUTH_BRIDGE_TOKEN=$(password_derive_sha256_hex "$PASSWORD_SEED@$NS@chat-oauth-bridge-token" 32)
fi
kube_secret_apply_vars "$NS" "ai-gateway" \
    auth-token-signing-key=AUTH_TOKEN_SIGNING_KEY \
    config-encryption-key=CONFIG_ENCRYPTION_KEY \
    chat-oauth-bridge-token=CHAT_OAUTH_BRIDGE_TOKEN

if [ -z "$IMAGE_REPOSITORY" ]; then
    IMAGE_REPOSITORY=$(prompt_with_default "please input ai-gateway image config." "ai-gateway image repository" "hub.bin.jutze.cn/jutze/ai-gateway")
fi
IMAGE_TAG=$(prompt_with_default "" "ai-gateway image tag" "$(registry_latest_tag "$IMAGE_REPOSITORY" "" anonymous)")
if [ -z "$CHAT_AGENT_IMAGE_REPOSITORY" ]; then
    CHAT_AGENT_IMAGE_REPOSITORY=$(prompt_with_default "please input chat-agent image config." "chat-agent image repository" "hub.bin.jutze.cn/jutze/chat-agent")
fi
CHAT_AGENT_IMAGE_TAG=$(prompt_with_default "" "chat-agent image tag" "$(registry_latest_tag "$CHAT_AGENT_IMAGE_REPOSITORY" "" anonymous)")
kube_configmap_apply_vars "$NS" "ai-gateway" \
    image-repository=IMAGE_REPOSITORY \
    chat-agent-image-repository=CHAT_AGENT_IMAGE_REPOSITORY
deploy_render_values values-*.yaml

## install postgresql
#####################################
log_header "install postgresql"
helm_ensure_chart "bitnami" "oci://registry-1.docker.io/bitnamicharts" "postgresql" "temp" "16.7.27"
helm upgrade --install -n $NS postgresql temp/postgresql --wait --timeout 600s -f temp/values-postgresql.yaml \
    --set global.postgresql.auth.postgresPassword=$DB_PW \
    --set global.postgresql.auth.password=$DB_PW \
    --set auth.replicationPassword=$DB_PW \
    --set primary.service.type=LoadBalancer

## install ai-gateway
#####################################
log_header "install ai-gateway"
helm_ensure_chart "bjw-s" "https://bjw-s-labs.github.io/helm-charts" "app-template" "temp" "$COMMON_CHART_VERSION"
helm upgrade --install -n $NS ai-gateway temp/app-template --wait --timeout 900s -f temp/values-ai-gateway.yaml

## done
#####################################
log_trace "install success!!!"
log_reminder "   access: https://${SUB_DOMAIN}.${DOMAIN}"
