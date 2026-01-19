#!/bin/bash

## This script should run after disable truenas Apps feature (k3s, default is disabled)

set -e
cd $(dirname $0)
source ../common.sh
source ../parameter.sh

# init
#####################################
log_header "Truenas init"
[ -d temp ] || mkdir temp
sed -i '/## PATCH/,$d' /etc/sysctl.conf
echo -e "\n## PATCH" >>/etc/sysctl.conf
echo "net.core.default_qdisc=fq" >>/etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >>/etc/sysctl.conf
echo "fs.inotify.max_user_watches=1048576" >>/etc/sysctl.conf
echo "fs.inotify.max_user_instances=8192" >>/etc/sysctl.conf
sysctl -p

## make you can use apt command and self download package
## IMPORTANT: do not run 'apt autoremove' and do not upgrade by apt commands.
log_info "    making apt usable"
zfs set readonly=off $(zfs list | grep '/usr' | awk '{print $1}')
rm /usr/local/bin/apt* /usr/local/bin/dpkg 2>/dev/null || true
export PATH="/usr/bin:$PATH"
chmod +x /usr/bin/*
wget -q -O- 'http://apt.tn.ixsystems.com/apt-direct/truenas.key' | apt-key add -
cp /etc/apt/trusted.gpg /etc/apt/trusted.gpg.d || true
apt update
swapoff -a
sed -i '/^\/swap/s/^/# /' /etc/fstab
sed -i "s/^#net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/g" /etc/sysctl.conf #forward vm ipv4 package if configure network bridge

# improve vm running performance
log_info "    improve vm running performance"
sed -i 's/##COMMENT//g' /usr/lib/python3/dist-packages/middlewared/plugins/vm/supervisor/domain_xml.py
sed -i '/##PATCH/d' /usr/lib/python3/dist-packages/middlewared/plugins/vm/supervisor/domain_xml.py
sed -i -e "s/create_element('tlbflush',/##COMMENT\0/g" /usr/lib/python3/dist-packages/middlewared/plugins/vm/supervisor/domain_xml.py
sed -i -e "s/create_element('frequencies',/##COMMENT\0/g" /usr/lib/python3/dist-packages/middlewared/plugins/vm/supervisor/domain_xml.py
sed -i -e "s/.*vm_data\['command_line_args'\]/##COMMENT\0/g" /usr/lib/python3/dist-packages/middlewared/plugins/vm/supervisor/domain_xml.py
sed -i -e "/'commandline'/a 'children': [create_element('arg', value='-cpu'),create_element('arg', value='host,hv_ipi,hv_relaxed,hv_reset,hv_runtime,hv_spinlocks=0x1fff,hv_stimer,hv_synic,hv_time,hv_vapic,hv_vendor_id=proxmox,hv_vpindex,kvm=off,+kvm_pv_eoi,+kvm_pv_unhalt')] ##PATCH" /usr/lib/python3/dist-packages/middlewared/plugins/vm/supervisor/domain_xml.py
service middlewared restart

# some patch on profile
log_info "    some patch on profile"
sed -i '/##PROFILE_PATCH/d' $HOME/.profile
PROFILE_PATCH=$(
    cat <<EOF
ln -sf /run/truenas_libvirt/libvirt-sock /var/run/libvirt/libvirt-sock 2>/dev/null ##PROFILE_PATCH
chmod +x /usr/bin/* ##PROFILE_PATCH
EOF
)
echo "$PROFILE_PATCH" >>$HOME/.profile

# install fail2ban
log_info "    install fail2ban and configure"
ipset help &>/dev/null || apt install ipset ipvsadm -y
fail2ban-client status &>/dev/null || apt install fail2ban -y
systemctl stop fail2ban.service
sed -i "s/banaction = iptables.*/banaction = iptables-ipset-proto6/" /etc/fail2ban/jail.conf
sed -i "s/banaction_allports = iptables.*/banaction_allports = iptables-ipset-proto6-allports/" /etc/fail2ban/jail.conf
SSHD_BAN_CONF=$(
    cat <<EOF
[sshd]
bantime  = 365d
findtime  = 1h
maxretry = 3
EOF
)
mkdir -p /etc/fail2ban/jail.d || true
echo "$SSHD_BAN_CONF" >/etc/fail2ban/jail.d/sshd.conf
log_info ""
systemctl restart fail2ban.service

## install k3s
#####################################
log_header "install k3s"
# init k3s config
log_info "    init k3s config."
K3S_CONF=$(
    cat <<EOF
cluster-cidr: $CLUSTER_CIDR
service-cidr: $SERVICE_CIDR
data-dir: $DATA_DIR
disable-network-policy: true
flannel-backend: host-gw
disable:
- servicelb
- traefik
- local-storage
kube-apiserver-arg:
- service-node-port-range=8000-65535
# - enable-admission-plugins=NodeRestriction
- audit-log-path=/tmp/k3s_server_audit.log
- audit-log-maxage=30
- audit-log-maxbackup=10
- audit-log-maxsize=50
# - feature-gates=''
kube-controller-manager-arg:
- node-cidr-mask-size=16
- terminated-pod-gc-threshold=5
# - feature-gates=''
kubelet-arg:
- max-pods=250
# - feature-gates=''
kube-proxy-arg:
- proxy-mode=nftables
# - feature-gates=''
EOF
)
mkdir -p /etc/rancher/k3s/
echo "$K3S_CONF" >/etc/rancher/k3s/config.yaml

# enable k3s service
log_info "    enable k3s service"
RES=$(k3s -v 2>/dev/null | grep $K3S_VERSION || true)
if [ -z "$RES" ]; then
    log_info "install k3s online"
    curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=$K3S_VERSION sh -
fi

# install helm
curl -fsSL -o ./temp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 ./temp/get_helm.sh
./temp/get_helm.sh

# auto refresh k3s certificate and cleanup
log_info "    making k3s certification auto refresh"
echo "0 2 1 jan,jul * root k3s certificate rotate --data-dir $DATA_DIR && systemctl restart k3s" >/etc/cron.d/renew_k3s_cert
echo "0 2 1 1 * root crictl rmi --prune" >/etc/cron.d/cleanup

## post installation
#####################################
# bash_completion
if [ ! -f /etc/profile.d/bash_completion.sh ]; then
    log_info "    making /etc/profile.d/bash_completion.sh"
    cat <<"EOF" >/etc/profile.d/bash_completion.sh
# shellcheck shell=sh disable=SC1091,SC2039,SC2166
# Check for interactive bash and that we haven't already been sourced.
if [ "x${BASH_VERSION-}" != x -a "x${PS1-}" != x -a "x${BASH_COMPLETION_VERSINFO-}" = x ]; then

    # Check for recent enough version of bash.
    if [ "${BASH_VERSINFO[0]}" -gt 4 ] ||
        [ "${BASH_VERSINFO[0]}" -eq 4 -a "${BASH_VERSINFO[1]}" -ge 2 ]; then
        [ -r "${XDG_CONFIG_HOME:-$HOME/.config}/bash_completion" ] &&
            . "${XDG_CONFIG_HOME:-$HOME/.config}/bash_completion"
        if shopt -q progcomp && [ -r /usr/share/bash-completion/bash_completion ]; then
            # Source completion code.
            . /usr/share/bash-completion/bash_completion
        fi
    fi

fi
EOF
fi

# bashrc
log_info "    making bashrc, you need configurate your shell to 'bash' by TrueNAS UI."
cat <<"EOF" >/root/.bashrc
# ~/.bashrc: executed by bash(1) for non-login shells.
# see /usr/share/doc/bash/examples/startup-files (in the package bash-doc)
# for examples

# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac

HISTCONTROL=ignoreboth

# append to the history file, don't overwrite it
shopt -s histappend

# for setting history length see HISTSIZE and HISTFILESIZE in bash(1)
HISTSIZE=1000
HISTFILESIZE=2000

# check the window size after each command and, if necessary,
# update the values of LINES and COLUMNS.
shopt -s checkwinsize

# If set, the pattern "**" used in a pathname expansion context will
# match all files and zero or more directories and subdirectories.
shopt -s globstar

# make less more friendly for non-text input files, see lesspipe(1)
[ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"

# set variable identifying the chroot you work in (used in the prompt below)
if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
    debian_chroot=$(cat /etc/debian_chroot)
fi

# set a fancy prompt (non-color, unless we know we "want" color)
case "$TERM" in
    xterm-color|*-256color) color_prompt=yes;;
esac

# uncomment for a colored prompt, if the terminal has the capability; turned
# off by default to not distract the user: the focus in a terminal window
# should be on the output of commands, not on the prompt
force_color_prompt=yes

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
    PS1='${debian_chroot:+($debian_chroot)}\[\e[31m\]\u\[\e[m\]\[\e[33m\]@\[\e[m\]\[\e[32m\]\h\[\e[m\]:\[\e[m\]\[\e[32m\]\[\e[1;32m\]\A\[\e[36m\] \w\[\e[m\]\$\[\e[m\] '
else
    PS1='${debian_chroot:+($debian_chroot)}\u@\h:\w\$ '
fi
unset color_prompt force_color_prompt

# If this is an xterm set the title to user@host:dir
case "$TERM" in
xterm*|rxvt*)
    PS1="\[\e]0;${debian_chroot:+($debian_chroot)}\u@\h: \w\a\]$PS1"
    ;;
*)
    ;;
esac

# enable color support of ls and also add handy aliases
if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    alias ls='ls --color=auto'
    alias dir='dir --color=auto'
    alias vdir='vdir --color=auto'

    alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias egrep='egrep --color=auto'
fi

# colored GCC warnings and errors
export GCC_COLORS='error=01;31:warning=01;35:note=01;36:caret=01;32:locus=01:quote=01'

# some more ls aliases
alias ll='ls -l'
alias la='ls -A'
alias l='ls -CF'

# Alias definitions.
# You may want to put all your additions into a separate file like
# ~/.bash_aliases, instead of adding them here directly.
# See /usr/share/doc/bash-doc/examples in the bash-doc package.

if [ -f ~/.bash_aliases ]; then
    . ~/.bash_aliases
fi

# enable programmable completion features (you don't need to enable
# this, if it's already enabled in /etc/bash.bashrc and /etc/profile
# sources /etc/bash.bashrc).
#if ! shopt -oq posix; then
#  if [ -f /usr/share/bash-completion/bash_completion ]; then
#    . /usr/share/bash-completion/bash_completion
#  elif [ -f /etc/bash_completion ]; then
#    . /etc/bash_completion
#  fi
#fi

export PATH="/usr/sbin:$PATH"
EOF

# command auto completion
log_info "    making commands auto completion"
sed -i '/##K3S_PATCH/d' $HOME/.profile
K3S_PATCH=$(
    cat <<EOF
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml ##K3S_PATCH
alias kk='kubectl get pod -A' ##K3S_PATCH
alias kp='kubectl get pod -A -o wide' ##K3S_PATCH
alias kn='kubectl get node -o wide' ##K3S_PATCH
alias ks='kubectl get svc -A -o wide' ##K3S_PATCH
alias ki='kubectl get ingress -A -o wide' ##K3S_PATCH
EOF
)
echo "$K3S_PATCH" >>$HOME/.profile

mkdir -p $HOME/.config/
[ ! -f $HOME/.config/bash_completion ] && touch $HOME/.config/bash_completion
sed -i '/##K3S_PATCH/d' $HOME/.config/bash_completion

kubectl completion bash >$HOME/.config/completion_k3s
helm completion bash >$HOME/.config/completion_helm
crictl completion bash >$HOME/.config/completion_crictl

echo "source $HOME/.config/completion_k3s ##K3S_PATCH" >>$HOME/.config/bash_completion
echo "source $HOME/.config/completion_helm ##K3S_PATCH" >>$HOME/.config/bash_completion
echo "source $HOME/.config/completion_crictl ##K3S_PATCH" >>$HOME/.config/bash_completion

## done
log_trace "init success!!!"
