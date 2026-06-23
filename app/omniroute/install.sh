#!/bin/bash

set -e
cd $(dirname $0)
source ../../common.sh
source ../../parameter.sh
NS=api
INSTALL_MODE="${1:-full}"
validate_install_mode "$INSTALL_MODE" redis omniroute

# initial
#####################################
log_header "initial"
kubectl create namespace $NS 2>/dev/null || true
load_secret_vars "$NS" "omniroute" \
    jwt-secret=JWT_SECRET \
    api-key-secret=API_KEY_SECRET
load_secret_vars "$NS" "redis" redis-password=REDIS_PW
if (install_mode_enabled "$INSTALL_MODE" omniroute && ([ -z "$JWT_SECRET" ] || [ -z "$API_KEY_SECRET" ])) \
    || (install_mode_enabled "$INSTALL_MODE" redis && [ -z "$REDIS_PW" ]); then
    PASSWORD_SEED=$(prompt_required "please input password seed for setting omniroute." "password seed" "")
fi
if install_mode_enabled "$INSTALL_MODE" omniroute && [ -z "$JWT_SECRET" ]; then
    JWT_SECRET=$(echo -n "$PASSWORD_SEED@$NS@jwt" | sha256sum | awk '{print $1}')
fi
if install_mode_enabled "$INSTALL_MODE" omniroute && [ -z "$API_KEY_SECRET" ]; then
    API_KEY_SECRET=$(echo -n "$PASSWORD_SEED@$NS@apikey" | sha256sum | awk '{print $1}')
fi
if install_mode_enabled "$INSTALL_MODE" redis && [ -z "$REDIS_PW" ]; then
    REDIS_PW=$(echo -n "$PASSWORD_SEED@$NS@redis" | sha256sum | awk '{print $1}' | head -c 32)
fi
REDIS_URL="redis://:$REDIS_PW@redis-master:6379"
if install_mode_enabled "$INSTALL_MODE" omniroute; then
    apply_secret_vars "$NS" "omniroute" \
        jwt-secret=JWT_SECRET \
        api-key-secret=API_KEY_SECRET \
        redis-url=REDIS_URL
fi

# render
#####################################
log_header "render values"
render_values_file_to_temp values-*.yaml

# install redis
#####################################
if install_mode_enabled "$INSTALL_MODE" redis; then
    log_header "install redis"
    ensure_helm_repo_chart "bitnami" "oci://registry-1.docker.io/bitnamicharts" "redis" "22.0.7"
    helm upgrade --install -n $NS redis temp/redis --wait --timeout 600s -f temp/values-redis.yaml \
        --set global.redis.password=$REDIS_PW
fi

# install omniroute
#####################################
if install_mode_enabled "$INSTALL_MODE" omniroute; then
    log_header "install omniroute"
    ensure_helm_repo_chart "bjw-s" "https://bjw-s-labs.github.io/helm-charts" "app-template" "$COMMON_CHART_VERSION"
    helm upgrade --install -n $NS omniroute temp/app-template --wait --timeout 600s -f temp/values-omniroute.yaml
fi

# done
#####################################
log_trace "install success!!!"
log_reminder "   access: https://api.${DOMAIN}"
log_reminder "   initial password: CHANGEME (please change after first login)"
