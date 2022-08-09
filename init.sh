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

## By default, truenas make docker images saving to pools,
## However, docker images is not important data, so i want
## change image data to boot device.
## if you want TrueNas default way, delete this section
IX=`cat /etc/docker/daemon.json 2>/dev/null | jq '."data-root"' | grep ix-applications || true`
if [ -n "$IX" ]; then
    echo -e "\033[32m   patching docker daemon config...  \033[0m"
    systemctl stop k3s.service
    systemctl restart docker.service
    while (( $(docker images -q | wc -l) > 0 ))
    do
        docker rm -f $(docker ps -aq) 2>/dev/null || true
        docker rmi $(docker images -q) 2>/dev/null || true
        sleep 3
    done
    systemctl stop docker.service
    sed -i '/##PATCH/d' /usr/lib/python3/dist-packages/middlewared/etc_files/docker.py
    sed -i 's/##COMMENT//g' /usr/lib/python3/dist-packages/middlewared/etc_files/docker.py
    sed -i -e "s/.*'data-root'/##COMMENT\0/g" /usr/lib/python3/dist-packages/middlewared/etc_files/docker.py
    sed -i -e "s/.*'bridge'/##COMMENT\0/g" /usr/lib/python3/dist-packages/middlewared/etc_files/docker.py
    sed -i -e "/'data-root'/a 'registry-mirrors': [\'${REGISTRY_MIRRORS}\'], ##PATCH" /usr/lib/python3/dist-packages/middlewared/etc_files/docker.py
    sed -i -e "/'data-root'/a 'log-opts': {'max-size':'100m','max-file':'3'}, ##PATCH" /usr/lib/python3/dist-packages/middlewared/etc_files/docker.py
    rm -rf /usr/lib/python3/dist-packages/middlewared/etc_files/__pycache__/
    systemctl restart middlewared.service
    systemctl restart truenas.target
    midclt call service.restart docker
    systemctl start k3s.service
fi

## auto refresh k3s certificate
echo -e "\033[32m   making k3s certification auto refresh  \033[0m"
K3S_PATH=`k3s check-config -h 2>/dev/null | grep ix-applications | sed 's/.*\(\/mnt\/.*\/ix-applications\/k3s\).*/\1/g'`
echo "0 2 1 jan,jul * root k3s certificate rotate --data-dir $K3S_PATH && systemctl restart k3s">/etc/cron.d/renew_k3s_cert

## zfs csi patchs
echo -e "\033[32m   patching zfs csi workload...  \033[0m"
sed -i -e "s/image: openebs\/zfs-driver:.*/image: jutze\/zfs-driver:2.1.0-self/g" ${K3S_PATH}/server/manifests/zfs-operator.yaml
cp ${K3S_PATH}/server/manifests/zfs-operator.yaml ${K3S_PATH}/server/manifests/zfs-operator2-patch.yaml
k3s kubectl apply -f ${K3S_PATH}/server/manifests/zfs-operator2-patch.yaml
midclt call service.restart kubernetes

## command auto completion
echo -e "\033[32m   making commands auto completion  \033[0m"
sed -i '/##K8S_PATCH/d' $HOME/.profile
K8S_PATCH=`cat<<EOF
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml ##K8S_PATCH
alias k3s kubectl='k3s kubectl' ##K8S_PATCH
source <(helm completion bash) ##K8S_PATCH
source <(k3s kubectl completion bash) ##K8S_PATCH
EOF
`
echo "$K8S_PATCH" >> $HOME/.profile

## make you can use apt command and self download package
## IMPORTANT: do not run 'apt autoremove' and do not upgrade by apt commands.
echo -e "\033[32m   making apt usable  \033[0m"
chmod +x /usr/bin/apt-*
wget -q -O- 'http://apt.tn.ixsystems.com/apt-direct/truenas.key' | apt-key add -

## .bashrc shell start config file, copy for ubuntu. 
## you need configurate your shell to 'bash' by TrueNAS UI.
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