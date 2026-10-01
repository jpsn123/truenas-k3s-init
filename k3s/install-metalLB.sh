#!/bin/bash

set -e
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../scripts/deploy/paths.sh"
source "$DEPLOY_LIB_DIR/liblog.sh"
source "$DEPLOY_LIB_DIR/libhelm.sh"
source "$DEPLOY_LIB_DIR/libprompt.sh"
source "$DEPLOY_LIB_DIR/libkubernetes.sh"
source "$DEPLOY_ROOT/parameter.sh"
cd "$SCRIPT_DIR"

INSTALL_MODE="${1:-}"

# install metalLB
#####################################
log_header "install metalLB"
NS=kube-system
kube_configmap_load "$NS" "metallb" ip-range=LB_IP_RANGE
if [ -z "$LB_IP_RANGE" ]; then
    LB_IP_RANGE=$(prompt_with_default "please input metalLB config." "load balancer ip range" "192.168.100.80-192.168.100.99")
fi
kube_configmap_apply_vars "$NS" "metallb" ip-range=LB_IP_RANGE
if [ "$INSTALL_MODE" == "reinstall" ]; then
    helm_ensure_chart "metallb" "https://metallb.github.io/metallb" "metallb" "temp"
else
    VERSION_PAIR=$(helm_chart_versions "metallb" "https://metallb.github.io/metallb" "metallb")
    read -r CHART_VERSION APP_VERSION <<<"$VERSION_PAIR"
    helm_ensure_chart "metallb" "https://metallb.github.io/metallb" "metallb" "temp" "$CHART_VERSION"
fi
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
