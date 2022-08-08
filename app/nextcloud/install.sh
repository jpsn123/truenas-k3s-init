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
source "$DEPLOY_ROOT/scripts/deploy/images.sh"
source "$DEPLOY_LIB_DIR/libregistry.sh"
source "$DEPLOY_LIB_DIR/libbuildkit.sh"
source "$DEPLOY_ROOT/parameter.sh"
cd "$SCRIPT_DIR"
NS=nextcloud
INSTALL_MODE="${1:-full}"
deploy_validate_mode "$INSTALL_MODE" postgresql redis nextcloud office
trap 'rm -rf temp/nextcloud-docker-config' EXIT

# functions
function ensure_nextcloud_image() {
    local IMAGE="$1"
    local CONTEXT="$2"
    local BASE_IMAGE="$3"

    if [ "$NEXTCLOUD_USE_CUSTOM_REGISTRY" == "y" ]; then
        if deploy_image_pull "$IMAGE" "$NEXTCLOUD_REGISTRY_USERNAME" "$NEXTCLOUD_REGISTRY_TOKEN"; then
            log_info "image is pullable: $IMAGE"
            return
        fi
        buildkit_ensure_client /usr/local/bin
        buildkit_build "$CONTEXT" "$IMAGE" "$NEXTCLOUD_BUILDKIT_ADDR" "temp/nextcloud-docker-config" "$BASE_IMAGE"
    else
        if deploy_image_pull "$IMAGE"; then
            log_info "image is pullable: $IMAGE"
            return
        fi
        kubectl -n "$NS" patch secret "nextcloud-custom-image" --type=json -p='[{"op":"remove","path":"/data/image-version"}]' >/dev/null 2>&1 || true
        log_error "image $IMAGE does not exist. please build it manually, then rerun this script."
        exit 1
    fi
}

# initial
#####################################
log_header "initial"
kubectl create namespace $NS 2>/dev/null || true
kube_secret_load "$NS" "redis" redis-password=REDIS_PW
kube_secret_load "$NS" "postgresql" password=DB_PW
kube_secret_load "$NS" "nextcloud" nextcloud-password=NEXTCLOUD_PW
kube_secret_load "$NS" "nextcloud-custom-image" \
    use-custom-registry=NEXTCLOUD_USE_CUSTOM_REGISTRY \
    registry-url=NEXTCLOUD_REGISTRY_URL \
    registry-username=NEXTCLOUD_REGISTRY_USERNAME \
    registry-token=NEXTCLOUD_REGISTRY_TOKEN \
    buildkit-addr=NEXTCLOUD_BUILDKIT_ADDR \
    image-repository=NEXTCLOUD_IMAGE_REPOSITORY
if (deploy_mode_enabled "$INSTALL_MODE" redis && [ -z "$REDIS_PW" ]) \
    || (deploy_mode_enabled "$INSTALL_MODE" postgresql && [ -z "$DB_PW" ]) \
    || (deploy_mode_enabled "$INSTALL_MODE" nextcloud && [ -z "$NEXTCLOUD_PW" ]); then
    PASSWORD_SEED=$(prompt_required "please input password seed for setting nextcloud." "password seed" "")
fi
if deploy_mode_enabled "$INSTALL_MODE" redis && [ -z "$REDIS_PW" ]; then
    REDIS_PW=$(password_derive_sha1 "$PASSWORD_SEED@$NS@redis" 32)
fi
if deploy_mode_enabled "$INSTALL_MODE" postgresql && [ -z "$DB_PW" ]; then
    DB_PW=$(password_derive_sha1 "$PASSWORD_SEED@$NS@pg" 32)
fi
if deploy_mode_enabled "$INSTALL_MODE" nextcloud && [ -z "$NEXTCLOUD_PW" ]; then
    NEXTCLOUD_PW=$(password_derive_sha1 "$PASSWORD_SEED@$NS@nextcloud" 32)
fi

if deploy_mode_enabled "$INSTALL_MODE" nextcloud; then
    if [ -z "$NEXTCLOUD_USE_CUSTOM_REGISTRY" ]; then
        NEXTCLOUD_USE_CUSTOM_REGISTRY=$(prompt_with_default "please select nextcloud custom registry config." "use custom registry? (y/n)" "n")
    fi
    if [[ "$NEXTCLOUD_USE_CUSTOM_REGISTRY" =~ ^[Yy]$ ]]; then
        NEXTCLOUD_USE_CUSTOM_REGISTRY=y
    else
        NEXTCLOUD_USE_CUSTOM_REGISTRY=n
    fi

    if [ "$NEXTCLOUD_USE_CUSTOM_REGISTRY" == "y" ]; then
        [ -n "$NEXTCLOUD_REGISTRY_URL" ] || NEXTCLOUD_REGISTRY_URL=$(prompt_with_default "please input nextcloud custom registry config." "registry url" "hub.bin.$DOMAIN")
        [ -n "$NEXTCLOUD_REGISTRY_USERNAME" ] || NEXTCLOUD_REGISTRY_USERNAME=$(prompt_required "" "registry username" "")
        [ -n "$NEXTCLOUD_REGISTRY_TOKEN" ] || NEXTCLOUD_REGISTRY_TOKEN=$(prompt_required "" "registry token" -s)
        [ -n "$NEXTCLOUD_BUILDKIT_ADDR" ] || NEXTCLOUD_BUILDKIT_ADDR=$(prompt_with_default "" "buildkit address" "tcp://buildkit.$DOMAIN:1234")
    else
        [ -n "$NEXTCLOUD_REGISTRY_URL" ] || NEXTCLOUD_REGISTRY_URL=$(prompt_with_default "please input nextcloud registry config." "registry url" "hub.bin.$DOMAIN")
        NEXTCLOUD_REGISTRY_USERNAME=""
        NEXTCLOUD_REGISTRY_TOKEN=""
        NEXTCLOUD_BUILDKIT_ADDR=""
    fi
    NEXTCLOUD_REGISTRY_HOST=$(registry_host "$NEXTCLOUD_REGISTRY_URL")

    NEXTCLOUD_IMAGE_PATH=$(registry_strip_host "$NEXTCLOUD_IMAGE_REPOSITORY")
    if [ -z "$NEXTCLOUD_IMAGE_PATH" ]; then
        NEXTCLOUD_IMAGE_PATH=$(prompt_with_default "please input nextcloud image config." "nextcloud image name" "$BRAND_PREFIX/nextcloud")
    fi
    if [ "$INSTALL_MODE" == "reinstall" ]; then
        helm_ensure_chart "nextcloud" "https://nextcloud.github.io/helm/" "nextcloud" "temp"
        VERSION_PAIR=$(helm_chart_versions_local "temp/nextcloud")
        read -r NEXTCLOUD_CHART_VERSION NEXTCLOUD_APP_VERSION <<<"$VERSION_PAIR"
        NEXTCLOUD_IMAGE_VERSION="$NEXTCLOUD_APP_VERSION-fpm"
    else
        VERSION_PAIR=$(helm_chart_versions "nextcloud" "https://nextcloud.github.io/helm/" "nextcloud")
        read -r NEXTCLOUD_CHART_VERSION DEFAULT_NEXTCLOUD_APP_VERSION <<<"$VERSION_PAIR"
        NEXTCLOUD_IMAGE_VERSION=$(prompt_with_default "" "nextcloud image version" "$DEFAULT_NEXTCLOUD_APP_VERSION-fpm")
        NEXTCLOUD_APP_VERSION="${NEXTCLOUD_IMAGE_VERSION%%-*}"
        helm_ensure_chart "nextcloud" "https://nextcloud.github.io/helm/" "nextcloud" "temp" "$NEXTCLOUD_CHART_VERSION"
    fi
    NEXTCLOUD_IMAGE_REPOSITORY="$NEXTCLOUD_REGISTRY_HOST/${NEXTCLOUD_IMAGE_PATH#/}"
    NEXTCLOUD_FULL_IMAGE="$NEXTCLOUD_IMAGE_REPOSITORY:$NEXTCLOUD_IMAGE_VERSION"

    NEXTCLOUD_USERNAME=admin
    kube_secret_apply_vars "$NS" "nextcloud" \
        nextcloud-username=NEXTCLOUD_USERNAME \
        nextcloud-password=NEXTCLOUD_PW
    kube_secret_apply_vars "$NS" "nextcloud-custom-image" \
        use-custom-registry=NEXTCLOUD_USE_CUSTOM_REGISTRY \
        registry-url=NEXTCLOUD_REGISTRY_URL \
        registry-username=NEXTCLOUD_REGISTRY_USERNAME \
        registry-token=NEXTCLOUD_REGISTRY_TOKEN \
        buildkit-addr=NEXTCLOUD_BUILDKIT_ADDR \
        image-repository=NEXTCLOUD_IMAGE_REPOSITORY
    if [ "$NEXTCLOUD_USE_CUSTOM_REGISTRY" == "y" ]; then
        kube_apply_registry_secret "$NS" "nextcloud-custom-registry" "$NEXTCLOUD_REGISTRY_HOST" "$NEXTCLOUD_REGISTRY_USERNAME" "$NEXTCLOUD_REGISTRY_TOKEN"
        registry_write_auth "temp/nextcloud-docker-config" "$NEXTCLOUD_REGISTRY_HOST" "$NEXTCLOUD_REGISTRY_USERNAME" "$NEXTCLOUD_REGISTRY_TOKEN"
    fi
    ensure_nextcloud_image "$NEXTCLOUD_FULL_IMAGE" "nextcloud-full-img" "nextcloud:$NEXTCLOUD_IMAGE_VERSION"
fi

deploy_render_values values-*.yaml
if deploy_mode_enabled "$INSTALL_MODE" nextcloud; then
    kubectl -n $NS apply -f temp/values-configs.yaml
    kubectl -n $NS apply -f temp/values-important-pvc.yaml
fi

# install postgresql
#####################################
if deploy_mode_enabled "$INSTALL_MODE" postgresql; then
    log_header "install postgresql"
    helm_ensure_chart "bitnami" "oci://registry-1.docker.io/bitnamicharts" "postgresql" "temp" "16.7.27"
    helm upgrade --install -n $NS postgresql temp/postgresql --wait --timeout 600s -f temp/values-postgresql.yaml \
        --set global.postgresql.auth.postgresPassword=$DB_PW \
        --set global.postgresql.auth.password=$DB_PW \
        --set auth.replicationPassword=$DB_PW
    kubectl -n $NS patch secret postgresql --type merge --patch \
        "{\"data\":{\"username\":\"$(echo -n nextcloud | base64)\"}}"
fi

# install redis
#####################################
if deploy_mode_enabled "$INSTALL_MODE" redis; then
    log_header "install redis"
    helm_ensure_chart "bitnami" "oci://registry-1.docker.io/bitnamicharts" "redis" "temp" "22.0.7"
    helm upgrade --install -n $NS redis temp/redis --wait --timeout 600s -f temp/values-redis.yaml \
        --set global.redis.password=$REDIS_PW
fi

# install nextcloud
#####################################
if deploy_mode_enabled "$INSTALL_MODE" nextcloud; then
    log_header "install nextcloud"
    helm upgrade --install -n $NS nextcloud temp/nextcloud --wait --timeout 1200s -f temp/values-nextcloud.yaml --set replicaCount=1
fi

# install office
#####################################
if deploy_mode_enabled "$INSTALL_MODE" office; then
    log_header "install office plugin"
    helm_ensure_chart "bjw-s" "https://bjw-s-labs.github.io/helm-charts" "app-template" "temp" "$COMMON_CHART_VERSION"
    helm upgrade --install -n $NS office temp/app-template --wait --timeout 600s -f temp/values-office.yaml
fi

## done
log_trace "install success!!!"
log_trace "run command to get boostrap password:"
log_reminder "   kubectl get secret -n $NS nextcloud -o go-template='{{ index .data \"nextcloud-password\" | base64decode }}{{ \"\\\n\" }}'"
