#!/usr/bin/env bash
# Bangun (ulang) cluster dengan satu varian arsitektur jalur, tanpa tes penulis.
# Pemakaian: ./scripts/07-cluster.sh <varian>
#   varian: flannel flannel-hostgw calico calico-noencap cilium cilium-native cilium-native-kpr antrea
#   lalu:   ./scripts/06-run-ekstensi.sh <varian yang sama>
# [MODIFIKASI] -e cni=<varian> juga diteruskan ke plays/6-kubeadm.yml, karena
# cilium-native-kpr membutuhkan cluster tanpa kube-proxy.
source "$(dirname "$0")/lib.sh"
activate

cni=${1:-}
[[ -n "$cni" ]] || die "Sebutkan varian, mis.: ./scripts/07-cluster.sh calico-noencap"
OUT="$RESULTS/raw/cni-$cni"
mkdir -p "$OUT"

log "===== Membangun cluster untuk $cni ====="
play plays/reset.yml 2>&1 | tee "$OUT/reset.log"
rm -f "$WORK/kubeconfig" "$RESULTS"/raw/cni-*/.cluster
for p in 6-kubeadm 7-kubeconfig 8-join 9-labels 10-untaint; do
	play "plays/$p.yml" -e "cni=$cni" 2>&1 | tee -a "$OUT/deploy.log"
done
play plays/cni.yml -e "cni=$cni" 2>&1 | tee -a "$OUT/deploy.log" \
	|| die "Gagal memasang $cni, lihat $OUT/deploy.log"
ssh_node "$CLIENT_IP" "kubectl get nodes -o wide; echo; kubectl get pods -A -o wide; echo; helm list -A; echo; ip route" > "$OUT/cluster-state.txt" 2>&1
touch "$OUT/.cluster"
log "Cluster $cni siap. Lanjutkan: ./scripts/06-run-ekstensi.sh $cni"
