# set pvc volume to legacy
LS=$(zfs list | grep k8s/pvc- | awk '{print $1}')
for i in ${LS}; do zfs set mountpoint=legacy $i; done
