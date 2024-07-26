#!/bin/bash

PODS=`kubectl get pod -n ldap -l app=ldap-openldap -o jsonpath='{.items[*].metadata.name}'`
for pod in ${PODS[*]}
do
  kubectl delete -n ldap pod $pod
  for ((i=0;i<100;i++))
  do
      RES=`kubectl -n ldap rollout status statefulset ldap-openldap -w=false 2>/dev/null|grep -E 'successfully|complete' || true`
      if [ -n "$RES" ]; then
          echo -e "resource ldap-openldap is ready!"
          break
      fi
      echo -e "waiting ldap-openldap be ready..."
      sleep 5
  done
done
echo -e "Restart all pods success!!!"