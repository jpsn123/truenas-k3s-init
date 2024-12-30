#!/bin/bash

## kube-system
K3S_VERSION='v1.29'
OFFLINE_INSTALL=false
CLUSTER_CIDR='172.30.0.0/16'
SERVICE_CIDR='172.31.0.0/16'
DATA_DIR='/root/k3s'
DNS_MAIN='114.114.114.114'
DNS_BACKUP=''
DOMAIN=''
LB_IP_RANGE='192.168.100.80-192.168.100.99'  ## loadbalancer ip range should be subnetwork of your local network
INGRESS_IP='192.168.100.80'  ## you need set your local network dns server to resolve *.your-domain.com to your-ingress-ip
INGRESS_ADDITIONAL_HTTP_PORT='8080'
INGRESS_ADDITIONAL_HTTPS_PORT='8443'
ZFS_DATASET_FOR_STORAGE="fast/k8s"
COMMON_CHART_VERSION="3.2.1"
STORAGE_CLASS_NAME="fast"

## rancher server
SUB_DOMAIN='srv'  ## rancher servicer sub-domain, you can access https://srv.your-domain.com to manage your k8s

## acme
ACME_EMAIL=''
ALI_ACCESS_KEY=''
ALI_SECRET_KEY=''
ACME_TEST_SERVER='https://acme-staging-v02.api.letsencrypt.org/directory'  #for test use
ACME_PRODUCT_SERVER='https://acme-v02.api.letsencrypt.org/directory'

## ddns
UPDATE_IPV4=true
UPDATE_IPV6=true
UPDATE_HOSTS="@.$DOMAIN,*.$DOMAIN"