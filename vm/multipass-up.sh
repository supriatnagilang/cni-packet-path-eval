#!/usr/bin/env bash
# OPSI B (hanya punya SATU server Ubuntu): buat 2 VM (doktnet01, doktnet02) dengan
# Multipass di server tersebut, lalu tulis IP-nya ke config.local.env.
# Jalankan DI server Ubuntu (yang juga menjadi controller).
# Catatan untuk laporan: link antar-node menjadi bridge virtual (virtio), bukan NIC
# fisik seperti paper. Hasil tetap valid untuk membandingkan CNI vs OS secara relatif.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CPUS=${CPUS:-4}
MEM=${MEM:-8G}
# RAM per node bisa dibedakan; control-plane (doktnet01) butuh lebih banyak.
# Contoh host 8 GB: MEM1=3584M MEM2=2560M
MEM1=${MEM1:-$MEM}
MEM2=${MEM2:-$MEM}
DISK=${DISK:-40G}
IMAGE=${IMAGE:-22.04}
KEY=${SSH_KEY:-$HOME/.ssh/id_ed25519}

command -v multipass >/dev/null || sudo snap install multipass
[[ -f "$KEY" ]] || ssh-keygen -t ed25519 -N "" -f "$KEY"

CI=$(mktemp)
cat > "$CI" <<EOF
#cloud-config
ssh_authorized_keys:
  - $(cat "$KEY.pub")
EOF

host_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
to_mb() { case $1 in *G) echo $(( ${1%G} * 1024 ));; *M) echo "${1%M}";; *) echo "$1";; esac; }
need_mb=$(( $(to_mb "$MEM1") + $(to_mb "$MEM2") + 1536 ))
if (( need_mb > host_mb )); then
	echo "PERINGATAN: VM ($MEM1 + $MEM2) + 1,5 GB untuk host = ${need_mb} MB > RAM host ${host_mb} MB." >&2
	echo "Turunkan MEM1/MEM2 (minimal 2048M per node) atau tekan Ctrl+C dalam 10 detik." >&2
	sleep 10
fi

for vm in doktnet01 doktnet02; do
	if multipass info "$vm" >/dev/null 2>&1; then echo "$vm sudah ada"; continue; fi
	if [[ $vm == doktnet01 ]]; then mem=$MEM1; else mem=$MEM2; fi
	# Snap multipass tidak bisa membaca /tmp milik host, jadi cloud-init dikirim lewat stdin
	multipass launch "$IMAGE" --name "$vm" --cpus "$CPUS" --memory "$mem" --disk "$DISK" --cloud-init - --timeout 900 < "$CI"
done
rm -f "$CI"

ip_of() { multipass info "$1" --format json | python3 -c "import json,sys; print(json.load(sys.stdin)['info']['$1']['ipv4'][0])"; }
nic_of() { multipass exec "$1" -- sh -c "ip -o -4 route show default | awk '{print \$5}'"; }

cat > "$ROOT/config.local.env" <<EOF
# Dibuat oleh vm/multipass-up.sh. Dibaca otomatis oleh config.env.
CLIENT_IP="$(ip_of doktnet01)"
SERVER_IP="$(ip_of doktnet02)"
SSH_USER="ubuntu"
SSH_KEY="$KEY"
TEST_NIC="$(nic_of doktnet01)"
LINK_LABEL="virtio-bridge"
EOF
cat "$ROOT/config.local.env"
echo "Selesai. Lanjutkan: ./scripts/00-setup-controller.sh"
