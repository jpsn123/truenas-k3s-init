#!/bin/bash

## This script should run after the Apps feature (k3s) is initialized

set -e
cd `dirname $0`
source common.sh
source parameter.sh

# init
#####################################
echo -e "\033[42;30m init \n\033[0m"
[ -d temp ] || mkdir temp

## make you can use apt command and self download package
## IMPORTANT: do not run 'apt autoremove' and do not upgrade by apt commands.
echo -e "\033[32m   making apt usable  \033[0m"
chmod +x /usr/bin/apt*
wget -q -O- 'http://apt.tn.ixsystems.com/apt-direct/truenas.key' | apt-key add -

## disable truenas docker and k3s server
#####################################
sed -i 's/##COMMENT//g' /usr/lib/python3/dist-packages/middlewared/plugins/service_/services/all.py
sed -i -e "s/.*DockerService,/##COMMENT\0/g" /usr/lib/python3/dist-packages/middlewared/plugins/service_/services/all.py
sed -i -e "s/.*KubernetesService,/##COMMENT\0/g" /usr/lib/python3/dist-packages/middlewared/plugins/service_/services/all.py
sed -i -e "s/.*KubeRouterService,/##COMMENT\0/g" /usr/lib/python3/dist-packages/middlewared/plugins/service_/services/all.py

## install docker
#####################################
#curl -sSL https://get.docker.com|sh
#systemctl enable docker

## install k3s
#####################################
K3S_CONF=`cat<<EOF
cluster-cidr: $CLUSTER_CIDR
service-cidr: $SERVICE_CIDR
data-dir: $DATA_DIR
snapshotter: native
disable:
- servicelb
- traefik
- local-storage
kube-apiserver-arg:
- service-node-port-range=9000-65535
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

## install
k3s -v | grep v1.24 || curl -sfL https://get.k3s.io | sh -

for ((i=0;i<100;i++))
do
  if [ -e "$DATA_DIR/agent/etc/containerd/config.toml" ]; then
    sed -i '/##PATCH/,$d' $DATA_DIR/agent/etc/containerd/config.toml
    CONTAINERD_PATCH=`cat<<EOF
##PATCH
[plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
  endpoint = ["http://hub-mirror.c.163.com/"]
[plugins."io.containerd.grpc.v1.cri".registry.mirrors."k8s.gcr.io"]
  endpoint = ["http://registry.aliyuncs.com/google_containers"]
EOF
`
    echo "$CONTAINERD_PATCH" >> $DATA_DIR/agent/etc/containerd/config.toml
    systemctl restart k3s
    break
  fi
  sleep 5
done

## auto refresh k3s certificate
echo -e "\033[32m   making k3s certification auto refresh  \033[0m"
echo "0 2 1 jan,jul * root k3s certificate rotate --data-dir $DATA_DIR && systemctl restart k3s">/etc/cron.d/renew_k3s_cert

## install zfs csi
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

## command auto completion
echo -e "\033[32m   making commands auto completion  \033[0m"
sed -i '/##K8S_PATCH/d' $HOME/.profile
K8S_PATCH=`cat<<EOF
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml ##K8S_PATCH
alias kubectl='k3s kubectl' ##K8S_PATCH
source <(helm completion bash) ##K8S_PATCH
source <(k3s kubectl completion bash) ##K8S_PATCH
ln -sf /run/truenas_libvirt/libvirt-sock /var/run/libvirt/libvirt-sock 2>/dev/null ##K8s_PATCH
chmod +x /usr/bin/apt* ##K8s_PATCH
EOF
`
echo "$K8S_PATCH" >> $HOME/.profile

## .bashrc shell start config file, copy for ubuntu. 
## you need configurate your shell to 'bash' by TrueNAS UI.
#####################################
echo -e "\033[32m   making bashrc  \033[0m"
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