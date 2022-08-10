#!/bin/bash

set -e
cd `dirname $0`
source common.sh
source parameter.sh

# install metalLB   
#####################################
echo -e "\033[42;30m install metalLB\n\033[0m"
helm repo add metallb https://metallb.github.io/metallb
[ -d temp/metallb ] || helm pull metallb/metallb --untar --untardir temp 2>/dev/null || true
METHOD=install
[ `app_is_exist kube-system metallb` == true ] && METHOD=upgrade
helm $METHOD metallb temp/metallb -n kube-system #--set loadBalancerClass="metallb-lbc"

YAML=`cat<<EOF
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
`
echo "$YAML" > ./temp/metallb-config.yaml
k3s kubectl apply -f ./temp/metallb-config.yaml 

k8s_wait kube-system deployment metallb-controller 100
k8s_wait kube-system daemonset metallb-speaker 100