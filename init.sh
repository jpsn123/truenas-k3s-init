#!/bin/bash

## This script should run after disable truenas Apps feature (k3s, default is disabled)

set -e
cd `dirname $0`
source common.sh
source parameter.sh

# init
#####################################
echo -e "\033[42m -------------------------------  \n\033[0m"
echo -e "\033[42m Truenas init \n\033[0m"
[ -d temp ] || mkdir temp
sed -i '/## PATCH/,$d' /etc/sysctl.conf
echo -e "\n## PATCH" >> /etc/sysctl.conf
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
echo "fs.inotify.max_user_watches=1048576" >> /etc/sysctl.conf
echo "fs.inotify.max_user_instances=8192" >> /etc/sysctl.conf
sysctl -p

## make you can use apt command and self download package
## IMPORTANT: do not run 'apt autoremove' and do not upgrade by apt commands.
echo -e "\033[32m    making apt usable.  \033[0m"
zfs set readonly=off `zfs list | grep '/usr' | awk '{print $1}'`
rm /usr/local/bin/apt* /usr/local/bin/dpkg || true
export PATH="/usr/bin:$PATH"
chmod +x /usr/bin/*
wget -q -O- 'http://apt.tn.ixsystems.com/apt-direct/truenas.key' | apt-key add -
swapoff -a
sed -i '/^\/swap/s/^/# /' /etc/fstab
sed -i "s/^#net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/g" /etc/sysctl.conf #forward vm ipv4 package if configure network bridge

# disable truenas docker and k3s server
echo -e "\033[32m    disable truenas docker and k3s server  \033[0m"
sed -i 's/##COMMENT//g' /usr/lib/python3/dist-packages/middlewared/plugins/service_/services/all.py
sed -i -e "s/.*DockerService,/##COMMENT\0/g" /usr/lib/python3/dist-packages/middlewared/plugins/service_/services/all.py
sed -i -e "s/.*KubernetesService,/##COMMENT\0/g" /usr/lib/python3/dist-packages/middlewared/plugins/service_/services/all.py
sed -i -e "s/.*KubeRouterService,/##COMMENT\0/g" /usr/lib/python3/dist-packages/middlewared/plugins/service_/services/all.py

# disable truenas swap
echo -e "\033[32m    disable truenas swap  \033[0m"
sed -i '/##PATCH/d' /usr/lib/python3/dist-packages/middlewared/plugins/disk_/swap_configure.py
sed -i "/^\( *\)async def swaps_configure(self):/{p;s//\1    return [] ###PATCH/;}" /usr/lib/python3/dist-packages/middlewared/plugins/disk_/swap_configure.py

# improve vm running performance
echo -e "\033[32m    improve vm running performance  \033[0m"
sed -i 's/##COMMENT//g' /usr/lib/python3/dist-packages/middlewared/plugins/vm/supervisor/domain_xml.py
sed -i '/##PATCH/d' /usr/lib/python3/dist-packages/middlewared/plugins/vm/supervisor/domain_xml.py
sed -i -e "s/create_element('tlbflush',/##COMMENT\0/g" /usr/lib/python3/dist-packages/middlewared/plugins/vm/supervisor/domain_xml.py
sed -i -e "s/create_element('frequencies',/##COMMENT\0/g" /usr/lib/python3/dist-packages/middlewared/plugins/vm/supervisor/domain_xml.py
sed -i -e "s/.*vm_data\['command_line_args'\]/##COMMENT\0/g" /usr/lib/python3/dist-packages/middlewared/plugins/vm/supervisor/domain_xml.py
sed -i -e "/'commandline'/a 'children': [create_element('arg', value='-cpu'),create_element('arg', value='host,hv_ipi,hv_relaxed,hv_reset,hv_runtime,hv_spinlocks=0x1fff,hv_stimer,hv_synic,hv_time,hv_vapic,hv_vendor_id=proxmox,hv_vpindex,kvm=off,+kvm_pv_eoi,+kvm_pv_unhalt')] ##PATCH" /usr/lib/python3/dist-packages/middlewared/plugins/vm/supervisor/domain_xml.py
service middlewared restart

# enable docker
echo -e "\033[32m    enable and config docker.  \033[0m"
docker help &>/dev/null || curl -sSL https://get.docker.com|sh
DOCKER_CONF=`cat<<EOF
{
  "log-opts":{"max-size":"100m","max-file":"3"},
  "exec-opts":["native.cgroupdriver=systemd"],
  "max-concurrent-uploads": 1,
  "features": {"push_with_retries": true}
}
EOF
`
mkdir -p /etc/docker/
echo "$DOCKER_CONF">/etc/docker/daemon.json
systemctl enable docker
systemctl restart docker || true

# some patch on profile
echo -e "\033[32m    some patch on profile \033[0m"
sed -i '/##PROFILE_PATCH/d' $HOME/.profile
PROFILE_PATCH=`cat<<EOF
ln -sf /run/truenas_libvirt/libvirt-sock /var/run/libvirt/libvirt-sock 2>/dev/null ##PROFILE_PATCH
chmod +x /usr/bin/* ##PROFILE_PATCH
EOF
`
echo "$PROFILE_PATCH" >> $HOME/.profile

# install fail2ban
echo -e "\033[32m    install fail2ban and configure \033[0m"
fail2ban-client status &>/dev/null || apt install fail2ban -y
systemctl stop fail2ban.service
sed -i "s/banaction = iptables.*/banaction = iptables-ipset-proto6/" /etc/fail2ban/jail.conf
sed -i "s/banaction_allports = iptables.*/banaction_allports = iptables-ipset-proto6-allports/" /etc/fail2ban/jail.conf
SSHD_BAN_CONF=`cat<<EOF
[sshd]
bantime  = 365d
findtime  = 1h
maxretry = 3
EOF
`
mkdir -p /etc/fail2ban/jail.d || true
echo "$SSHD_BAN_CONF">/etc/fail2ban/jail.d/sshd.conf
systemctl restart fail2ban.service

## install k3s
#####################################
echo -e "\033[42m -------------------------------  \n\033[0m"
echo -e "\033[42m install k3s  \n\033[0m"

# init k3s config
echo -e "\033[32m    init k3s config.  \033[0m"
K3S_CONF=`cat<<EOF
cluster-cidr: $CLUSTER_CIDR
service-cidr: $SERVICE_CIDR
data-dir: $DATA_DIR
snapshotter: fuse-overlayfs
disable-network-policy: true
disable:
- servicelb
- traefik
- local-storage
kube-apiserver-arg:
- service-node-port-range=8000-65535
- enable-admission-plugins=NodeRestriction,NamespaceLifecycle,ServiceAccount
- audit-log-path=/tmp/k3s_server_audit.log
- audit-log-maxage=30
- audit-log-maxbackup=10
- audit-log-maxsize=50
- service-account-lookup=true
kube-controller-manager-arg:
- node-cidr-mask-size=16
- terminated-pod-gc-threshold=5
kubelet-arg:
- max-pods=250
EOF
`
mkdir -p /etc/rancher/k3s/
echo "$K3S_CONF" > /etc/rancher/k3s/config.yaml

# enable k3s service
echo -e "\033[32m    enable k3s service.  \033[0m"
RES=`k3s -v 2>/dev/null | grep $K3S_VERSION || true`
if [ -z "$RES" ]; then
  if [ $OFFLINE_INSTALL == true ]; then
    echo -e "\033[36m      Configure offline k3s installation, please copy files to k3s directory, inclue your self docker images. \033[0m"
    [ -e k3s/install.sh ] || curl -sfL https://get.k3s.io > k3s/install.sh || (echo -e "\033[31m error: k3s/install.sh file not found! \033[0m" ; false)
    [ -e k3s/k3s ] || (echo -e "\033[31m      error: k3s/k3s file not found! \033[0m" ; false)
    [ -e k3s/k3s-airgap-images*.tar* ] || (echo -e "\033[31m      error: k3s/k3s-airgap-images file not found, your must provide k3s docker images. \033[0m" ; false)
    mkdir -p $DATA_DIR/agent/images/
    cp -f k3s/k3s /usr/local/bin/
    chmod +x /usr/local/bin/k3s
    cp -f k3s/*images*.tar* $DATA_DIR/agent/images/
    cat k3s/install.sh | INSTALL_K3S_SKIP_DOWNLOAD=true sh -
  else
    curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=$K3S_VERSION sh -
  fi
fi

# auto refresh k3s certificate and cleanup
echo -e "\033[32m    making k3s certification auto refresh  \033[0m"
echo "0 2 1 jan,jul * root k3s certificate rotate --data-dir $DATA_DIR && systemctl restart k3s">/etc/cron.d/renew_k3s_cert
echo "0 2 1 1 * root crictl rmi --prune">/etc/cron.d/cleanup

## install zfs csi
echo -e "\033[32m    install local-zfs csi  \033[0m"
kubectl apply -f zfs-operator.yaml
zfs create ${ZFS_POOL_FOR_STORAGE} 2>/dev/null || true
ZFS_SC=`cat<<EOF
allowVolumeExpansion: true
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
  name: ${STORAGE_CLASS_NAME}
parameters:
  fstype: zfs
  poolname: ${ZFS_DATASET_FOR_STORAGE}
  shared: "yes"
provisioner: zfs.csi.openebs.io
reclaimPolicy: Delete
volumeBindingMode: Immediate
EOF
`
echo "$ZFS_SC">./temp/local-zfs-sc.yaml
k3s kubectl apply -f ./temp/local-zfs-sc.yaml

# command auto completion
echo -e "\033[32m    making commands auto completion  \033[0m"
sed -i '/##K8S_PATCH/d' $HOME/.profile
K8S_PATCH=`cat<<EOF
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml ##K8S_PATCH
alias kubectl='k3s kubectl' ##K8S_PATCH
source <(helm completion bash) ##K8S_PATCH
source <(k3s kubectl completion bash) ##K8S_PATCH
source <(crictl completion bash) ##K8S_PATCH
EOF
`
echo "$K8S_PATCH" >> $HOME/.profile

## post installation
#####################################
echo -e "\033[42m -------------------------------  \n\033[0m"
echo -e "\033[42m making bashrc  \n\033[0m"
echo -e "\033[32m    cp .bashrc shell start config file, copy from ubuntu.  \033[0m"
echo -e "\033[33m    you need configurate your shell to 'bash' by TrueNAS UI.  \033[0m"
cat<<"EOF" > /root/.bashrc
[ -z "$PS1" ] && return
HISTCONTROL=ignoredups:ignorespace
shopt -s histappend
HISTSIZE=1000
HISTFILESIZE=2000
shopt -s checkwinsize
[ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"
if [ -z "$debian_chroot" ] && [ -r /etc/debian_chroot ]; then
    debian_chroot=$(cat /etc/debian_chroot)
fi
case "$TERM" in
    xterm-color) color_prompt=yes;;
esac
if [ -n "$force_color_prompt" ]; then
    if [ -x /usr/bin/tput ] && tput setaf 1 >&/dev/null; then
	# We have color support; assume it's compliant with Ecma-48
	# (ISO/IEC-6429). (Lack of such support is extremely rare, and such
	# a case would tend to support setf rather than setaf.)
	color_prompt=yes
    else
	color_prompt=
    fi
fi
if [ "$color_prompt" = yes ]; then
    PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
else
    PS1='${debian_chroot:+($debian_chroot)}\u@\h:\w\$ '
fi
unset color_prompt force_color_prompt
case "$TERM" in
xterm*|rxvt*)
    PS1="\[\e]0;${debian_chroot:+($debian_chroot)}\u@\h: \w\a\]$PS1"
    ;;
*)
    ;;
esac
if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    alias ls='ls --color=auto'
    alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias egrep='egrep --color=auto'
fi
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
EOF

## done
#####################################
echo -e "\033[42m -------------------------------  \n\033[0m"
echo -e "\033[42m init success!!!  \033[0m"