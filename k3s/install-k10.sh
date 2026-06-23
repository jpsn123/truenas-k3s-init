#!/bin/bash

set -e
cd $(dirname $0)
source ../common.sh
source ../parameter.sh

NS=kasten-io
INSTALL_MODE="$1"
trap 'rm -rf temp/k10-docker-config' EXIT

# functions
function ensure_k10_image() {
    local IMAGE="$1"
    local CONTEXT="$2"
    local BASE_IMAGE="$3"

    if [ "$K10_USE_CUSTOM_REGISTRY" == "y" ]; then
        if k3s_crictl_pull_image "$IMAGE" "$K10_REGISTRY_USERNAME" "$K10_REGISTRY_TOKEN"; then
            log_info "image is pullable: $IMAGE"
            return
        fi
        build_image_with_buildkit "$CONTEXT" "$IMAGE" "$K10_BUILDKIT_ADDR" "temp/k10-docker-config" "$BASE_IMAGE"
    else
        if k3s_crictl_pull_image "$IMAGE"; then
            log_info "image is pullable: $IMAGE"
            return
        fi
        log_error "image $IMAGE for k10 version $VERSION does not exist. please build it manually, then rerun this script."
        exit 1
    fi
}

# install k10 for backup
#####################################
log_header "install k10 for backup"
kubectl create namespace $NS 2>/dev/null || true
load_secret_vars "$NS" "k10-cluster-passphrase" passphrase=PASSWD
if [ -z "$PASSWD" ]; then
    PASSWORD_SEED=$(prompt_required "please input admin password seed for k10." "password seed" "")
    PASSWD=$(derive_password_sha1 "$PASSWORD_SEED" "k10" 32)
fi
load_secret_vars "$NS" "k10-custom-images" \
    use-custom-registry=K10_USE_CUSTOM_REGISTRY \
    registry-url=K10_REGISTRY_URL \
    registry-username=K10_REGISTRY_USERNAME \
    registry-token=K10_REGISTRY_TOKEN \
    buildkit-addr=K10_BUILDKIT_ADDR \
    kanister-tools-image=K10_KANISTER_TOOLS_IMAGE \
    metering-image=K10_METERING_IMAGE \
    license=K10_LICENSE_VALUE
if [ "$INSTALL_MODE" == "reinstall" ]; then
    ensure_helm_repo_chart "kasten" "https://charts.kasten.io/" "k10"
    resolve_chart_app_version "k10" CHART_VERSION VERSION
else
    read -r CHART_VERSION DEFAULT_VERSION <<<"$(get_helm_chart_versions "kasten" "https://charts.kasten.io/" "k10")"
    VERSION=$(prompt_with_default "please input k10 version." "version" "$DEFAULT_VERSION")
    if [ "$VERSION" != "$DEFAULT_VERSION" ]; then
        read -r CHART_VERSION _ <<<"$(get_helm_chart_versions "kasten" "https://charts.kasten.io/" "k10" "$VERSION")"
    fi
fi
if [ -z "$K10_USE_CUSTOM_REGISTRY" ]; then
    K10_USE_CUSTOM_REGISTRY=$(prompt_with_default "please select k10 custom registry config." "use custom registry? (y/n)" "n")
fi
if [[ "$K10_USE_CUSTOM_REGISTRY" =~ ^[Yy]$ ]]; then
    K10_USE_CUSTOM_REGISTRY=y
else
    K10_USE_CUSTOM_REGISTRY=n
fi

if [ "$K10_USE_CUSTOM_REGISTRY" == "y" ]; then
    [ -n "$K10_REGISTRY_URL" ] || K10_REGISTRY_URL=$(prompt_with_default "please input k10 custom registry config." "registry url" "hub.bin.$DOMAIN")
    [ -n "$K10_REGISTRY_USERNAME" ] || K10_REGISTRY_USERNAME=$(prompt_required "" "registry username" "")
    [ -n "$K10_REGISTRY_TOKEN" ] || K10_REGISTRY_TOKEN=$(prompt_required "" "registry token" -s)
    [ -n "$K10_BUILDKIT_ADDR" ] || K10_BUILDKIT_ADDR=$(prompt_with_default "" "buildkit address" "tcp://buildkit.buildkit.svc.cluster.local:1234")
    K10_REGISTRY_HOST=$(normalize_registry_host "$K10_REGISTRY_URL")
else
    [ -n "$K10_REGISTRY_URL" ] || K10_REGISTRY_URL=$(prompt_with_default "please input k10 registry config." "registry url" "hub.bin.$DOMAIN")
    K10_REGISTRY_USERNAME=""
    K10_REGISTRY_TOKEN=""
    K10_BUILDKIT_ADDR=""
    K10_REGISTRY_HOST=$(normalize_registry_host "$K10_REGISTRY_URL")
fi

K10_KANISTER_TOOLS_IMAGE_PATH=$(strip_image_registry "$K10_KANISTER_TOOLS_IMAGE")
K10_METERING_IMAGE_PATH=$(strip_image_registry "$K10_METERING_IMAGE")
if [ -z "$K10_KANISTER_TOOLS_IMAGE_PATH" ]; then
    K10_KANISTER_TOOLS_IMAGE_PATH=$(prompt_with_default "please input k10 custom images." "kanister tools image name" "$BRAND_PREFIX/kanister-tools")
fi
if [ -z "$K10_METERING_IMAGE_PATH" ]; then
    K10_METERING_IMAGE_PATH=$(prompt_with_default "" "kasten metering image name" "$BRAND_PREFIX/kasten-metering")
fi
K10_KANISTER_TOOLS_IMAGE="$K10_REGISTRY_HOST/${K10_KANISTER_TOOLS_IMAGE_PATH#/}"
K10_METERING_IMAGE="$K10_REGISTRY_HOST/${K10_METERING_IMAGE_PATH#/}"
K10_KANISTER_TOOLS_FULL_IMAGE="$K10_KANISTER_TOOLS_IMAGE:$VERSION"
K10_METERING_FULL_IMAGE="$K10_METERING_IMAGE:$VERSION"

if [ -n "$K10_METERING_IMAGE" ] && [ -z "$K10_LICENSE_VALUE" ]; then
    K10_LICENSE_VALUE=$(prompt_with_default "" "license" "Y3VzdG9tZXJOYW1lOiBwcmVtaXVtLWxpY2Vuc2UKZGF0ZUVuZDogJzIxMDAtMDEtMDFUMDA6MDA6MDAuMDAwWicKZGF0ZVN0YXJ0OiAnMjAyMC0wMS0wMVQwMDowMDowMC4wMDBaJwpmZWF0dXJlczogbnVsbAppZDogcHJlbWl1bS0wYWY4MzE5Zi0xODBmLTRhOTAtOTE3My1kOTJiNzZmMTgzNTEKcHJvZHVjdDogSzEwCnJlc3RyaWN0aW9uczoKICBub2RlczogNTAwCnNlcnZpY2VBY2NvdW50S2V5OiBudWxsCnZlcnNpb246IHYxLjAuMApzaWduYXR1cmU6IEYxbnVLUFV5STJtbDJGMmV1VHdGOXNZRTZMVU5rQ3ZiR2tTV1ZkT0ZqdERCb1B6SjUyVWFsVkFmRjVmQUxpcm5BcVhkcERnYi9YcnpxSEYrTE0xS2pEMVdXUFd0ZUdXNFc1anBPSFN0T296Y0c5M0pUUHF5M2l6TVk3RmczZVFLYTZzWDhBdnFwOXArWXVBMWNwTENlQ2dsR2dnOTVzSUFmYmRMMTBmV2d2RmR6QUt4dUZLN2psRzVtbG1CRVF5R0hrYWdoZFIrVGxzeUNTNEFkbXVBOEZodVUwZnRBdXN0b1M3R2JKd1BuTFI3STFZY1Q4OW8wU2xRZEJ2Yjg2QzdKbm1OdnY0aHhiSUo5TTJvWGJPSnQ4ZnBNcjhNWFR6YWRMTWJzSndhZ3VBVHlNUWF2cExHNXRPb0U2ZE1uMVlFVDZLdWZiYy9NdThVRDVYYXlDYTdkZz09Cg==")
fi
render_values_file_to_temp values-k10.yaml
apply_secret_vars "$NS" "k10-cluster-passphrase" passphrase=PASSWD
apply_secret_vars "$NS" "k10-dr-secret" key=PASSWD
apply_secret_vars "$NS" "kopia-repo-password" password=PASSWD
apply_secret_vars "$NS" "k10-custom-images" \
    use-custom-registry=K10_USE_CUSTOM_REGISTRY \
    registry-url=K10_REGISTRY_URL \
    registry-username=K10_REGISTRY_USERNAME \
    registry-token=K10_REGISTRY_TOKEN \
    buildkit-addr=K10_BUILDKIT_ADDR \
    kanister-tools-image=K10_KANISTER_TOOLS_IMAGE \
    metering-image=K10_METERING_IMAGE \
    license=K10_LICENSE_VALUE
if [ "$K10_USE_CUSTOM_REGISTRY" == "y" ]; then
    apply_docker_registry_secret "$NS" "k10-custom-registry" "$K10_REGISTRY_HOST" "$K10_REGISTRY_USERNAME" "$K10_REGISTRY_TOKEN"
    write_docker_registry_auth_config "temp/k10-docker-config" "$K10_REGISTRY_HOST" "$K10_REGISTRY_USERNAME" "$K10_REGISTRY_TOKEN"
fi
ensure_k10_image "$K10_KANISTER_TOOLS_FULL_IMAGE" "kanister-tools-image" "gcr.io/kasten-images/kanister-tools:$VERSION"
ensure_k10_image "$K10_METERING_FULL_IMAGE" "kasten-metering-image" "gcr.io/kasten-images/metering:$VERSION"
kubectl annotate volumesnapshotclass \
    $(kubectl get volumesnapshotclass -o=jsonpath='{.items[?(@.metadata.annotations.snapshot\.storage\.kubernetes\.io\/is-default-class=="true")].metadata.name}') \
    k10.kasten.io/is-snapshot-class=true

# install
ensure_helm_repo_chart "kasten" "https://charts.kasten.io/" "k10" "$CHART_VERSION"
helm upgrade --install -n $NS k10 temp/k10 -f temp/values-k10.yaml

# change config excludedApps
RANCHER_NS_ARR=$(kubectl get ns -o=jsonpath='{.items[*].metadata.name}' | tr " " "\n" | grep -E 'cattle-|fleet-|local|p-[a-z0-9]+|user-|u-[a-z0-9]+')
IGNORE_STR=$(kubectl -n kasten-io get configmaps k10-config -o=jsonpath='{.data.excludedApps}')
NS_IGNORE_ARR=(${IGNORE_STR//,/ })
IGNORE_STR=($(echo "${RANCHER_NS_ARR[@]}" "${NS_IGNORE_ARR[@]}" | tr ' ' '\n' | sort -u | tr '\n' ','))
kubectl -n $NS patch configmap k10-config --type merge --patch \
    "{\"data\":{\"excludedApps\":\"${IGNORE_STR:0:-1}\"}}"

# customize tool-images for self-defined kopia repo password
kubectl -n $NS patch configmap k10-config --type merge --patch \
    "{\"data\":{\"KanisterToolsImage\":\"$K10_KANISTER_TOOLS_FULL_IMAGE\"}}"

# use custom metering image
if [ -n "$K10_METERING_IMAGE" ]; then
    PATCH=$(
        cat <<EOF
spec:
  template:
    spec:
      containers:
      - name: metering-svc
        image: $K10_METERING_FULL_IMAGE
EOF
    )
    kubectl patch -n $NS deployment metering-svc --patch "$PATCH"
fi

# kill all k10 pods to reload config
kubectl -n $NS delete pod -l app.kubernetes.io/instance=k10

# create k10 admin token
#####################################
log_header "create k10 admin token"
kubectl --namespace kasten-io create serviceaccount my-k10-admin 2>/dev/null || true
kubectl apply --namespace=kasten-io --filename=- <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels:
    app.kubernetes.io/instance: k10
    app.kubernetes.io/name: k10
  name: kasten-my-k10-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: my-k10-admin
    namespace: kasten-io
EOF
kubectl apply --namespace=kasten-io --filename=- <<EOF
apiVersion: v1
kind: Secret
type: kubernetes.io/service-account-token
metadata:
  name: my-k10-admin
  annotations:
    kubernetes.io/service-account.name: "my-k10-admin"
EOF
TOKEN=$(get_secret_value "kasten-io" "my-k10-admin" "token")
log_trace "\nk10 admin token: \n"
log_reminder "$TOKEN \n"

# done
log_trace "install k10 success!!!"
