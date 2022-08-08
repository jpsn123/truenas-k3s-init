#!/bin/bash
set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../scripts/deploy/paths.sh"
source "$DEPLOY_ROOT/scripts/deploy/install-mode.sh"
cd "$SCRIPT_DIR"

INSTALL_MODE="${1:-full}"
deploy_validate_mode "$INSTALL_MODE"

printf '\033[36m Start to install all component, If you want to customize the installation, you can run install-*.sh script manually.  \033[0m\n'
bash ./init.sh
bash ./install-csi.sh "$INSTALL_MODE"
bash ./install-gpu.sh
bash ./install-metalLB.sh "$INSTALL_MODE"
bash ./install-ingress-nginx.sh "$INSTALL_MODE"
bash ./install-cert-manager.sh "$INSTALL_MODE"
bash ./install-acme.sh "$INSTALL_MODE"
bash ./install-rancher.sh "$INSTALL_MODE"
