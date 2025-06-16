echo -e "\033[36m Start to install all component, If you want to customize the installation, you can run install-*.sh script manually.  \033[0m"
./init.sh
./install-metalLB.sh
./install-ingress-nginx.sh
./install-cert-manager.sh
./install-acme-helm.sh
./install-rancher.sh
./install-ddns.sh
