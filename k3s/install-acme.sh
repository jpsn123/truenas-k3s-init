#!/bin/bash

set -e
cd $(dirname $0)
source ../common.sh
source ../parameter.sh

ACME_EMAIL=$(kubectl get clusterissuer "${DOMAIN}-letsencrypt-issuer" -o jsonpath='{.spec.acme.email}' 2>/dev/null || true)
load_secret_vars "cert-manager" "${DOMAIN}-alidns-secret" \
    access-key=ALI_ACCESS_KEY \
    secret-key=ALI_SECRET_KEY

[ -n "$ACME_EMAIL" ] || ACME_EMAIL=$(prompt_required "please input acme email." "acme email" "")
[ -n "$ALI_ACCESS_KEY" ] || ALI_ACCESS_KEY=$(prompt_required "please input aliyun access key." "aliyun access key" "")
[ -n "$ALI_SECRET_KEY" ] || ALI_SECRET_KEY=$(prompt_required "please input aliyun secret key." "aliyun secret key" -s)

# install alidns-webhook for geting certificate automatically
#####################################
log_header "install alidns-webhook"
read CHART_VERSION APP_VERSION < <(get_helm_chart_versions "cert-manager-alidns-webhook" "https://devmachine-fr.github.io/cert-manager-alidns-webhook" "alidns-webhook")
ensure_helm_repo_chart "cert-manager-alidns-webhook" "https://devmachine-fr.github.io/cert-manager-alidns-webhook" "alidns-webhook" "$CHART_VERSION"
helm upgrade --install alidns-webhook temp/alidns-webhook -n cert-manager --wait --timeout 600s --set groupName="acme.${DOMAIN}"
ALIDNS_SECRET_YAML=$(
  cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${DOMAIN}-alidns-secret
  namespace: cert-manager
data:
  access-key: $(echo -n "$ALI_ACCESS_KEY" | base64)
  secret-key: $(echo -n "$ALI_SECRET_KEY" | base64)
EOF
)
echo "$ALIDNS_SECRET_YAML" >./temp/alidns-secret.yaml
kubectl apply -f ./temp/alidns-secret.yaml
ALIDNS_ISSUE_YAML=$(
  cat <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${DOMAIN}-letsencrypt-issuer
spec:
  acme:
    email: ${ACME_EMAIL}
    server: 'https://acme-v02.api.letsencrypt.org/directory'
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
)
echo "$ALIDNS_ISSUE_YAML" >./temp/alidns-issuer.yaml
ALIDNS_ISSUE_YAML=$(
  cat <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${DOMAIN}-letsencrypt-test-issuer
spec:
  acme:
    email: ${ACME_EMAIL}
    server: 'https://acme-staging-v02.api.letsencrypt.org/directory'
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
)
echo "$ALIDNS_ISSUE_YAML" >./temp/alidns-test-issuer.yaml
kubectl apply -f ./temp/alidns-issuer.yaml
kubectl apply -f ./temp/alidns-test-issuer.yaml

# done
log_trace "install alidns-webhook success!!!"
