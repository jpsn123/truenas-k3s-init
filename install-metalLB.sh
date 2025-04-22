#!/bin/bash

set -e
cd $(dirname $0)
source common.sh
source parameter.sh

# install metalLB
#####################################
log_header "install metalLB"
helm repo add metallb https://metallb.github.io/metallb
[ -d temp/metallb ] || (helm repo update metallb && helm pull metallb/metallb --untar --untardir temp)
helm upgrade --install metallb temp/metallb -n kube-system #--set loadBalancerClass="metallb-lbc"

k8s_wait kube-system deployment metallb-controller 100

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

k8s_wait kube-system daemonset metallb-speaker 100

## done
log_trace "init success!!!"
