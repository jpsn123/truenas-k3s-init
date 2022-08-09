#!/bin/bash

BRAND_PREFIX='jpsn'
REGISTRY_MIRRORS='https://docker.mirrors.ustc.edu.cn' ## optional: 'https://iul02qsw.mirror.aliyuncs.com'
EMAIL='jpsn@foxmail.com'
DNS_MAIN='114.114.114.114'
DNS_BACKUP=''
DNS_DOMAIN='jpsn.site'
LAN_RANGE='192.168.31.80-192.168.31.99'

CLUSTER_NAME="$BRAND_PREFIX-cloud"

SUB_DOMAIN='srv'
ALI_ACCESS_KEY=''
ALI_SECRET_KEY=''

ACME_TEST_SERVER='https://acme-staging-v02.api.letsencrypt.org/directory' #for test use
ACME_PRODUCT_SERVER='https://acme-v02.api.letsencrypt.org/directory'