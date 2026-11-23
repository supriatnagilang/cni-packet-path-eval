# Perbandingan Kode: `replikasi_dakic` → `modifikasi_dakic`

Dibuat otomatis oleh `tools/gen_perubahan_kode.py` (20-11-2026). Rancangan: [ARSITEKTUR_JALUR.md](ARSITEKTUR_JALUR.md); hasil: [HASIL_ANALISIS.md](HASIL_ANALISIS.md).

**Prinsip:** menambah, bukan mengganti. Metode pengukuran L0–L4 tidak diubah, sehingga data varian baru sebanding dengan data impor dari replikasi.

## Ringkasan

| File | +/− baris | Inti perubahan |
|---|---|---|
| `overlay/plays/cni.yml` | +50 / −0 | Varian CNI baru |
| `overlay/plays/6-kubeadm.yml` | +4 / −0 | Cluster tanpa kube-proxy |
| `scripts/07-cluster.sh` | +9 / −8 | Meneruskan nama varian |
| `scripts/06-run-ekstensi.sh` | +67 / −1 | Verifikasi mode jalur |
| `scripts/05-analyze.sh` | +2 / −6 | Hanya analisis ekstensi |
| `analysis/ekstensi.py` | +136 / −3 | Analisis per varian |
| `config.env` | +8 / −1 | Daftar varian |
| `scripts/08-run-path-variants.sh` | 28 baris | **file baru** |
| `tools/gen_perubahan_kode.py` | 103 baris | **file baru** |

**Identik (diperiksa byte demi byte):** `scripts/lib.sh`, `scripts/00-setup-controller.sh`, `scripts/01-build-work.sh`, `scripts/02-prepare-nodes.sh`, `scripts/diagnose.sh`, `analysis/k8s_tool.py`, `analysis/requirements.txt`, `tools/sample.sh`; juga `vm/`, playbook lain di `overlay/plays/`, dan `upstream/` (kode penulis).

**Tidak disalin** (khusus replikasi): `scripts/03-run-os-baseline.sh`, `04-run-cni.sh`, `run-tests.sh`, `analysis/parse.py`, `plot.py`.

Baris `-` = `replikasi_dakic`, baris `+` = `modifikasi_dakic`.

---

## 1. `overlay/plays/cni.yml`: Varian CNI baru

- **`calico-noencap`** (faktor A): operator Calico dengan IPPool `encapsulation=None` + BGP; rute pod antar-node dipasang bird tanpa IP-in-IP. Syarat: kedua node satu subnet L2.
- **`cilium-native`** (faktor A): `routingMode=native` + `autoDirectNodeRoutes`, kube-proxy tetap. Satu-satunya beda dengan `cilium` (VXLAN) adalah enkapsulasi.
- **`cilium-native-kpr`** (A+B+C): routing native + `kubeProxyReplacement=true` + `bpf.masquerade=true` (mengaktifkan BPF host-routing). `k8sServiceHost` = IP control-plane karena tanpa kube-proxy.
- `ipam.mode=kubernetes` pada kedua varian Cilium baru: IPAM bawaan (10.0.0.0/8) tumpang-tindih dengan IP node 10.97.0.x.
- Task `antrea`, `calico`, `cilium`, `flannel`, `flannel-hostgw` **tidak diubah**.

```diff
--- replikasi_dakic/overlay/plays/cni.yml
+++ modifikasi_dakic/overlay/plays/cni.yml
@@ -2,6 +2,8 @@
 # [TAMBAHAN REPLIKASI] Penulis memasang CNI secara manual dengan perintah Helm di
 # cni-helm.txt. Playbook ini menjalankan perintah yang sama secara otomatis.
 # Pemakaian: ansible-playbook plays/cni.yml -e cni=<antrea|calico|cilium|flannel>
+# [MODIFIKASI] varian arsitektur jalur tambahan: calico-noencap, cilium-native,
+#   cilium-native-kpr (lihat ARSITEKTUR_JALUR.md). flannel-hostgw sudah ada.
 - name: Pasang Helm dan CNI
   hosts: k8s-control-nodes
   become: false
@@ -31,6 +33,21 @@
         helm upgrade --install calico projectcalico/tigera-operator --version {{ calico_version }} --namespace tigera-operator
       when: cni == "calico"
 
+    # ---- [MODIFIKASI A] calico-noencap: IPPool tanpa enkapsulasi; rute pod antar-node
+    #      dipasang bird (BGP full-mesh). Syarat: kedua node satu subnet L2.
+    #      Satu-satunya beda dengan "calico" adalah encapsulation (bawaan: IP-in-IP).
+    - name: Calico tanpa enkapsulasi (BGP)
+      shell: |
+        helm repo add projectcalico https://docs.tigera.io/calico/charts --force-update
+        kubectl create namespace tigera-operator --dry-run=client -o yaml | kubectl apply -f -
+        helm upgrade --install calico projectcalico/tigera-operator --version {{ calico_version }} \
+          --namespace tigera-operator \
+          --set 'installation.calicoNetwork.bgp=Enabled' \
+          --set 'installation.calicoNetwork.ipPools[0].cidr={{ pod_cidr }}' \
+          --set 'installation.calicoNetwork.ipPools[0].encapsulation=None' \
+          --set 'installation.calicoNetwork.ipPools[0].natOutgoing=Enabled'
+      when: cni == "calico-noencap"
+
     # ---- CILIUM (cni-helm.txt: cilium 1.15.6, tunnelProtocol vxlan atau geneve)
     - name: Cilium
       shell: |
@@ -38,6 +55,39 @@
         helm upgrade --install cilium cilium/cilium --version {{ cilium_version }} --namespace kube-system --set tunnelProtocol={{ cilium_tunnel }}
       when: cni == "cilium"
 
+    # ---- [MODIFIKASI A] cilium-native: routing native (tanpa VXLAN), kube-proxy TETAP
+    #      dipakai, host-routing Legacy. Beda dengan "cilium" hanya enkapsulasi.
+    #      ipam.mode=kubernetes wajib: cluster-pool bawaan (10.0.0.0/8) tumpang-tindih
+    #      dengan IP node 10.x, sehingga rute native rusak.
+    - name: Cilium native routing (kube-proxy tetap)
+      shell: |
+        helm repo add cilium https://helm.cilium.io/ --force-update
+        helm upgrade --install cilium cilium/cilium --version {{ cilium_version }} --namespace kube-system \
+          --set routingMode=native \
+          --set autoDirectNodeRoutes=true \
+          --set ipv4NativeRoutingCIDR={{ pod_cidr }} \
+          --set ipam.mode=kubernetes \
+          --set kubeProxyReplacement=false
+      when: cni == "cilium-native"
+
+    # ---- [MODIFIKASI A+B+C] cilium-native-kpr: routing native + kube-proxy replacement
+    #      eBPF (B) + BPF masquerade, yang mengaktifkan BPF host-routing (C) pada kernel
+    #      >= 5.10. Cluster dibuat TANPA kube-proxy (lihat 6-kubeadm.yml), sehingga
+    #      Cilium harus diberi alamat API server secara langsung.
+    - name: Cilium native routing + kube-proxy replacement
+      shell: |
+        helm repo add cilium https://helm.cilium.io/ --force-update
+        helm upgrade --install cilium cilium/cilium --version {{ cilium_version }} --namespace kube-system \
+          --set routingMode=native \
+          --set autoDirectNodeRoutes=true \
+          --set ipv4NativeRoutingCIDR={{ pod_cidr }} \
+          --set ipam.mode=kubernetes \
+          --set kubeProxyReplacement=true \
+          --set k8sServiceHost={{ ansible_ssh_host }} \
+          --set k8sServicePort=6443 \
+          --set bpf.masquerade=true
+      when: cni == "cilium-native-kpr"
+
     # ---- FLANNEL (cni-helm.txt memakai podCidr=10.233.64.0/18, tidak cocok dengan
     #      --pod-network-cidr=10.244.0.0/16 di plays/6-kubeadm.yml; disamakan ke pod_cidr)
     - name: Flannel
```

## 2. `overlay/plays/6-kubeadm.yml`: Cluster tanpa kube-proxy

Untuk `cni=cilium-native-kpr`, `kubeadm init` diberi `--skip-phases=addon/kube-proxy`. Untuk varian lain perintahnya sama persis (ekspresi Jinja menghasilkan string kosong).

```diff
--- replikasi_dakic/overlay/plays/6-kubeadm.yml
+++ modifikasi_dakic/overlay/plays/6-kubeadm.yml
@@ -6,6 +6,9 @@
 # "Port-10250 is in use" gagal; (2) --apiserver-advertise-address dipaksa ke IP SSH
 # node agar kubeconfig bisa dipakai controller; (3) tidak dijalankan ulang jika
 # cluster sudah ada. Pod CIDR tetap sama dengan penulis.
+# [MODIFIKASI] (4) untuk cni=cilium-native-kpr, addon kube-proxy dilewati karena
+# Service ditangani eBPF Cilium (kube-proxy replacement). Varian lain tidak berubah.
+# Dipanggil dengan: -e cni=<varian> (scripts/07-cluster.sh).
 - import_playbook: wait-runtime.yml
 
 - name: Initialize kubernetes cluster
@@ -15,5 +18,6 @@
       shell: >
         kubeadm init --pod-network-cidr={{ pod_cidr }}
         --apiserver-advertise-address={{ ansible_ssh_host }}
+        {{ '--skip-phases=addon/kube-proxy' if (cni | default('')) == 'cilium-native-kpr' else '' }}
       args:
         creates: /etc/kubernetes/admin.conf
```

## 3. `scripts/07-cluster.sh`: Meneruskan nama varian

- Inti perubahan: `play "plays/$p.yml" -e "cni=$cni"`. Sebelumnya `-e cni` hanya ke `plays/cni.yml`, sekarang juga ke `6-kubeadm.yml` (dan playbook cluster lain, tanpa efek di sana).
- Sisanya komentar, contoh pemakaian, dan pesan log. Urutan langkah tidak berubah.

```diff
--- replikasi_dakic/scripts/07-cluster.sh
+++ modifikasi_dakic/scripts/07-cluster.sh
@@ -1,22 +1,23 @@
 #!/usr/bin/env bash
-# Bangun (ulang) cluster dengan satu CNI TANPA menjalankan tes replikasi.
-# Dipakai untuk ekstensi pada CNI yang tes replikasinya sudah .done, atau untuk
-# varian yang hanya diuji di ekstensi (flannel-hostgw).
-# Pemakaian: ./scripts/07-cluster.sh <antrea|calico|cilium|flannel|flannel-hostgw>
-#   lalu:    ./scripts/06-run-ekstensi.sh <cni yang sama>
+# Bangun (ulang) cluster dengan satu varian arsitektur jalur, tanpa tes penulis.
+# Pemakaian: ./scripts/07-cluster.sh <varian>
+#   varian: flannel flannel-hostgw calico calico-noencap cilium cilium-native cilium-native-kpr antrea
+#   lalu:   ./scripts/06-run-ekstensi.sh <varian yang sama>
+# [MODIFIKASI] -e cni=<varian> juga diteruskan ke plays/6-kubeadm.yml, karena
+# cilium-native-kpr membutuhkan cluster tanpa kube-proxy.
 source "$(dirname "$0")/lib.sh"
 activate
 
 cni=${1:-}
-[[ -n "$cni" ]] || die "Sebutkan CNI, mis.: ./scripts/07-cluster.sh flannel-hostgw"
+[[ -n "$cni" ]] || die "Sebutkan varian, mis.: ./scripts/07-cluster.sh calico-noencap"
 OUT="$RESULTS/raw/cni-$cni"
 mkdir -p "$OUT"
 
-log "===== Membangun cluster untuk $cni (tanpa tes replikasi) ====="
+log "===== Membangun cluster untuk $cni ====="
 play plays/reset.yml 2>&1 | tee "$OUT/reset.log"
 rm -f "$WORK/kubeconfig" "$RESULTS"/raw/cni-*/.cluster
 for p in 6-kubeadm 7-kubeconfig 8-join 9-labels 10-untaint; do
-	play "plays/$p.yml" 2>&1 | tee -a "$OUT/deploy.log"
+	play "plays/$p.yml" -e "cni=$cni" 2>&1 | tee -a "$OUT/deploy.log"
 done
 play plays/cni.yml -e "cni=$cni" 2>&1 | tee -a "$OUT/deploy.log" \
 	|| die "Gagal memasang $cni, lihat $OUT/deploy.log"
```

## 4. `scripts/06-run-ekstensi.sh`: Verifikasi mode jalur

- Setelah pod uji siap dan **sebelum** mengukur, skrip menulis `env/path-mode.txt`: MTU pod, antarmuka tunnel, `ip route`, DaemonSet kube-proxy, jumlah rantai `KUBE-SVC`, IPPool Calico, `cilium-dbg status --verbose`.
- `check_path_mode()` mencocokkannya dengan rancangan varian. Bila tidak sesuai, skrip berhenti (timpa: `EXT_ALLOW_MODE_MISMATCH=true`). Hasil ditulis di baris terakhir `path-mode.txt`.
- **Revisi setelah run `results-1` (20 Nov):** versi pertama memeriksa baris `Routing: Network: Native/Tunnel` (tidak pernah dicetak Cilium 1.15) dan mode IPPool Calico (kueri kosong), sehingga keempat varian baru salah dinilai `TIDAK SESUAI`. Sekarang bukti yang dipakai adalah antarmuka tunnel (`cilium_vxlan`, `flannel*`, `tunl0`) dan rute pod node lain via NIC (routing langsung). Diuji pada 4 file asli (semua `SESUAI`) dan 2 kasus negatif (ditolak dengan benar).
- Satu-satunya baris lama yang dihapus adalah komentar header.
- **Bagian pengukuran (pod uji, Service, `target()`, `measure()`, loop L0..L4) tidak diubah.**

```diff
--- replikasi_dakic/scripts/06-run-ekstensi.sh
+++ modifikasi_dakic/scripts/06-run-ekstensi.sh
@@ -1,6 +1,9 @@
 #!/usr/bin/env bash
 # USULAN PENGEMBANGAN: atribusi overhead berlapis dengan metodologi yang diperbaiki.
-# Dijalankan pada cluster yang SEDANG berjalan (setelah 04-run-cni.sh <cni>).
+# Dijalankan pada cluster yang SEDANG berjalan (setelah 07-cluster.sh <varian>).
+# [MODIFIKASI] Sebelum mengukur, mode jalur aktif dicatat dan diverifikasi
+# (env/path-mode.txt). Metode pengukuran L0..L4 TIDAK diubah dari ekstensi 1,
+# sehingga hasilnya sebanding dengan data yang diimpor dari replikasi_dakic.
 #   L0-host         : iperf3/netperf langsung di OS (doktnet01 -> doktnet02), bare-metal
 #   L1-hostnet-pod  : pod hostNetwork -> pod hostNetwork (isolasi kontainer saja, tanpa CNI)
 #   L2-pod-ip       : pod -> pod lewat IP pod (data plane CNI)
@@ -96,6 +99,69 @@
 	echo "# Rute pod klien"; k "exec -n ext cli -- ip route" 2>/dev/null || true
 } > "$OUT/env/pod-network.txt" 2>&1
 
+# [MODIFIKASI] Bukti mode jalur yang benar-benar aktif (ARSITEKTUR_JALUR.md §4).
+# Hasil hanya sah bila varian sesuai rancangan; ketidaksesuaian menghentikan skrip
+# (timpa dengan EXT_ALLOW_MODE_MISMATCH=true bila memang disengaja).
+ssh_node "$CLIENT_IP" "bash -s" > "$OUT/env/path-mode.txt" 2>&1 <<'EOS' || true
+echo "## MTU eth0 pod klien"; kubectl exec -n ext cli -- cat /sys/class/net/eth0/mtu
+echo "## Antarmuka tunnel di host"; ip -d -br link show | grep -Ei 'vxlan|ipip|tunl|geneve|flannel|cilium_(vxlan|geneve)' || echo "(tidak ada)"
+echo "## ip route host"; ip route
+echo "## kube-proxy DaemonSet"; kubectl -n kube-system get ds kube-proxy --no-headers 2>&1 || true
+echo "## Jumlah rantai KUBE-SVC iptables"; sudo iptables-save -t nat 2>/dev/null | grep -c '^:KUBE-SVC' || true
+if kubectl get crd ippools.crd.projectcalico.org >/dev/null 2>&1; then
+	echo "## Calico IPPool"
+	kubectl get ippools.crd.projectcalico.org -o jsonpath='{range .items[*]}{.metadata.name} ipipMode={.spec.ipipMode} vxlanMode={.spec.vxlanMode}{"\n"}{end}'
+fi
+if kubectl -n kube-system get ds cilium >/dev/null 2>&1; then
+	echo "## Cilium status"
+	kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --verbose 2>/dev/null \
+		|| kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium status --verbose
+fi
+EOS
+
+check_path_mode() { # -> daftar masalah (kosong = sesuai)
+	local f="$OUT/env/path-mode.txt" mtu
+	mtu=$(sed -n '/^## MTU eth0/{n;p;}' "$f" | tr -dc '0-9')
+	case $CNI in
+		flannel-hostgw|calico-noencap|cilium-native|cilium-native-kpr)
+			# pod-network.txt baris 4 = MTU NIC host
+			[[ "$mtu" == "$(sed -n '4p' "$OUT/env/pod-network.txt" | tr -dc '0-9')" ]] \
+				|| echo "MTU pod $mtu < MTU host: masih ada enkapsulasi?" ;;
+	esac
+	# Bukti yang dipakai: antarmuka tunnel dan rute pod node lain. Cilium 1.15 TIDAK
+	# mencetak "Routing: Network: Native/Tunnel" di status, dan kueri IPPool Calico bisa
+	# kosong, jadi keduanya tidak dipakai sebagai syarat (versi awal: false negative).
+	local tun native
+	tun=$(sed -n '/^## Antarmuka tunnel/{n;p;}' "$f")
+	native=$(grep -Ec "^10\.244\.[0-9.]+/[0-9]+ via [0-9.]+ dev $TEST_NIC" "$f" || true)
+	case $CNI in
+		calico)         grep -q 'dev tunl0' "$f" || echo "Calico bukan IP-in-IP (tidak ada rute via tunl0)" ;;
+		cilium)         [[ $tun == *cilium_vxlan* ]] || echo "Cilium tidak dalam mode Tunnel (tidak ada cilium_vxlan)" ;;
+		flannel)        [[ $tun == *flannel* ]] || echo "Flannel tanpa antarmuka VXLAN" ;;
+		flannel-hostgw|calico-noencap|cilium-native|cilium-native-kpr)
+			[[ $tun == "(tidak ada)" ]] || echo "Masih ada antarmuka tunnel: $tun"
+			[[ $native -ge 1 ]] || echo "Tidak ada rute pod node lain via $TEST_NIC (bukan routing langsung)" ;;
+	esac
+	case $CNI in
+		cilium|cilium-native)
+			grep -Eq 'KubeProxyReplacement: +False' "$f" || echo "KPR aktif, padahal varian ini memakai kube-proxy" ;;
+		cilium-native-kpr)
+			grep -Eq 'KubeProxyReplacement: +True' "$f" || echo "KubeProxyReplacement tidak aktif"
+			grep -Eq 'Host Routing: +BPF' "$f" || echo "Host-routing bukan BPF (faktor C tidak aktif; hasil = A+B saja)"
+			grep -q 'kube-proxy' <(sed -n '/^## kube-proxy/{n;p;}' "$f" | grep -v NotFound) && echo "DaemonSet kube-proxy masih ada" ;;
+	esac
+	return 0
+}
+problems=$(check_path_mode)
+if [[ -n "$problems" ]]; then
+	printf '# VERIFIKASI: TIDAK SESUAI\n%s\n' "$problems" >> "$OUT/env/path-mode.txt"
+	warn "Mode jalur $CNI tidak sesuai rancangan:"; printf '  - %s\n' "$problems" >&2
+	[[ "${EXT_ALLOW_MODE_MISMATCH:-false}" == "true" ]] || die "Dihentikan. Lihat $OUT/env/path-mode.txt"
+else
+	echo "# VERIFIKASI: SESUAI ($CNI)" >> "$OUT/env/path-mode.txt"
+	log "Mode jalur $CNI terverifikasi"
+fi
+
 # Server L0 di OS doktnet02
 # pkill -f dijalankan di sesi ssh TERSENDIRI: bila satu baris dengan "iperf3 -s -p 5301 -D",
 # pola pkill cocok dengan baris perintah shell ssh itu sendiri dan shell-nya ikut terbunuh
```

## 5. `scripts/05-analyze.sh`: Hanya analisis ekstensi

`parse.py` dan `plot.py` (khusus log tes penulis) tidak dipakai di proyek modifikasi. Yang tersisa hanya `ekstensi.py`.

```diff
--- replikasi_dakic/scripts/05-analyze.sh
+++ modifikasi_dakic/scripts/05-analyze.sh
@@ -1,9 +1,5 @@
 #!/usr/bin/env bash
-# Log mentah -> CSV -> grafik (replikasi dan ekstensi)
+# Log ekstensi -> CSV -> grafik (per lapisan + per varian arsitektur jalur)
 source "$(dirname "$0")/lib.sh"
 activate
-python "$ROOT/analysis/parse.py"
-python "$ROOT/analysis/plot.py"
-if [[ -d "$RESULTS/ekstensi" ]]; then
-	python "$ROOT/analysis/ekstensi.py"
-fi
+python "$ROOT/analysis/ekstensi.py"
```

## 6. `analysis/ekstensi.py`: Analisis per varian

- `main()` hanya ditambah satu baris di akhir: `path_analysis(ok, agg)`. Keluaran lama **identik** dengan `replikasi_dakic` (diuji pada data impor).
- `RESULTS_DIR` (variabel lingkungan) memilih folder hasil lain, mis. `RESULTS_DIR=results-1`. Bawaan: `results/`.
- `VARIANT_INFO`: faktor A/B/C setiap varian. `PAIRS`: pasangan yang mengisolasi faktor.
- `path_analysis()` menghasilkan:
  - `ekstensi_path_summary.csv`: per varian × lapisan (L0, L2–L4) + status verifikasi.
  - `ekstensi_path_stats.csv`: per pasangan × metrik × lapisan, berisi selisih, Cliff's delta, p Mann–Whitney, dan p Holm. Keluarga Holm = (pasangan, metrik) atas ≤3 lapisan (dengan n=5, p minimum 0,0079).
  - `ext_path_throughput.png`, `ext_path_latency.png`.
- `verification()` membaca baris `# VERIFIKASI` terakhir dari `path-mode.txt`, atau menandai data impor.

```diff
--- replikasi_dakic/analysis/ekstensi.py
+++ modifikasi_dakic/analysis/ekstensi.py
@@ -24,9 +24,11 @@
 from scipy import stats
 
 ROOT = Path(__file__).resolve().parent.parent
-EXT = ROOT / "results" / "ekstensi"
-SUM = ROOT / "results" / "summary"
-FIG = ROOT / "results" / "figures"
+import os
+RES = Path(os.environ.get("RESULTS_DIR", ROOT / "results"))
+EXT = RES / "ekstensi"
+SUM = RES / "summary"
+FIG = RES / "figures"
 LAYERS = ["L0-host", "L1-hostnet-pod", "L2-pod-ip", "L3-clusterip", "L4-nodeport"]
 NAME = re.compile(r"iter_(\d+)_(idle|tcp|udp|tcprr|udprr)\.out$")
 
@@ -195,7 +197,138 @@
     axes[0].legend(fontsize=7)
     fig.tight_layout(); fig.savefig(FIG / "ext_efficiency.png", dpi=200); plt.close(fig)
     print(f"Ekstensi: {len(df)} run -> {SUM}/ekstensi_*.csv, {FIG}/ext_*.png")
+    path_analysis(ok, agg)
 
 
+# ----------------------------------------------------------------------------
+# [MODIFIKASI] Analisis varian arsitektur jalur (ARSITEKTUR_JALUR.md §2 dan §6)
+# ----------------------------------------------------------------------------
+# varian -> (A: enkapsulasi, B: implementasi Service, C: jalur host)
+VARIANT_INFO = {
+    "cni-flannel":           ("VXLAN", "iptables", "netfilter"),
+    "cni-flannel-hostgw":    ("routing", "iptables", "netfilter"),
+    "cni-calico":            ("IP-in-IP", "iptables", "netfilter"),
+    "cni-calico-noencap":    ("routing", "iptables", "netfilter"),
+    "cni-cilium":            ("VXLAN", "iptables", "netfilter"),
+    "cni-cilium-native":     ("routing", "iptables", "netfilter"),
+    "cni-cilium-native-kpr": ("routing", "eBPF", "BPF"),
+    "cni-antrea":            ("Geneve", "iptables", "OVS"),
+}
+# (varian a, varian b, faktor yang berbeda)
+PAIRS = [
+    ("cni-flannel", "cni-flannel-hostgw", "A (Flannel)"),
+    ("cni-calico", "cni-calico-noencap", "A (Calico)"),
+    ("cni-cilium", "cni-cilium-native", "A (Cilium)"),
+    ("cni-cilium-native", "cni-cilium-native-kpr", "B+C (Cilium)"),
+    ("cni-cilium", "cni-cilium-native-kpr", "A+B+C (Cilium)"),
+    ("cni-flannel-hostgw", "cni-calico-noencap", "implementasi (routing+iptables)"),
+    ("cni-flannel", "cni-cilium", "implementasi (VXLAN+iptables)"),
+    ("cni-calico-noencap", "cni-cilium-native-kpr", "B+C (+implementasi)"),
+]
+PATH_LAYERS = ["L2-pod-ip", "L3-clusterip", "L4-nodeport"]
+# (nama metrik, tes, kolom)
+PATH_METRICS = [("tcp_gbps", "tcp", "gbps"), ("udp_gbps", "udp", "gbps"),
+                ("tcprr_p50_us", "tcprr", "lat_p50"), ("tcprr_p99_us", "tcprr", "lat_p99"),
+                ("tcp_cpu_pct", "tcp", "cpu_mean"), ("tcp_gbps_per_cpu", "tcp", "eta")]
+
+
+def cliffs_delta(a, b):
+    a, b = list(a), list(b)
+    if not a or not b:
+        return float("nan")
+    s = sum((x > y) - (x < y) for x in a for y in b)
+    return s / (len(a) * len(b))
+
+
+def verification(cni):
+    """Baris terakhir '# VERIFIKASI' di env/path-mode.txt, atau status impor."""
+    d = EXT / cni
+    f = d / "env" / "path-mode.txt"
+    if f.exists():
+        for line in reversed(f.read_text(errors="replace").splitlines()):
+            if line.startswith("# VERIFIKASI"):
+                return line[2:].strip()
+    return "diimpor, mode tidak diverifikasi" if (d / "IMPORTED.txt").exists() else "tidak ada path-mode.txt"
+
+
+def path_analysis(ok, agg):
+    present = [v for v in VARIANT_INFO if v in set(ok.cni)]
+    if len(present) < 2:
+        return
+    ok = ok.copy()
+    ok["eta"] = ok["gbps"] / ok["cpu_mean"]
+
+    # Ringkasan per varian x lapisan
+    rows = []
+    for v in present:
+        a, b, c = VARIANT_INFO[v]
+        for layer in ["L0-host"] + PATH_LAYERS:
+            g = agg[(agg.cni == v) & (agg.layer == layer)].set_index("test")
+            get = lambda t, col: g.loc[t, col] if t in g.index else float("nan")
+            rows.append({"variant": v.replace("cni-", ""), "A_encap": a, "B_service": b, "C_host_path": c,
+                         "layer": layer, "tcp_gbps": get("tcp", "gbps"), "tcp_overhead_pct": get("tcp", "overhead_pct"),
+                         "udp_gbps": get("udp", "gbps"), "udp_loss_pct": get("udp", "loss"),
+                         "tcprr_p50_us": get("tcprr", "p50"), "tcprr_p99_us": get("tcprr", "p99"),
+                         "tcp_cpu_pct": get("tcp", "cpu"), "tcp_gbps_per_cpu": get("tcp", "gbps_per_cpu"),
+                         "verifikasi": verification(v)})
+    summ = pd.DataFrame(rows)
+    summ.to_csv(SUM / "ekstensi_path_summary.csv", index=False)
+
+    # Uji per pasangan. Holm per (pasangan, metrik) atas <=3 lapisan: dengan n=5 per
+    # kelompok, p Mann-Whitney terkecil = 0,0079, jadi keluarga uji harus kecil agar
+    # perbedaan yang konsisten (5 dari 5) tetap bisa signifikan.
+    st = []
+    for va, vb, factor in PAIRS:
+        if va not in present or vb not in present:
+            continue
+        for name, test, col in PATH_METRICS:
+            block = []
+            for layer in PATH_LAYERS:
+                xa = ok[(ok.cni == va) & (ok.layer == layer) & (ok.test == test)][col].dropna()
+                xb = ok[(ok.cni == vb) & (ok.layer == layer) & (ok.test == test)][col].dropna()
+                if len(xa) < 2 or len(xb) < 2:
+                    continue
+                p = stats.mannwhitneyu(xa, xb).pvalue
+                ma, mb = xa.mean(), xb.mean()
+                block.append({"pair": f"{va[4:]} vs {vb[4:]}", "factor": factor, "metric": name, "layer": layer,
+                              "mean_a": ma, "mean_b": mb, "delta": mb - ma,
+                              "delta_pct": 100 * (mb / ma - 1) if ma else float("nan"),
+                              "cliffs_delta": cliffs_delta(xb, xa), "n_a": len(xa), "n_b": len(xb), "mwu_p": p})
+            for r, pa in zip(block, holm([r["mwu_p"] for r in block])):
+                r["holm_p"] = pa
+                r["signif_0.05"] = pa < 0.05
+            st.extend(block)
+    pd.DataFrame(st).to_csv(SUM / "ekstensi_path_stats.csv", index=False)
+
+    # Grafik: throughput TCP per varian, batang per lapisan
+    labels = [v.replace("cni-", "") for v in present]
+    lay = ["L0-host"] + PATH_LAYERS
+    fig, ax = plt.subplots(figsize=(7.2, 3.2))
+    w = 0.8 / len(lay)
+    for i, layer in enumerate(lay):
+        d = summ[summ.layer == layer].set_index("variant").reindex(labels)
+        x = [j + (i - (len(lay) - 1) / 2) * w for j in range(len(labels))]
+        ax.bar(x, d.tcp_gbps, w, label=layer.split("-")[0] + " " + layer.split("-", 1)[1], color=f"C{i}")
+    ax.set_xticks(range(len(labels)))
+    ax.set_xticklabels([f"{l}\n{'/'.join(VARIANT_INFO['cni-' + l][:2])}" for l in labels], fontsize=6.5)
+    ax.set_ylabel("TCP Gbit/s"); ax.grid(axis="y", alpha=0.3)
+    ax.legend(fontsize=7, ncol=4, loc="lower center", bbox_to_anchor=(0.5, 1.0), frameon=False)
+    fig.tight_layout(); fig.savefig(FIG / "ext_path_throughput.png", dpi=200); plt.close(fig)
+
+    # Grafik: latensi TCP_RR p50 (pekat) dan p99 (pudar) per varian, lapisan L2..L4
+    fig, ax = plt.subplots(figsize=(7.2, 3.2))
+    w = 0.8 / len(PATH_LAYERS)
+    for i, layer in enumerate(PATH_LAYERS):
+        d = summ[summ.layer == layer].set_index("variant").reindex(labels)
+        x = [j + (i - (len(PATH_LAYERS) - 1) / 2) * w for j in range(len(labels))]
+        ax.bar(x, d.tcprr_p99_us, w, alpha=0.35, color=f"C{i + 1}")
+        ax.bar(x, d.tcprr_p50_us, w, color=f"C{i + 1}", label=layer)
+    ax.set_xticks(range(len(labels))); ax.set_xticklabels(labels, fontsize=7)
+    ax.set_ylabel("TCP_RR (µs)\npekat = p50, pudar = p99"); ax.grid(axis="y", alpha=0.3)
+    ax.legend(fontsize=7, ncol=3, loc="lower center", bbox_to_anchor=(0.5, 1.0), frameon=False)
+    fig.tight_layout(); fig.savefig(FIG / "ext_path_latency.png", dpi=200); plt.close(fig)
+    print(f"Varian jalur: {len(present)} varian -> {SUM}/ekstensi_path_*.csv, {FIG}/ext_path_*.png")
+
+
 if __name__ == "__main__":
     main()
```

## 7. `config.env`: Daftar varian

Judul file diganti, dan `EXT_PATH_VARIANTS` ditambahkan (bawaan: `calico-noencap cilium cilium-native cilium-native-kpr`). Semua nilai lain sama.

```diff
--- replikasi_dakic/config.env
+++ modifikasi_dakic/config.env
@@ -1,5 +1,6 @@
 # =============================================================================
-# Replikasi Dakić et al. (2024), Electronics 13(19):3972
+# MODIFIKASI: variasi arsitektur jalur paket (lihat ARSITEKTUR_JALUR.md)
+# Berbasis replikasi Dakić et al. (2024), Electronics 13(19):3972
 # Kode penulis: upstream/ (https://github.com/vEddYcro/cni-performance-testing, commit b0e55c4)
 # Semua skrip di scripts/ membaca file ini. Ubah nilai di sini, bukan di skrip.
 # Variabel bisa ditimpa sementara dari baris perintah, misalnya:
@@ -65,3 +66,9 @@
 EXT_LAYERS="${EXT_LAYERS:-L0-host L1-hostnet-pod L2-pod-ip L3-clusterip L4-nodeport}"
 EXT_ITERATIONS="${EXT_ITERATIONS:-5}"
 EXT_DURATION="${EXT_DURATION:-30}"
+
+# ----- MODIFIKASI: varian arsitektur jalur (scripts/08-run-path-variants.sh) ----
+# Profil OS dikunci di default (tidak ada playbook optimasi penulis yang dijalankan).
+# flannel, flannel-hostgw, calico sudah diimpor dari replikasi_dakic (results/ekstensi/*/IMPORTED.txt).
+# Varian lain yang tersedia: flannel flannel-hostgw calico antrea
+EXT_PATH_VARIANTS="${EXT_PATH_VARIANTS:-calico-noencap cilium cilium-native cilium-native-kpr}"
```

## 8. `scripts/08-run-path-variants.sh`: File baru

Untuk setiap varian (`EXT_PATH_VARIANTS` atau argumen): `07-cluster.sh` lalu `06-run-ekstensi.sh`. Varian yang sudah `.done` dilewati, dan kegagalan satu varian tidak menghentikan varian berikutnya. Di akhir dijalankan `05-analyze.sh`.

```bash
#!/usr/bin/env bash
# [MODIFIKASI] Menjalankan semua varian arsitektur jalur secara berurutan:
#   per varian: 07-cluster.sh (reset -> kubeadm -> CNI) -> 06-run-ekstensi.sh (L0..L4)
# Varian yang sudah punya results/ekstensi/cni-<v>/.done dilewati (aman diulang
# setelah gagal di tengah jalan). Hapus .done untuk mengukur ulang.
# Pemakaian: ./scripts/08-run-path-variants.sh [varian ...]   (bawaan: EXT_PATH_VARIANTS)
source "$(dirname "$0")/lib.sh"

variants=("$@")
[[ ${#variants[@]} -gt 0 ]] || read -r -a variants <<< "$EXT_PATH_VARIANTS"
log "Varian: ${variants[*]} | $EXT_ITERATIONS iterasi × ${EXT_DURATION}s per tes"

failed=()
for v in "${variants[@]}"; do
	if [[ -f "$RESULTS/ekstensi/cni-$v/.done" ]]; then
		log "Lewati $v (sudah .done)"; continue
	fi
	# Subshell: die() di skrip anak tidak menghentikan varian berikutnya
	if ( "$ROOT/scripts/07-cluster.sh" "$v" && "$ROOT/scripts/06-run-ekstensi.sh" "$v" ); then
		log "Selesai: $v"
	else
		warn "Varian $v gagal; lanjut ke varian berikutnya"; failed+=("$v")
	fi
done

"$ROOT/scripts/05-analyze.sh"
[[ ${#failed[@]} -eq 0 ]] || die "Gagal: ${failed[*]} (lihat results/raw/cni-<v>/deploy.log dan results/ekstensi/cni-<v>/env/path-mode.txt)"
log "Semua varian selesai. Ringkasan: results/summary/ekstensi_path_*.csv"
```

## 9. `tools/gen_perubahan_kode.py`: File baru

Generator dokumen ini.

```python
#!/usr/bin/env python3
"""Membuat PERUBAHAN_KODE.md: diff setiap file modifikasi_dakic terhadap replikasi_dakic.

Pemakaian (dari folder Tugas_CIS/):  python3 modifikasi_dakic/tools/gen_perubahan_kode.py
Penjelasan per file ada di NOTES di bawah; diff dihasilkan langsung dengan `diff -u`.
"""
import datetime
import subprocess
from pathlib import Path

MOD = Path(__file__).resolve().parent.parent
REP = MOD.parent / "replikasi_dakic"

NOTES = {
    "overlay/plays/cni.yml": ("Varian CNI baru", """\
- **`calico-noencap`** (faktor A): operator Calico dengan IPPool `encapsulation=None` + BGP; rute pod antar-node dipasang bird tanpa IP-in-IP. Syarat: kedua node satu subnet L2.
- **`cilium-native`** (faktor A): `routingMode=native` + `autoDirectNodeRoutes`, kube-proxy tetap. Satu-satunya beda dengan `cilium` (VXLAN) adalah enkapsulasi.
- **`cilium-native-kpr`** (A+B+C): routing native + `kubeProxyReplacement=true` + `bpf.masquerade=true` (mengaktifkan BPF host-routing). `k8sServiceHost` = IP control-plane karena tanpa kube-proxy.
- `ipam.mode=kubernetes` pada kedua varian Cilium baru: IPAM bawaan (10.0.0.0/8) tumpang-tindih dengan IP node 10.97.0.x.
- Task `antrea`, `calico`, `cilium`, `flannel`, `flannel-hostgw` **tidak diubah**."""),
    "overlay/plays/6-kubeadm.yml": ("Cluster tanpa kube-proxy", """\
Untuk `cni=cilium-native-kpr`, `kubeadm init` diberi `--skip-phases=addon/kube-proxy`. Untuk varian lain perintahnya sama persis (ekspresi Jinja menghasilkan string kosong)."""),
    "scripts/07-cluster.sh": ("Meneruskan nama varian", """\
- Inti perubahan: `play "plays/$p.yml" -e "cni=$cni"`. Sebelumnya `-e cni` hanya ke `plays/cni.yml`, sekarang juga ke `6-kubeadm.yml` (dan playbook cluster lain, tanpa efek di sana).
- Sisanya komentar, contoh pemakaian, dan pesan log. Urutan langkah tidak berubah."""),
    "scripts/06-run-ekstensi.sh": ("Verifikasi mode jalur", """\
- Setelah pod uji siap dan **sebelum** mengukur, skrip menulis `env/path-mode.txt`: MTU pod, antarmuka tunnel, `ip route`, DaemonSet kube-proxy, jumlah rantai `KUBE-SVC`, IPPool Calico, `cilium-dbg status --verbose`.
- `check_path_mode()` mencocokkannya dengan rancangan varian. Bila tidak sesuai, skrip berhenti (timpa: `EXT_ALLOW_MODE_MISMATCH=true`). Hasil ditulis di baris terakhir `path-mode.txt`.
- **Revisi setelah run `results-1` (20 Nov):** versi pertama memeriksa baris `Routing: Network: Native/Tunnel` (tidak pernah dicetak Cilium 1.15) dan mode IPPool Calico (kueri kosong), sehingga keempat varian baru salah dinilai `TIDAK SESUAI`. Sekarang bukti yang dipakai adalah antarmuka tunnel (`cilium_vxlan`, `flannel*`, `tunl0`) dan rute pod node lain via NIC (routing langsung). Diuji pada 4 file asli (semua `SESUAI`) dan 2 kasus negatif (ditolak dengan benar).
- Satu-satunya baris lama yang dihapus adalah komentar header.
- **Bagian pengukuran (pod uji, Service, `target()`, `measure()`, loop L0..L4) tidak diubah.**"""),
    "scripts/05-analyze.sh": ("Hanya analisis ekstensi", """\
`parse.py` dan `plot.py` (khusus log tes penulis) tidak dipakai di proyek modifikasi. Yang tersisa hanya `ekstensi.py`."""),
    "analysis/ekstensi.py": ("Analisis per varian", """\
- `main()` hanya ditambah satu baris di akhir: `path_analysis(ok, agg)`. Keluaran lama **identik** dengan `replikasi_dakic` (diuji pada data impor).
- `RESULTS_DIR` (variabel lingkungan) memilih folder hasil lain, mis. `RESULTS_DIR=results-1`. Bawaan: `results/`.
- `VARIANT_INFO`: faktor A/B/C setiap varian. `PAIRS`: pasangan yang mengisolasi faktor.
- `path_analysis()` menghasilkan:
  - `ekstensi_path_summary.csv`: per varian × lapisan (L0, L2–L4) + status verifikasi.
  - `ekstensi_path_stats.csv`: per pasangan × metrik × lapisan, berisi selisih, Cliff's delta, p Mann–Whitney, dan p Holm. Keluarga Holm = (pasangan, metrik) atas ≤3 lapisan (dengan n=5, p minimum 0,0079).
  - `ext_path_throughput.png`, `ext_path_latency.png`.
- `verification()` membaca baris `# VERIFIKASI` terakhir dari `path-mode.txt`, atau menandai data impor."""),
    "config.env": ("Daftar varian", """\
Judul file diganti, dan `EXT_PATH_VARIANTS` ditambahkan (bawaan: `calico-noencap cilium cilium-native cilium-native-kpr`). Semua nilai lain sama."""),
}
NEW = {"scripts/08-run-path-variants.sh": ("File baru", """\
Untuk setiap varian (`EXT_PATH_VARIANTS` atau argumen): `07-cluster.sh` lalu `06-run-ekstensi.sh`. Varian yang sudah `.done` dilewati, dan kegagalan satu varian tidak menghentikan varian berikutnya. Di akhir dijalankan `05-analyze.sh`."""),
       "tools/gen_perubahan_kode.py": ("File baru", "Generator dokumen ini.")}
IDENTICAL = ["scripts/lib.sh", "scripts/00-setup-controller.sh", "scripts/01-build-work.sh",
             "scripts/02-prepare-nodes.sh", "scripts/diagnose.sh", "analysis/k8s_tool.py",
             "analysis/requirements.txt", "tools/sample.sh"]


def udiff(f):
    r = subprocess.run(["diff", "-u", "--label", f"replikasi_dakic/{f}", "--label", f"modifikasi_dakic/{f}",
                        str(REP / f), str(MOD / f)], capture_output=True, text=True)
    plus = sum(1 for l in r.stdout.splitlines() if l.startswith("+") and not l.startswith("+++"))
    minus = sum(1 for l in r.stdout.splitlines() if l.startswith("-") and not l.startswith("---"))
    return r.stdout, plus, minus


def main():
    diffs = {f: udiff(f) for f in NOTES}
    same = [f for f in IDENTICAL if (REP / f).read_bytes() == (MOD / f).read_bytes()]
    out = [f"""# Perbandingan Kode: `replikasi_dakic` → `modifikasi_dakic`

Dibuat otomatis oleh `tools/gen_perubahan_kode.py` ({datetime.date.today():%d-%m-%Y}). Rancangan: [ARSITEKTUR_JALUR.md](ARSITEKTUR_JALUR.md); hasil: [HASIL_ANALISIS.md](HASIL_ANALISIS.md).

**Prinsip:** menambah, bukan mengganti. Metode pengukuran L0–L4 tidak diubah, sehingga data varian baru sebanding dengan data impor dari replikasi.

## Ringkasan

| File | +/− baris | Inti perubahan |
|---|---|---|
"""]
    for f, (title, _) in NOTES.items():
        _, p, m = diffs[f]
        out.append(f"| `{f}` | +{p} / −{m} | {title} |\n")
    for f, (title, _) in NEW.items():
        out.append(f"| `{f}` | {len((MOD / f).read_text().splitlines())} baris | **{title.lower()}** |\n")
    out.append(f"""
**Identik (diperiksa byte demi byte):** {", ".join(f"`{f}`" for f in same)}; juga `vm/`, playbook lain di `overlay/plays/`, dan `upstream/` (kode penulis).

**Tidak disalin** (khusus replikasi): `scripts/03-run-os-baseline.sh`, `04-run-cni.sh`, `run-tests.sh`, `analysis/parse.py`, `plot.py`.

Baris `-` = `replikasi_dakic`, baris `+` = `modifikasi_dakic`.

---
""")
    n = 0
    for f, (title, note) in NOTES.items():
        n += 1
        out.append(f"\n## {n}. `{f}`: {title}\n\n{note}\n\n```diff\n{diffs[f][0].rstrip()}\n```\n")
    for f, (title, note) in NEW.items():
        n += 1
        lang = "bash" if f.endswith(".sh") else "python"
        out.append(f"\n## {n}. `{f}`: {title}\n\n{note}\n\n```{lang}\n{(MOD / f).read_text().rstrip()}\n```\n")
    (MOD / "PERUBAHAN_KODE.md").write_text("".join(out))
    print(f"Ditulis: {MOD / 'PERUBAHAN_KODE.md'}")


if __name__ == "__main__":
    main()
```
