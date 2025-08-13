#!/bin/bash

## global
BRAND_PREFIX='mycloud'
EMAIL=''
TIMEZONE='Asia/Shanghai'

## k8s
K3S_VERSION='v1.32'
CLUSTER_CIDR='172.30.0.0/16'
SERVICE_CIDR='172.31.0.0/16'
DATA_DIR='/opt/k3s'
LB_IP_RANGE='192.168.100.80-192.168.100.99' ## loadbalancer ip range should be subnetwork of your local network
INGRESS_IP='192.168.100.80'                 ## you need set your local network dns server to resolve *.your-domain.com to your-ingress-ip
DOMAIN=''
ZFS_DATASET_FOR_STORAGE="fast/k8s"
DEFAULT_STORAGE_CLASS='fast'                # for default
DEFAULT_SHARED_STORAGE_CLASS='fast'         # for shared
DEFAULT_SHARED_CACHEFS_STORAGE_CLASS='mass' # for shared with cachefs, accelerate io speed
DEFAULT_LARGE_STORAGE_CLASS='mass'          # for large capacity storage
COMMON_CHART_VERSION="4.1.1"

## acme
ACME_EMAIL=''
ALI_ACCESS_KEY=''
ALI_SECRET_KEY=''
