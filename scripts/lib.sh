#!/usr/bin/env bash
# Fungsi bersama. Di-source oleh skrip lain, tidak dijalankan langsung.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$ROOT/config.env"

UPSTREAM="$ROOT/upstream"
WORK="$ROOT/work"
RESULTS="$ROOT/results"
VENV="$ROOT/.venv"
UPSTREAM_COMMIT="b0e55c4"

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

activate() {
	[[ -x "$VENV/bin/ansible-playbook" ]] || die "Jalankan dulu scripts/00-setup-controller.sh"
	# shellcheck disable=SC1091
	source "$VENV/bin/activate"
	export ANSIBLE_CONFIG="$WORK/ansible.cfg"
	export KUBECONFIG="$WORK/kubeconfig"
}

# Tujuan tes iperf3/netperf (paper: 172.16.21.2)
target_ip() {
	if [[ "$USE_TEST_SUBNET" == "true" ]]; then echo "172.16.21.2"; else echo "$SERVER_IP"; fi
}

# Tag yang dilewati saat menjalankan playbook tes penulis
skip_tags() {
	local tags=()
	[[ "$USE_TEST_SUBNET" == "true" ]] || tags+=(setup-config apply-config)
	# Task "Set MTU" penulis tidak ikut ter-tag mtu-9000: tanpa set-mtu dilewati, NIC
	# tertinggal di MTU 9000 walau tes jumbo tidak dijalankan.
	[[ "$TEST_JUMBO" == "true" ]] || tags+=(mtu-9000 set-mtu)
	local IFS=,
	echo "${tags[*]:-none}"
}

# ansible-playbook dijalankan dari dalam work/ (path relatif di kode penulis bergantung pada ini)
play() {
	(cd "$WORK" && ansible-playbook -i inventory "$@")
}

ssh_node() { # ssh_node <ip> <perintah>
	local ip=$1; shift
	ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
		-o ConnectTimeout=10 "$SSH_USER@$ip" "$@"
}

wait_nodes_ready() {
	log "Menunggu semua node Ready"
	for _ in $(seq 1 60); do
		if kubectl_py wait-ready 2>/dev/null; then return 0; fi
		sleep 10
	done
	die "Node tidak Ready setelah 10 menit"
}

# Klien Kubernetes kecil berbasis pustaka Python 'kubernetes' (tidak perlu kubectl di controller)
kubectl_py() {
	python "$ROOT/analysis/k8s_tool.py" "$@"
}

# Dokumentasi lingkungan (rubrik: ketepatan dokumentasi setup)
collect_env() { # collect_env <folder_hasil>
	local out="$1/env"
	mkdir -p "$out"
	{
		date -u +"%Y-%m-%dT%H:%M:%SZ"
		echo "# controller"; uname -a
		ansible --version | head -1
		python --version
		echo "# upstream commit"; git -C "$UPSTREAM" rev-parse HEAD
		echo "# config.env"; cat "$ROOT/config.env"
	} > "$out/controller.txt" 2>&1
	for pair in "doktnet01:$CLIENT_IP" "doktnet02:$SERVER_IP"; do
		local name=${pair%%:*} ip=${pair##*:}
		ssh_node "$ip" "hostname; uname -a; echo; cat /etc/os-release; echo; lscpu; echo; free -m; echo;
			sudo dmidecode -s system-product-name 2>/dev/null; echo; ip -br addr; echo; ip -d link show $TEST_NIC;
			echo; ethtool $TEST_NIC 2>/dev/null | grep -E 'Speed|Duplex'; ethtool -i $TEST_NIC 2>/dev/null;
			echo; tuned-adm active 2>/dev/null; echo; sysctl net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem;
			echo; kubelet --version 2>/dev/null; kubeadm version -o short 2>/dev/null; containerd --version 2>/dev/null;
			iperf3 --version | head -1; netperf -V 2>/dev/null" > "$out/$name.txt" 2>&1 \
			|| warn "Gagal mengumpulkan info lingkungan dari $name"
	done
}
