#!/bin/bash

## This script should run after disable truenas Apps feature (k3s, default is disabled)

set -e
cd `dirname $0`
source common.sh
source parameter.sh

# init
#####################################
echo -e "\033[42m Truenas init \n\033[0m"
[ -d temp ] || mkdir temp

## make you can use apt command and self download package
## IMPORTANT: do not run 'apt autoremove' and do not upgrade by apt commands.
echo -e "\033[32m    making apt usable.  \033[0m"
chmod +x /usr/bin/apt*
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

# enable docker
echo -e "\033[32m    enable and config docker.  \033[0m"
docker help &>/dev/null || curl -sSL https://get.docker.com|sh
DOCKER_CONF=`cat<<EOF
{
  "registry-mirrors": ["http://hub-mirror.c.163.com/"],
  "log-opts":{"max-size":"100m","max-file":"3"},
  "exec-opts":["native.cgroupdriver=systemd"]
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
chmod +x /usr/bin/apt* ##PROFILE_PATCH
EOF
`
echo "$PROFILE_PATCH" >> $HOME/.profile

## install k3s
#####################################
echo -e "\033[42m install k3s  \n\033[0m"

# init k3s config
echo -e "\033[32m    init k3s config.  \033[0m"
K3S_CONF=`cat<<EOF
cluster-cidr: $CLUSTER_CIDR
service-cidr: $SERVICE_CIDR
data-dir: $DATA_DIR
snapshotter: fuse-overlayfs
disable:
- servicelb
- traefik
- local-storage
kube-apiserver-arg:
- service-node-port-range=8200-40000
- enable-admission-plugins=NodeRestriction,NamespaceLifecycle,ServiceAccount
- audit-log-path=/tmp/k3s_server_audit.log
- audit-log-maxage=30
- audit-log-maxbackup=10
- audit-log-maxsize=50
- service-account-lookup=true
- feature-gates=MixedProtocolLBService=true
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

# wait k3s wake up and patch cri config
echo -e "\033[32m    wait k3s wake up and patch cri config.  \033[0m"
systemctl restart k3s
for ((i=0;i<100;i++))
do
  if [ -e "$DATA_DIR/agent/etc/containerd/config.toml" ]; then
	sleep 5
    cp -f $DATA_DIR/agent/etc/containerd/config.toml $DATA_DIR/agent/etc/containerd/config.toml.tmpl
    sed -i '/##PATCH/,$d' $DATA_DIR/agent/etc/containerd/config.toml.tmpl
    CONTAINERD_PATCH=`cat<<EOF
##PATCH
[plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
  endpoint = ["http://hub-mirror.c.163.com/"]
#[plugins."io.containerd.grpc.v1.cri".registry.mirrors."k8s.gcr.io"]
#  endpoint = ["http://registry.aliyuncs.com/google_containers"]
EOF
`
    echo "$CONTAINERD_PATCH" >> $DATA_DIR/agent/etc/containerd/config.toml.tmpl
    systemctl restart k3s
    break
  fi
  sleep 5
done

# auto refresh k3s certificate
echo -e "\033[32m    making k3s certification auto refresh  \033[0m"
echo "0 2 1 jan,jul * root k3s certificate rotate --data-dir $DATA_DIR && systemctl restart k3s">/etc/cron.d/renew_k3s_cert

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
  name: local-zfs-sc
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
echo -e "\033[42m init success!!!  \033[0m"