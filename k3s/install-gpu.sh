#!/bin/bash

set -e
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../scripts/deploy/paths.sh"
source "$DEPLOY_LIB_DIR/liblog.sh"
source "$DEPLOY_ROOT/parameter.sh"
cd "$SCRIPT_DIR"

# install
#####################################
log_header "install gpu support"

## install device plugin for intel gpu
PCI_DEVICES=$(lspci)
if grep 'VGA' <<<"$PCI_DEVICES" | grep -q 'Intel'; then
    NODE_CONFIG=$(kubectl get node -oyaml)
    if ! grep -q 'gpu.intel.com/i915' <<<"$NODE_CONFIG"; then
        kubectl apply -k 'https://github.com/intel/intel-device-plugins-for-kubernetes/deployments/nfd?ref=main'
        kubectl apply -k 'https://github.com/intel/intel-device-plugins-for-kubernetes/deployments/nfd/overlays/node-feature-rules?ref=main'
        kubectl apply -n node-feature-discovery -k 'https://github.com/intel/intel-device-plugins-for-kubernetes/deployments/gpu_plugin/overlays/monitoring_shared-dev_nfd?ref=main'
    fi
fi