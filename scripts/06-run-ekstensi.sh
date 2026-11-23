#!/usr/bin/env bash
# USULAN PENGEMBANGAN: atribusi overhead berlapis dengan metodologi yang diperbaiki.
# Dijalankan pada cluster yang SEDANG berjalan (setelah 07-cluster.sh <varian>).
# [MODIFIKASI] Sebelum mengukur, mode jalur aktif dicatat dan diverifikasi
# (env/path-mode.txt). Metode pengukuran L0..L4 TIDAK diubah dari ekstensi 1,
# sehingga hasilnya sebanding dengan data yang diimpor dari replikasi_dakic.
#   L0-host         : iperf3/netperf langsung di OS (doktnet01 -> doktnet02), bare-metal
#   L1-hostnet-pod  : pod hostNetwork -> pod hostNetwork (isolasi kontainer saja, tanpa CNI)
#   L2-pod-ip       : pod -> pod lewat IP pod (data plane CNI)
#   L3-clusterip    : pod -> Service ClusterIP (CNI + kube-proxy/eBPF service)
#   L4-nodeport     : pod -> NodePort di IP node (jalur yang diukur penulis)
# Perbaikan terhadap metode penulis: UDP -b 0 (penulis: default 1 Mbit/s), latensi
# p50/p90/p99 dengan port data netperf tetap, server netperf di dalam pod (penulis:
# di host), pemantauan CPU kedua node, energi RAPL, keluaran JSON.
# Pemakaian: ./scripts/06-run-ekstensi.sh [nama_cni_yang_sedang_terpasang]
source "$(dirname "$0")/lib.sh"
activate

CNI=${1:-}
if [[ -z "$CNI" ]]; then
	marker=$(ls -t "$RESULTS"/raw/cni-*/.cluster 2>/dev/null | head -1 || true)
	[[ -n "$marker" ]] && CNI=$(basename "$(dirname "$marker")") && CNI=${CNI#cni-}
fi
[[ -n "$CNI" ]] || die "Sebutkan CNI yang sedang terpasang, mis.: ./scripts/06-run-ekstensi.sh calico"
OUT="$RESULTS/ekstensi/cni-$CNI"
mkdir -p "$OUT"
D=$EXT_DURATION
IMG=$TEST_IMAGE
k() { ssh_node "$CLIENT_IP" "kubectl $*"; }

log "Ekstensi pada cni-$CNI | lapisan: $EXT_LAYERS | $EXT_ITERATIONS iterasi × ${D}s"
for ip in "$CLIENT_IP" "$SERVER_IP"; do
	scp -q -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$ROOT/tools/sample.sh" "$SSH_USER@$ip:/tmp/sample.sh"
done
collect_env "$OUT"

log "Menyiapkan pod uji"
ssh_node "$CLIENT_IP" "kubectl delete ns ext --ignore-not-found --wait=true; kubectl create ns ext" >/dev/null
ssh_node "$CLIENT_IP" "kubectl apply -n ext -f -" <<EOF
apiVersion: v1
kind: Pod
metadata: {name: srv, labels: {app: ext-srv}}
spec:
  nodeSelector: {kubernetes.io/hostname: doktnet02}
  containers:
  - name: s
    image: $IMG
    command: ["sh","-c","netserver -p 12865 && iperf3 -s -p 5201"]
---
apiVersion: v1
kind: Pod
metadata: {name: cli}
spec:
  nodeSelector: {kubernetes.io/hostname: doktnet01}
  containers: [{name: c, image: $IMG, command: ["sleep","infinity"]}]
---
apiVersion: v1
kind: Pod
metadata: {name: srv-host}
spec:
  hostNetwork: true
  nodeSelector: {kubernetes.io/hostname: doktnet02}
  containers:
  - name: s
    image: $IMG
    command: ["sh","-c","netserver -p 12875 && iperf3 -s -p 5211"]
---
apiVersion: v1
kind: Pod
metadata: {name: cli-host}
spec:
  hostNetwork: true
  nodeSelector: {kubernetes.io/hostname: doktnet01}
  containers: [{name: c, image: $IMG, command: ["sleep","infinity"]}]
---
apiVersion: v1
kind: Service
metadata: {name: srv}
spec:
  type: NodePort
  selector: {app: ext-srv}
  ports:
  - {name: iperf-tcp, protocol: TCP, port: 5201, targetPort: 5201, nodePort: 30201}
  - {name: iperf-udp, protocol: UDP, port: 5201, targetPort: 5201, nodePort: 30201}
  - {name: np-ctl, protocol: TCP, port: 12865, targetPort: 12865, nodePort: 30865}
  # Port data netperf: netserver mendengarkan di nomor yang DIMINTA klien (-P ,port).
  # Lewat NodePort klien meminta 30866, jadi port/targetPort/nodePort harus sama.
  - {name: np-data-tcp, protocol: TCP, port: 30866, targetPort: 30866, nodePort: 30866}
  - {name: np-data-udp, protocol: UDP, port: 30866, targetPort: 30866, nodePort: 30866}
EOF
k "wait -n ext --for=condition=Ready pod --all --timeout=300s" >/dev/null
SRV_POD_IP=$(k "get pod -n ext srv -o jsonpath='{.status.podIP}'")
SVC_IP=$(k "get svc -n ext srv -o jsonpath='{.spec.clusterIP}'")
log "IP pod server $SRV_POD_IP | ClusterIP $SVC_IP"
{
	echo "# MTU antarmuka pod (penulis mengubah MTU NIC host SETELAH CNI terpasang)"
	k "exec -n ext cli -- cat /sys/class/net/eth0/mtu"
	echo "# MTU NIC host $TEST_NIC"; ssh_node "$CLIENT_IP" "cat /sys/class/net/$TEST_NIC/mtu"
	echo "# Rute pod klien"; k "exec -n ext cli -- ip route" 2>/dev/null || true
} > "$OUT/env/pod-network.txt" 2>&1

# [MODIFIKASI] Bukti mode jalur yang benar-benar aktif (ARSITEKTUR_JALUR.md §4).
# Hasil hanya sah bila varian sesuai rancangan; ketidaksesuaian menghentikan skrip
# (timpa dengan EXT_ALLOW_MODE_MISMATCH=true bila memang disengaja).
ssh_node "$CLIENT_IP" "bash -s" > "$OUT/env/path-mode.txt" 2>&1 <<'EOS' || true
echo "## MTU eth0 pod klien"; kubectl exec -n ext cli -- cat /sys/class/net/eth0/mtu
echo "## Antarmuka tunnel di host"; ip -d -br link show | grep -Ei 'vxlan|ipip|tunl|geneve|flannel|cilium_(vxlan|geneve)' || echo "(tidak ada)"
echo "## ip route host"; ip route
echo "## kube-proxy DaemonSet"; kubectl -n kube-system get ds kube-proxy --no-headers 2>&1 || true
echo "## Jumlah rantai KUBE-SVC iptables"; sudo iptables-save -t nat 2>/dev/null | grep -c '^:KUBE-SVC' || true
if kubectl get crd ippools.crd.projectcalico.org >/dev/null 2>&1; then
	echo "## Calico IPPool"
	kubectl get ippools.crd.projectcalico.org -o jsonpath='{range .items[*]}{.metadata.name} ipipMode={.spec.ipipMode} vxlanMode={.spec.vxlanMode}{"\n"}{end}'
fi
if kubectl -n kube-system get ds cilium >/dev/null 2>&1; then
	echo "## Cilium status"
	kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --verbose 2>/dev/null \
		|| kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium status --verbose
fi
EOS

check_path_mode() { # -> daftar masalah (kosong = sesuai)
	local f="$OUT/env/path-mode.txt" mtu
	mtu=$(sed -n '/^## MTU eth0/{n;p;}' "$f" | tr -dc '0-9')
	case $CNI in
		flannel-hostgw|calico-noencap|cilium-native|cilium-native-kpr)
			# pod-network.txt baris 4 = MTU NIC host
			[[ "$mtu" == "$(sed -n '4p' "$OUT/env/pod-network.txt" | tr -dc '0-9')" ]] \
				|| echo "MTU pod $mtu < MTU host: masih ada enkapsulasi?" ;;
	esac
	# Bukti yang dipakai: antarmuka tunnel dan rute pod node lain. Cilium 1.15 TIDAK
	# mencetak "Routing: Network: Native/Tunnel" di status, dan kueri IPPool Calico bisa
	# kosong, jadi keduanya tidak dipakai sebagai syarat (versi awal: false negative).
	local tun native
	tun=$(sed -n '/^## Antarmuka tunnel/{n;p;}' "$f")
	native=$(grep -Ec "^10\.244\.[0-9.]+/[0-9]+ via [0-9.]+ dev $TEST_NIC" "$f" || true)
	case $CNI in
		calico)         grep -q 'dev tunl0' "$f" || echo "Calico bukan IP-in-IP (tidak ada rute via tunl0)" ;;
		cilium)         [[ $tun == *cilium_vxlan* ]] || echo "Cilium tidak dalam mode Tunnel (tidak ada cilium_vxlan)" ;;
		flannel)        [[ $tun == *flannel* ]] || echo "Flannel tanpa antarmuka VXLAN" ;;
		flannel-hostgw|calico-noencap|cilium-native|cilium-native-kpr)
			[[ $tun == "(tidak ada)" ]] || echo "Masih ada antarmuka tunnel: $tun"
			[[ $native -ge 1 ]] || echo "Tidak ada rute pod node lain via $TEST_NIC (bukan routing langsung)" ;;
	esac
	case $CNI in
		cilium|cilium-native)
			grep -Eq 'KubeProxyReplacement: +False' "$f" || echo "KPR aktif, padahal varian ini memakai kube-proxy" ;;
		cilium-native-kpr)
			grep -Eq 'KubeProxyReplacement: +True' "$f" || echo "KubeProxyReplacement tidak aktif"
			grep -Eq 'Host Routing: +BPF' "$f" || echo "Host-routing bukan BPF (faktor C tidak aktif; hasil = A+B saja)"
			grep -q 'kube-proxy' <(sed -n '/^## kube-proxy/{n;p;}' "$f" | grep -v NotFound) && echo "DaemonSet kube-proxy masih ada" ;;
	esac
	return 0
}
problems=$(check_path_mode)
if [[ -n "$problems" ]]; then
	printf '# VERIFIKASI: TIDAK SESUAI\n%s\n' "$problems" >> "$OUT/env/path-mode.txt"
	warn "Mode jalur $CNI tidak sesuai rancangan:"; printf '  - %s\n' "$problems" >&2
	[[ "${EXT_ALLOW_MODE_MISMATCH:-false}" == "true" ]] || die "Dihentikan. Lihat $OUT/env/path-mode.txt"
else
	echo "# VERIFIKASI: SESUAI ($CNI)" >> "$OUT/env/path-mode.txt"
	log "Mode jalur $CNI terverifikasi"
fi

# Server L0 di OS doktnet02
# pkill -f dijalankan di sesi ssh TERSENDIRI: bila satu baris dengan "iperf3 -s -p 5301 -D",
# pola pkill cocok dengan baris perintah shell ssh itu sendiri dan shell-nya ikut terbunuh
# (versi awal gagal karena ini, server L0 tidak pernah menyala).
ssh_node "$SERVER_IP" "pkill -f '[i]perf3 -s -p 5301'" || true
ssh_node "$SERVER_IP" "iperf3 -s -p 5301 -D && sleep 1 && ss -ltn | grep -q ':5301 ' && { pgrep -x netserver >/dev/null || netserver; }" \
	|| die "Server L0 (iperf3 port 5301) di doktnet02 gagal dijalankan"

# Tujuan per lapisan: <runner> <host> <iperf_port> <netperf_ctl_port> <netperf_data_port>
target() {
	case $1 in
		L0-host)        echo "host $SERVER_IP 5301 12865 12867" ;;
		L1-hostnet-pod) echo "cli-host $SERVER_IP 5211 12875 12876" ;;
		L2-pod-ip)      echo "cli $SRV_POD_IP 5201 12865 30866" ;;
		L3-clusterip)   echo "cli $SVC_IP 5201 12865 30866" ;;
		L4-nodeport)    echo "cli $SERVER_IP 30201 30865 30866" ;;
	esac
}

run_on() { # run_on <runner> <perintah>
	if [[ $1 == host ]]; then ssh_node "$CLIENT_IP" "$2"; else k "exec -n ext $1 -- sh -c '$2'"; fi
}

measure() { # measure <file_prefix> <runner> <perintah>
	for ip in "$CLIENT_IP" "$SERVER_IP"; do
		ssh_node "$ip" "sudo nohup sh /tmp/sample.sh $D > /tmp/mon.txt 2>&1 < /dev/null & echo \$! > /tmp/mon.pid"
	done
	run_on "$2" "$3" > "$1.out" 2>&1 || warn "Gagal: $1 (lihat $1.out)"
	for pair in "client:$CLIENT_IP" "server:$SERVER_IP"; do
		ssh_node "${pair##*:}" 'while [ -d "/proc/$(cat /tmp/mon.pid)" ]; do sleep 1; done; cat /tmp/mon.txt' > "$1.${pair%%:*}.mon"
	done
}

NP_FIELDS="min_latency,mean_latency,P50_LATENCY,P90_LATENCY,P99_LATENCY,max_latency,stddev_latency,transaction_rate"
for layer in $EXT_LAYERS; do
	read -r runner host iport nctl ndata <<< "$(target "$layer")"
	mkdir -p "$OUT/$layer"
	for i in $(seq 1 "$EXT_ITERATIONS"); do
		p="$OUT/$layer/$(printf 'iter_%02d' "$i")"
		log "$CNI | $layer | iterasi $i/$EXT_ITERATIONS"
		measure "${p}_idle" "$runner" "sleep $D"
		measure "${p}_tcp" "$runner" "iperf3 -c $host -p $iport -t $D -O 1 -J"
		measure "${p}_udp" "$runner" "iperf3 -c $host -p $iport -u -b 0 -l 1472 -t $D -O 1 -J"
		measure "${p}_tcprr" "$runner" "netperf -H $host -p $nctl -l $D -t TCP_RR -- -P ,$ndata -o $NP_FIELDS"
		measure "${p}_udprr" "$runner" "netperf -H $host -p $nctl -l $D -t UDP_RR -- -P ,$ndata -o $NP_FIELDS"
	done
done

k "delete ns ext --wait=false" >/dev/null || true
ssh_node "$SERVER_IP" "pkill -f '[i]perf3 -s -p 5301'" || true
touch "$OUT/.done"
log "Ekstensi selesai: $OUT. Jalankan scripts/05-analyze.sh"
