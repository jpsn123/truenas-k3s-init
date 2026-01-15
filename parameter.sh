#!/bin/bash

## global
BRAND_PREFIX='mycloud'
EMAIL=''
TIMEZONE='Asia/Shanghai'

## k8s
K3S_VERSION='v1.33'
CLUSTER_CIDR='172.30.0.0/16'
SERVICE_CIDR='172.31.0.0/16'
DATA_DIR='/opt/k3s'
LB_IP_RANGE='192.168.100.80-192.168.100.99' ## loadbalancer ip range should be subnetwork of your local network
INGRESS_IP='192.168.100.80'                 ## you need set your local network dns server to resolve *.your-domain.com to your-ingress-ip
DOMAIN=''
COMMON_CHART_VERSION="4.3.0"

## acme
ACME_EMAIL=''
ALI_ACCESS_KEY=''
ALI_SECRET_KEY=''

## csi for k8s
DEFAULT_STORAGE_CLASS='fast'                # for default
DEFAULT_SHARED_STORAGE_CLASS='fast'         # for shared
DEFAULT_SHARED_CACHEFS_STORAGE_CLASS='fast' # for shared with cachefs, accelerate io speed
DEFAULT_LARGE_STORAGE_CLASS='mass'          # for large capacity storage
STORAGE_CLASS_YAML=$(
  cat <<EOF
allowVolumeExpansion: true
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
  name: fast
parameters:
  fstype: zfs
  poolname: fast/k8s
  shared: "yes"
provisioner: zfs.csi.openebs.io
reclaimPolicy: Delete
volumeBindingMode: Immediate
---
allowVolumeExpansion: true
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  annotations:
  name: mass
parameters:
  fstype: zfs
  poolname: mass/k8s
  shared: "yes"
provisioner: zfs.csi.openebs.io
reclaimPolicy: Delete
volumeBindingMode: Immediate
EOF
)

SNAPSHOT_CLASS_YAML=$(
  cat <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: zfs-csi
  annotations:
    snapshot.storage.kubernetes.io/is-default-class: "true"
driver: zfs.csi.openebs.io
deletionPolicy: Delete
---
EOF
)
