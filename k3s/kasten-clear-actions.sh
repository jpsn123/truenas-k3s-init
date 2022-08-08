#!/bin/bash

action_name=(backupactions batchrestoreactions cancelactions exportactions importactions restoreactions runactions)
for ac_item in ${action_name[*]}; do
  ac_namespace=($(kubectl get $ac_item -A 2>/dev/null | tail -n +2 | awk '{print $1}'))
  ac_name=($(kubectl get $ac_item -A 2>/dev/null | tail -n +2 | awk '{print $2}'))
  for ((index = 0; index < ${#ac_name[*]}; index++)); do
    kubectl delete $ac_item -n ${ac_namespace[$index]} ${ac_name[$index]}
  done
done
