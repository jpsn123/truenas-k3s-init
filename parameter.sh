#!/bin/bash

BRAND_PREFIX='jpsn'
REGISTRY_MIRRORS='https://docker.mirrors.ustc.edu.cn'  ## optional: 'https://iul02qsw.mirror.aliyuncs.com'
EMAIL='jpsn@foxmail.com'
DNS_MAIN='114.114.114.114'
DNS_BACKUP=''
DOMAIN='jpsn.site'
LB_IP_RANGE='192.168.31.80-192.168.31.99'  ## loadbalancer ip range should be subnetwork of your local network
INGRESS_IP='192.168.31.80'  ## you need set your local network dns server to resolve *.your-domain.com to your-ingress-ip

CLUSTER_NAME="$BRAND_PREFIX-cloud"

SUB_DOMAIN='srv'  ## rancher servicer sub-domain, you can access https://srv.your-domain.com to manage your k8s
ALI_ACCESS_KEY=''
ALI_SECRET_KEY=''

ACME_TEST_SERVER='https://acme-staging-v02.api.letsencrypt.org/directory'  #for test use
ACME_PRODUCT_SERVER='https://acme-v02.api.letsencrypt.org/directory'