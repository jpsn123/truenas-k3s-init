#!/bin/bash

set -e
cd $(dirname $0)
source ../common.sh
source ../parameter.sh

# install metalLB
#####################################
log_header "install metalLB"
read CHART_VERSION APP_VERSION <<<"$(get_helm_chart_versions "metallb" "https://metallb.github.io/metallb" "metallb")"
ensure_helm_repo_chart "metallb" "https://metallb.github.io/metallb" "metallb" "$CHART_VERSION"
helm upgrade --install metallb temp/metallb -n kube-system --wait --timeout 600s #--set loadBalancerClass="metallb-lbc"

YAML=$(
  cat <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lan-pool
  namespace: kube-system
spec:
  addresses:
  - "$LB_IP_RANGE"
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2-advertisement
  namespace: kube-system
spec:
  ipAddressPools:
  - lan-pool
EOF
)
echo "$YAML" >./temp/metallb-config.yaml
kubectl apply -f ./temp/metallb-config.yaml

## done
log_trace "init success!!!"
