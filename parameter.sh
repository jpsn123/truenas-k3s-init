#!/bin/bash

## global
BRAND_PREFIX='homelab'
DOMAIN='example.com'
EMAIL='system@example.com'
TIMEZONE='Asia/Shanghai'

## k8s
K3S_VERSION='v1.35'
CLUSTER_CIDR='172.30.0.0/16'
SERVICE_CIDR='172.31.0.0/16'
DATA_DIR='/opt/k3s'
LB_IP_RANGE='192.168.100.80-192.168.100.99' ## loadbalancer ip range should be subnetwork of your local network
INGRESS_IP='192.168.100.80'                 ## you need set your local network dns server to resolve *.your-domain.com to your-ingress-ip
COMMON_CHART_VERSION="4.6.2"
DEFAULT_STORAGE_CLASS='fast'                # for default
DEFAULT_SHARED_STORAGE_CLASS='fast'         # for shared
DEFAULT_SHARED_CACHEFS_STORAGE_CLASS='fast' # for shared with cachefs, accelerate io speed
DEFAULT_LARGE_STORAGE_CLASS='mass'          # for large capacity storage

## storage class for zfs-csi
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
