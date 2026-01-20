#!/bin/bash

# write by gpt5.2

# 1) 自动发现 pools（zfs.csi.openebs.io）
pools="$(kubectl get sc -o jsonpath='{range .items[?(@.provisioner=="zfs.csi.openebs.io")]}{.parameters.poolname}{"\n"}{end}' | sort -u)"

# 2) 把 PV 信息缓存到变量（volumeHandle 作为 key）
pvtsv="$(kubectl get pv -o jsonpath='{range .items[?(@.spec.csi.driver=="zfs.csi.openebs.io")]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.spec.storageClassName}{"\t"}{.spec.claimRef.namespace}{"/"}{.spec.claimRef.name}{"\t"}{.spec.csi.volumeHandle}{"\n"}{end}')"

# 3) 打印表头
printf "%-55s %-38s %-10s %-6s %-34s %-5s %-6s\n" "DATASET" "PV" "PHASE" "SC" "CLAIM" "USED" "ORPHAN"
printf "%-55s %-38s %-10s %-6s %-34s %-5s %-6s\n" \
"-------------------------------------------------------" "--------------------------------------" "----------" "------" "----------------------------------" "-----" "------"

# 4) 以 zfs dataset 为主循环：打印明细，同时收集 ORPHAN 清单（用数组）
orphans=()
while read -r ds; do
  # 只处理末尾是 pvc-* 的 dataset（你也可以放宽/收紧这个规则）
  [[ "$ds" != */pvc-* ]] && continue
  id="${ds##*/}"

  # 在 pvtsv 中找对应 volumeHandle
  line="$(printf "%s\n" "$pvtsv" | awk -F'\t' -v k="$id" '$5==k{print; exit}')"

  if [[ -n "$line" ]]; then
    pv="$(printf "%s" "$line" | awk -F'\t' '{print $1}')"
    phase="$(printf "%s" "$line" | awk -F'\t' '{print $2}')"
    sc="$(printf "%s" "$line" | awk -F'\t' '{print $3}')"
    claim="$(printf "%s" "$line" | awk -F'\t' '{print $4}')"
    used=$([[ "$phase" == "Bound" ]] && echo YES || echo NO)
    orphan=NO
  else
    pv="-"; phase="-"; sc="-"; claim="-"
    used="-"; orphan=YES
    orphans+=("$ds")
  fi

  printf "%-55s %-38s %-10s %-6s %-34s %-5s %-6s\n" \
    "${ds:0:55}" "$pv" "$phase" "$sc" "${claim:0:34}" "$used" "$orphan"
done < <(
  printf "%s\n" "$pools" | while read -r pool; do
    [[ -z "$pool" ]] && continue
    zfs list -H -o name -r "$pool" 2>/dev/null || true
  done
)

# 5) 展示 ORPHAN 总数 + 清单，然后询问是否删除
echo
echo "ORPHAN dataset count: ${#orphans[@]}"
if (( ${#orphans[@]} > 0 )); then
  echo "ORPHAN list:"
  printf '%s\n' "${orphans[@]}"

  echo
  read -r -p "Delete ALL orphan datasets above? Type 'yes' to delete: " ans
  if [[ "$ans" == "yes" ]]; then
    echo "Deleting..."
    for ds in "${orphans[@]}"; do
      echo "zfs destroy -r $ds"
      zfs destroy -r "$ds"
    done
    echo "Done."
  else
    echo "Canceled."
  fi
fi
