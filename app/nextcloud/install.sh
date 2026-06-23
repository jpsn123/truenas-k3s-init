#!/bin/bash

set -e
cd $(dirname $0)
source ../../common.sh
source ../../parameter.sh
NS=nextcloud
INSTALL_MODE="${1:-full}"
validate_install_mode "$INSTALL_MODE" postgresql redis nextcloud office
trap 'rm -rf temp/nextcloud-docker-config' EXIT

# functions
function ensure_nextcloud_image() {
    local IMAGE="$1"
    local CONTEXT="$2"
    local BASE_IMAGE="$3"

    if [ "$NEXTCLOUD_USE_CUSTOM_REGISTRY" == "y" ]; then
        if k3s_crictl_pull_image "$IMAGE" "$NEXTCLOUD_REGISTRY_USERNAME" "$NEXTCLOUD_REGISTRY_TOKEN"; then
            log_info "image is pullable: $IMAGE"
            return
        fi
        build_image_with_buildkit "$CONTEXT" "$IMAGE" "$NEXTCLOUD_BUILDKIT_ADDR" "temp/nextcloud-docker-config" "$BASE_IMAGE"
    else
        if k3s_crictl_pull_image "$IMAGE"; then
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
load_secret_vars "$NS" "redis" redis-password=REDIS_PW
load_secret_vars "$NS" "postgresql" password=DB_PW
load_secret_vars "$NS" "nextcloud" nextcloud-password=NEXTCLOUD_PW
load_secret_vars "$NS" "nextcloud-custom-image" \
    use-custom-registry=NEXTCLOUD_USE_CUSTOM_REGISTRY \
    registry-url=NEXTCLOUD_REGISTRY_URL \
    registry-username=NEXTCLOUD_REGISTRY_USERNAME \
    registry-token=NEXTCLOUD_REGISTRY_TOKEN \
    buildkit-addr=NEXTCLOUD_BUILDKIT_ADDR \
    image-repository=NEXTCLOUD_IMAGE_REPOSITORY
load_configmap_vars "$NS" "nextcloud-install-version" \
    chart-version=NEXTCLOUD_CHART_VERSION \
    app-version=NEXTCLOUD_APP_VERSION \
    image-version=NEXTCLOUD_IMAGE_VERSION
if (install_mode_enabled "$INSTALL_MODE" redis && [ -z "$REDIS_PW" ]) \
    || (install_mode_enabled "$INSTALL_MODE" postgresql && [ -z "$DB_PW" ]) \
    || (install_mode_enabled "$INSTALL_MODE" nextcloud && [ -z "$NEXTCLOUD_PW" ]); then
    PASSWORD_SEED=$(prompt_required "please input password seed for setting nextcloud." "password seed" "")
fi
if install_mode_enabled "$INSTALL_MODE" redis && [ -z "$REDIS_PW" ]; then
    REDIS_PW=$(derive_password_sha1 "$PASSWORD_SEED" "$NS@redis" 32)
fi
if install_mode_enabled "$INSTALL_MODE" postgresql && [ -z "$DB_PW" ]; then
    DB_PW=$(derive_password_sha1 "$PASSWORD_SEED" "$NS@pg" 32)
fi
if install_mode_enabled "$INSTALL_MODE" nextcloud && [ -z "$NEXTCLOUD_PW" ]; then
    NEXTCLOUD_PW=$(derive_password_sha1 "$PASSWORD_SEED" "$NS@nextcloud" 32)
fi

if install_mode_enabled "$INSTALL_MODE" nextcloud; then
    if [ "$INSTALL_MODE" != "reinstall" ]; then
        NEXTCLOUD_IMAGE_VERSION=""
        NEXTCLOUD_CHART_VERSION=""
    fi

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
        [ -n "$NEXTCLOUD_BUILDKIT_ADDR" ] || NEXTCLOUD_BUILDKIT_ADDR=$(prompt_with_default "" "buildkit address" "tcp://buildkit.buildkit.svc.cluster.local:1234")
    else
        [ -n "$NEXTCLOUD_REGISTRY_URL" ] || NEXTCLOUD_REGISTRY_URL=$(prompt_with_default "please input nextcloud registry config." "registry url" "hub.bin.$DOMAIN")
        NEXTCLOUD_REGISTRY_USERNAME=""
        NEXTCLOUD_REGISTRY_TOKEN=""
        NEXTCLOUD_BUILDKIT_ADDR=""
    fi
    NEXTCLOUD_REGISTRY_HOST=$(normalize_registry_host "$NEXTCLOUD_REGISTRY_URL")

    NEXTCLOUD_IMAGE_PATH=$(strip_image_registry "$NEXTCLOUD_IMAGE_REPOSITORY")
    if [ -z "$NEXTCLOUD_IMAGE_PATH" ]; then
        NEXTCLOUD_IMAGE_PATH=$(prompt_with_default "please input nextcloud image config." "nextcloud image name" "$BRAND_PREFIX/nextcloud")
    fi
    if [ "$INSTALL_MODE" == "reinstall" ]; then
        if [ -z "$NEXTCLOUD_IMAGE_VERSION" ] || [ -z "$NEXTCLOUD_CHART_VERSION" ]; then
            log_error "missing nextcloud version configmap, please run full or nextcloud mode first."
            exit 1
        fi
    else
        read -r NEXTCLOUD_CHART_VERSION DEFAULT_NEXTCLOUD_APP_VERSION <<<"$(get_helm_chart_versions "nextcloud" "https://nextcloud.github.io/helm/" "nextcloud")"
        NEXTCLOUD_IMAGE_VERSION=$(prompt_with_default "" "nextcloud image version" "$DEFAULT_NEXTCLOUD_APP_VERSION-fpm")
        NEXTCLOUD_APP_VERSION="${NEXTCLOUD_IMAGE_VERSION%%-*}"
        if [ "$NEXTCLOUD_APP_VERSION" != "$DEFAULT_NEXTCLOUD_APP_VERSION" ]; then
            read -r NEXTCLOUD_CHART_VERSION _ <<<"$(get_helm_chart_versions "nextcloud" "https://nextcloud.github.io/helm/" "nextcloud" "$NEXTCLOUD_APP_VERSION")"
        fi
        apply_configmap_vars "$NS" "nextcloud-install-version" \
            chart-version=NEXTCLOUD_CHART_VERSION \
            app-version=NEXTCLOUD_APP_VERSION \
            image-version=NEXTCLOUD_IMAGE_VERSION
    fi
    NEXTCLOUD_IMAGE_REPOSITORY="$NEXTCLOUD_REGISTRY_HOST/${NEXTCLOUD_IMAGE_PATH#/}"
    NEXTCLOUD_FULL_IMAGE="$NEXTCLOUD_IMAGE_REPOSITORY:$NEXTCLOUD_IMAGE_VERSION"

    NEXTCLOUD_USERNAME=admin
    apply_secret_vars "$NS" "nextcloud" \
        nextcloud-username=NEXTCLOUD_USERNAME \
        nextcloud-password=NEXTCLOUD_PW
    apply_secret_vars "$NS" "nextcloud-custom-image" \
        use-custom-registry=NEXTCLOUD_USE_CUSTOM_REGISTRY \
        registry-url=NEXTCLOUD_REGISTRY_URL \
        registry-username=NEXTCLOUD_REGISTRY_USERNAME \
        registry-token=NEXTCLOUD_REGISTRY_TOKEN \
        buildkit-addr=NEXTCLOUD_BUILDKIT_ADDR \
        image-repository=NEXTCLOUD_IMAGE_REPOSITORY
    if [ "$NEXTCLOUD_USE_CUSTOM_REGISTRY" == "y" ]; then
        apply_docker_registry_secret "$NS" "nextcloud-custom-registry" "$NEXTCLOUD_REGISTRY_HOST" "$NEXTCLOUD_REGISTRY_USERNAME" "$NEXTCLOUD_REGISTRY_TOKEN"
        write_docker_registry_auth_config "temp/nextcloud-docker-config" "$NEXTCLOUD_REGISTRY_HOST" "$NEXTCLOUD_REGISTRY_USERNAME" "$NEXTCLOUD_REGISTRY_TOKEN"
    fi
    ensure_nextcloud_image "$NEXTCLOUD_FULL_IMAGE" "nextcloud-full-img" "nextcloud:$NEXTCLOUD_IMAGE_VERSION"
fi

if install_mode_enabled "$INSTALL_MODE" office && [ "$INSTALL_MODE" != "reinstall" ]; then
    ensure_helm_repo_chart "bjw-s" "https://bjw-s-labs.github.io/helm-charts" "app-template" "$COMMON_CHART_VERSION"
fi
render_values_file_to_temp values-*.yaml
if install_mode_enabled "$INSTALL_MODE" nextcloud; then
    kubectl -n $NS apply -f temp/values-configs.yaml
    kubectl -n $NS apply -f temp/values-important-pvc.yaml
fi

# install postgresql
#####################################
if install_mode_enabled "$INSTALL_MODE" postgresql; then
    log_header "install postgresql"
    ensure_helm_repo_chart "bitnami" "oci://registry-1.docker.io/bitnamicharts" "postgresql" "16.7.27"
    helm upgrade --install -n $NS postgresql temp/postgresql --wait --timeout 600s -f temp/values-postgresql.yaml \
        --set global.postgresql.auth.postgresPassword=$DB_PW \
        --set global.postgresql.auth.password=$DB_PW \
        --set auth.replicationPassword=$DB_PW
    kubectl -n $NS patch secret postgresql --type merge --patch \
        "{\"data\":{\"username\":\"$(echo -n nextcloud | base64)\"}}"
fi

# install redis
#####################################
if install_mode_enabled "$INSTALL_MODE" redis; then
    log_header "install redis"
    ensure_helm_repo_chart "bitnami" "oci://registry-1.docker.io/bitnamicharts" "redis" "22.0.7"
    helm upgrade --install -n $NS redis temp/redis --wait --timeout 600s -f temp/values-redis.yaml \
        --set global.redis.password=$REDIS_PW
fi

# install nextcloud
#####################################
if install_mode_enabled "$INSTALL_MODE" nextcloud; then
    log_header "install nextcloud"
    ensure_helm_repo_chart "nextcloud" "https://nextcloud.github.io/helm/" "nextcloud" "$NEXTCLOUD_CHART_VERSION"
    helm upgrade --install -n $NS nextcloud temp/nextcloud --wait --timeout 1200s -f temp/values-nextcloud.yaml --set replicaCount=1
fi

# install office
#####################################
if install_mode_enabled "$INSTALL_MODE" office; then
    log_header "install office plugin"
    ensure_helm_repo_chart "bjw-s" "https://bjw-s-labs.github.io/helm-charts" "app-template" "$COMMON_CHART_VERSION"
    helm upgrade --install -n $NS office temp/app-template --wait --timeout 600s -f temp/values-office.yaml
fi

## done
log_trace "install success!!!"
log_trace "run command to get boostrap password:"
log_reminder "   kubectl get secret -n $NS nextcloud -o go-template='{{ index .data \"nextcloud-password\" | base64decode }}{{ \"\\\n\" }}'"
