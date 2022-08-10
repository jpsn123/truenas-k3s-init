#!/bin/bash

set -e
cd `dirname $0`
source common.sh
source parameter.sh

# install alidns-webhook for geting certificate automatically
#####################################
echo -e "\033[42;30m install alidns-webhook for geting certificate automatically\n\033[0m"
helm repo add cert-manager-alidns-webhook https://devmachine-fr.github.io/cert-manager-alidns-webhook
[ -d temp/alidns-webhook ] || helm pull cert-manager-alidns-webhook/alidns-webhook --untar --untardir temp 2>/dev/null || true
METHOD=install
[ `app_is_exist cert-manager alidns-webhook` == true ] && METHOD=upgrade
helm $METHOD alidns-webhook temp/alidns-webhook -n cert-manager --set groupName="acme.${DOMAIN}"
k8s_wait cert-manager deployment alidns-webhook 50
ALIDNS_SECRET_YAML=`cat<<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${DOMAIN}-alidns-secret
  namespace: cert-manager
data:
  access-key: $(echo -n "$ALI_ACCESS_KEY" | base64)
  secret-key: $(echo -n "$ALI_SECRET_KEY" | base64)
EOF
`
echo "$ALIDNS_SECRET_YAML">./temp/alidns-secret.yaml
k3s kubectl apply -f ./temp/alidns-secret.yaml
ALIDNS_ISSUE_YAML=`cat<<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${DOMAIN}-letsencrypt-issuer
spec:
  acme:
    email: $EMAIL
    server: $ACME_PRODUCT_SERVER
    #disableAccountKeyGeneration: true
    privateKeySecretRef:
      name: ${DOMAIN}-letsencrypt-key
    solvers:
    - dns01:
        webhook:
          config:
            accessTokenSecretRef:
              name: ${DOMAIN}-alidns-secret
              key: access-key
            regionId: cn-beijing
            secretKeySecretRef:
              name: ${DOMAIN}-alidns-secret
              key: secret-key
          groupName: acme.${DOMAIN}
          solverName: alidns-solver
      selector:
        dnsZones:
        - '${DOMAIN}'
EOF
`
echo "$ALIDNS_ISSUE_YAML">./temp/alidns-issuer.yaml
ALIDNS_ISSUE_YAML=`cat<<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${DOMAIN}-letsencrypt-test-issuer
spec:
  acme:
    email: $EMAIL
    server: $ACME_TEST_SERVER
    disableAccountKeyGeneration: true
    privateKeySecretRef:
      name: ${DOMAIN}-letsencrypt-key
    solvers:
    - dns01:
        webhook:
          config:
            accessTokenSecretRef:
              name: ${DOMAIN}-alidns-secret
              key: access-key
            regionId: cn-beijing
            secretKeySecretRef:
              name: ${DOMAIN}-alidns-secret
              key: secret-key
          groupName: acme.${DOMAIN}
          solverName: alidns-solver
      selector:
        dnsZones:
        - '${DOMAIN}'
EOF
`
echo "$ALIDNS_ISSUE_YAML">./temp/alidns-test-issuer.yaml
k3s kubectl apply -f ./temp/alidns-issuer.yaml
k3s kubectl apply -f ./temp/alidns-test-issuer.yaml