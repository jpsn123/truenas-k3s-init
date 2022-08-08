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
NS=jfrog
INSTALL_MODE="${1:-full}"
deploy_validate_mode "$INSTALL_MODE" jfrog

# initial
#####################################
log_header "initial"
kubectl create namespace $NS 2>/dev/null || true
kube_secret_load "$NS" "jfrog-platform-postgresql" postgres-password=PG_PW
kube_secret_load "$NS" "jfrog-platform-artifactory-unified-secret" \
    master-key=MASTER_PW \
    join-key=JOIN_PW \
    bootstrap.creds=BOOTSTRAP_CREDS
if [ -n "$BOOTSTRAP_CREDS" ]; then
    ARTIFACTORY_PW=${BOOTSTRAP_CREDS#*=}
fi
if deploy_mode_enabled "$INSTALL_MODE" jfrog && ([ -z "$ARTIFACTORY_PW" ] || [ -z "$PG_PW" ] || [ -z "$MASTER_PW" ] || [ -z "$JOIN_PW" ]); then
    PASSWORD_SEED=$(prompt_required "please input password seed for setting jfrog." "password seed" "")
fi
if deploy_mode_enabled "$INSTALL_MODE" jfrog && ([ -z "$ARTIFACTORY_PW" ] || [ -z "$MASTER_PW" ] || [ -z "$JOIN_PW" ]); then
    ARTIFACTORY_PW=$(password_derive_sha1 "$PASSWORD_SEED@$NS@jfrog" 32)
    MASTER_PW=$(password_derive_sha256_hex "$PASSWORD_SEED@$NS@master" 64)
    JOIN_PW=$(password_derive_sha256_hex "$PASSWORD_SEED@$NS@join" 32)
fi
if deploy_mode_enabled "$INSTALL_MODE" jfrog && [ -z "$PG_PW" ]; then
    PG_PW=$(password_derive_sha1 "$PASSWORD_SEED@$NS@pg" 32)
fi
if deploy_mode_enabled "$INSTALL_MODE" jfrog; then
    # jfrog jar patch script
    kube_apply_configmap "$NS" "jfrog-patch" --from-file=patch.py=patch.py
    # 自定义前端资源：custom.sh 负责运行时把 logo/svg 覆盖到 dist，并替换文案
    kube_apply_configmap "$NS" "jfrog-frontend-custom" \
        --from-file=custom.sh=custom/custom.sh \
        --from-file=apple-touch-icon.png=custom/apple-touch-icon.png \
        --from-file=favicon-16x16.png=custom/favicon-16x16.png \
        --from-file=favicon-32x32.png=custom/favicon-32x32.png \
        --from-file=favicon.ico=custom/favicon.ico \
        --from-file=favicon.png=custom/favicon.png \
        --from-file=jfrog.svg=custom/jfrog.svg \
        --from-file=jfrog.00000000.svg=custom/jfrog.00000000.svg \
        --from-file=logo.00000000.svg=custom/logo.00000000.svg \
        --from-file=login_logo.00000000.svg=custom/login_logo.00000000.svg \
        --from-file=login_side.00000000.svg=custom/login_side.00000000.svg
fi
deploy_render_values values-*.yaml

# install jfrog
#####################################
if deploy_mode_enabled "$INSTALL_MODE" jfrog; then
    log_info "install jfrog"
    if [ "$INSTALL_MODE" == "reinstall" ]; then
        helm_ensure_chart "jfrog" "https://charts.jfrog.io" "jfrog-platform" "temp"
    else
        VERSION_PAIR=$(helm_chart_versions "jfrog" "https://charts.jfrog.io" "jfrog-platform")
        read -r JFROG_PLATFORM_CHART_VERSION DEFAULT_JFROG_PLATFORM_APP_VERSION <<<"$VERSION_PAIR"
        JFROG_PLATFORM_APP_VERSION=$(prompt_with_default "" "jfrog app version" "$DEFAULT_JFROG_PLATFORM_APP_VERSION")
        if [ "$JFROG_PLATFORM_APP_VERSION" != "$DEFAULT_JFROG_PLATFORM_APP_VERSION" ]; then
            VERSION_PAIR=$(helm_chart_versions "jfrog" "https://charts.jfrog.io" "jfrog-platform" "$JFROG_PLATFORM_APP_VERSION")
            read -r JFROG_PLATFORM_CHART_VERSION JFROG_PLATFORM_APP_VERSION <<<"$VERSION_PAIR"
        fi
        helm_ensure_chart "jfrog" "https://charts.jfrog.io" "jfrog-platform" "temp" "$JFROG_PLATFORM_CHART_VERSION"
    fi
    helm upgrade --install -n $NS jfrog-platform temp/jfrog-platform -f temp/values-jfrog.yaml \
        --set global.masterKey=$MASTER_PW \
        --set global.joinKey=$JOIN_PW \
        --set global.database.adminPassword=$PG_PW \
        --set postgresql.auth.postgresPassword=$PG_PW \
        --set artifactory.database.password=$PG_PW \
        --set artifactory.artifactory.admin.password=$ARTIFACTORY_PW \
        --set xray.database.password=$PG_PW \
        --set distribution.database.password=$PG_PW
    kubectl apply -n $NS -f temp/values-ingress.yaml
fi

## done
#####################################
log_trace "init success!!!"
log_trace "run command to get bootstrap password:"
log_reminder "   kubectl get secret -n $NS jfrog-platform-artifactory-unified-secret -o go-template='{{ index .data \"bootstrap.creds\" | base64decode }}{{ \"\\\n\" }}'"
