#!/bin/bash

set -e
cd $(dirname $0)
source ../common.sh
source ../parameter.sh

# install
#####################################
log_header "install zfs csi"

helm repo add openebs https://openebs.github.io/charts 2>/dev/null || true
[ -d temp/openebs ] || (helm repo update openebs && helm pull openebs/openebs --untar --untardir temp)
helm upgrade --install --create-namespace zfs-csi temp/openebs -n openebs --wait --timeout 600s -f values-openebs.yaml

zfs create ${ZFS_POOL_FOR_STORAGE} 2>/dev/null || true
ZFS_SC=$(
    cat <<EOF
allowVolumeExpansion: true
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
  name: ${DEFAULT_STORAGE_CLASS}
parameters:
  fstype: zfs
  poolname: ${ZFS_DATASET_FOR_STORAGE}
  shared: "yes"
provisioner: zfs.csi.openebs.io
reclaimPolicy: Delete
volumeBindingMode: Immediate
EOF
)
echo "$ZFS_SC" >./temp/local-zfs-sc.yaml
kubectl apply -f ./temp/local-zfs-sc.yaml