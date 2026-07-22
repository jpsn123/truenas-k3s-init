#!/bin/bash

set -e
cd $(dirname $0)
source ../common.sh
source ../parameter.sh

# install
#####################################
log_header "install zfs csi"
read CHART_VERSION APP_VERSION <<<"$(get_helm_chart_versions "openebs" "https://openebs.github.io/openebs" "openebs")"
ensure_helm_repo_chart "openebs" "https://openebs.github.io/openebs" "openebs" "$CHART_VERSION"
helm upgrade --install --create-namespace zfs-csi temp/openebs -n openebs --wait --timeout 600s -f values-openebs.yaml

## create storageclass
log_info "create storageclass"
echo "$STORAGE_CLASS_YAML" >./temp/storageclass.yaml
kubectl apply -f ./temp/storageclass.yaml

## create snapshotclass
log_info "create snapshotclass"
echo "$SNAPSHOT_CLASS_YAML" >./temp/volumesnapshot-class.yaml
kubectl apply -f ./temp/volumesnapshot-class.yaml
