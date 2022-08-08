#!/bin/bash

set -e
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../scripts/deploy/paths.sh"
source "$DEPLOY_LIB_DIR/liblog.sh"
source "$DEPLOY_LIB_DIR/libhelm.sh"
source "$DEPLOY_ROOT/parameter.sh"
cd "$SCRIPT_DIR"

INSTALL_MODE="${1:-}"

# install
#####################################
log_header "install zfs csi"
if [ "$INSTALL_MODE" == "reinstall" ]; then
    helm_ensure_chart "openebs" "https://openebs.github.io/openebs" "openebs" "temp"
else
    VERSION_PAIR=$(helm_chart_versions "openebs" "https://openebs.github.io/openebs" "openebs")
    read -r CHART_VERSION APP_VERSION <<<"$VERSION_PAIR"
    helm_ensure_chart "openebs" "https://openebs.github.io/openebs" "openebs" "temp" "$CHART_VERSION"
fi
helm upgrade --install --create-namespace zfs-csi temp/openebs -n openebs --wait --timeout 600s -f values-openebs.yaml

## enable fsGroup permission handling for RWX volumes
log_info "set zfs csi fsGroupPolicy to File"
kubectl patch csidriver zfs.csi.openebs.io --type merge -p '{"spec":{"fsGroupPolicy":"File"}}'

## create storageclass
log_info "create storageclass"
echo "$STORAGE_CLASS_YAML" >./temp/storageclass.yaml
kubectl apply -f ./temp/storageclass.yaml

## create snapshotclass
log_info "create snapshotclass"
echo "$SNAPSHOT_CLASS_YAML" >./temp/volumesnapshot-class.yaml
kubectl apply -f ./temp/volumesnapshot-class.yaml
