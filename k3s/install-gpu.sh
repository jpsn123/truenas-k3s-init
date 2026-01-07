#!/bin/bash

set -e
cd $(dirname $0)
source ../common.sh
source ../parameter.sh

# install
#####################################
log_header "install gpu support"

## install device plugin for intel gpu
RES=$(lspci | grep VGA | grep Intel)
if [ -n "$RES" ]; then
    RES=$(kubectl get node -oyaml | grep gpu.intel.com/i915)
    if [ -z "$RES" ]; then
        kubectl apply -k 'https://github.com/intel/intel-device-plugins-for-kubernetes/deployments/nfd?ref=main'
        kubectl apply -k 'https://github.com/intel/intel-device-plugins-for-kubernetes/deployments/nfd/overlays/node-feature-rules?ref=main'
        kubectl apply -n node-feature-discovery -k 'https://github.com/intel/intel-device-plugins-for-kubernetes/deployments/gpu_plugin/overlays/monitoring_shared-dev_nfd?ref=main'
    fi
fi