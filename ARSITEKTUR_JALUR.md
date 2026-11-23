# Ekstensi 2: Variasi Arsitektur Jalur Paket

> **Status (20 Nov 2026): diimplementasikan di folder ini (`modifikasi_dakic/`), belum
> dijalankan di testbed.** Dokumen ini menjelaskan apa yang diubah, alasannya, cara
> menjalankan, dan cara membaca hasilnya. Ekstensi 1 (atribusi berlapis L0–L4,
> `scripts/06-run-ekstensi.sh`) dipakai apa adanya sebagai alat ukur. Semua path di
> dokumen ini relatif terhadap `modifikasi_dakic/`. Folder `replikasi_dakic/` tidak diubah.

## 1. Motivasi

Dakić et al. (2024) mengoptimasi kinerja CNI lewat **setelan sistem operasi** (sysctl,
ethtool, profil `tuned`). Hasil replikasi dan ekstensi 1 menunjukkan bahwa setelan OS
hampir tidak berpengaruh, sedangkan **arsitektur jalur paket** sangat berpengaruh:

| Perubahan | Efek terukur | Sumber |
|---|---|---|
| Profil `kernel_optimizations` pada Calico | +3,2 s.d. +5,5% throughput TCP | `results/summary/summary_bandwidth.csv` |
| Profil `network-throughput` vs default | bercampur, −17 s.d. +20% (di bawah noise n=2) | `results/summary/efficiency.csv` |
| Flannel VXLAN → Flannel `host-gw` (L2, TCP) | overhead **80,7% → 3,5%** | `results/summary/ekstensi_summary.csv` |
| Flannel VXLAN → `host-gw` (L2, latensi p50) | 83,8 → 76,4 µs | idem |

Kesimpulannya, pertanyaan yang lebih bermanfaat bukan "setelan OS mana yang terbaik",
tetapi **"keputusan arsitektur jalur mana yang menentukan biaya jaringan kontainer, dan
seberapa besar masing-masing?"**

## 2. Rancangan: tiga keputusan arsitektur

Profil OS dikunci di `1-default_settings`. Yang divariasikan hanya arsitektur jalur:

| Keputusan | Pilihan | Lapisan ekstensi 1 yang terdampak |
|---|---|---|
| **A. Enkapsulasi antar-node** | overlay (VXLAN / IP-in-IP) vs routing langsung | L2 (dan L3) |
| **B. Implementasi Service** | kube-proxy (iptables) vs eBPF (*kube-proxy replacement*, KPR) | L3, L4 |
| **C. Jalur di host** | stack netfilter biasa vs BPF host-routing (melewati iptables/upper stack) | L2–L4, terutama latensi |

### 2.1 Matriks varian

| Nama varian (`cni=`) | A | B | C | Status |
|---|---|---|---|---|
| `flannel` | VXLAN | iptables | biasa | ✔ data ada |
| `flannel-hostgw` | routing | iptables | biasa | ✔ data ada |
| `calico` | IP-in-IP (bawaan operator, MTU pod 1480) | iptables | biasa | ✔ data ada; mode perlu diverifikasi (§4) |
| `calico-noencap` | routing (BGP) | iptables | biasa | **baru** |
| `cilium` (= cilium-vxlan) | VXLAN (`CILIUM_TUNNEL=vxlan`) | iptables (kube-proxy) | biasa | CNI sudah ada; **ekstensi belum dijalankan** |
| `cilium-native` | routing (native) | iptables (kube-proxy) | biasa | **baru** (memisahkan A dari B+C) |
| `cilium-native-kpr` | routing (native) | **eBPF** | **BPF host-routing** | **baru** |

Tiga varian benar-benar baru. `cilium` cukup dijalankan dengan `07-cluster.sh cilium`
lalu `06-run-ekstensi.sh cilium`. Data `flannel`, `flannel-hostgw`, dan `calico` diimpor
dari `replikasi_dakic` (run 18 Nov 2026; lihat `results/ekstensi/*/IMPORTED.txt`).

### 2.2 Pasangan pembanding (isolasi faktor)

| Pasangan | Faktor yang berbeda | Pertanyaan |
|---|---|---|
| `calico` vs `calico-noencap` | A saja | Biaya IP-in-IP pada Calico |
| `flannel` vs `flannel-hostgw` | A saja | Biaya VXLAN pada Flannel (sudah ada) |
| `flannel-hostgw` vs `calico-noencap` | implementasi CNI (keduanya routing + iptables) | Apakah CNI routing setara satu sama lain? |
| `cilium` vs `flannel` | implementasi CNI (keduanya VXLAN + iptables) | Apakah data plane eBPF Cilium lebih murah daripada VXLAN kernel Flannel? |
| `cilium` vs `cilium-native` | A saja | Biaya VXLAN pada Cilium |
| `cilium-native` vs `cilium-native-kpr` | B + C | Manfaat Service eBPF + BPF host-routing |
| `cilium` vs `cilium-native-kpr` | A + B + C sekaligus | Batas atas manfaat arsitektur eBPF penuh |
| `calico-noencap` vs `cilium-native-kpr` | B + C (keduanya routing) | Manfaat Service eBPF + BPF host-routing di luar efek enkapsulasi |

Keterbatasan rancangan: `cilium-native` memisahkan A dari B+C, tetapi B dan C tetap
tercampur. Di Cilium 1.15, BPF host-routing mensyaratkan kube-proxy replacement dan BPF
masquerade, jadi C tidak dapat diaktifkan tanpa B.

## 3. Implementasi

Semua perubahan mengikuti pola yang sudah ada: tambahan di `overlay/plays/` diberi label
`[EKSTENSI]`, lalu `01-build-work.sh` membangun ulang `work/`. Kode penulis di
`upstream/` tidak disentuh.

### 3.1 `calico-noencap` (`overlay/plays/cni.yml`)

Syarat: kedua node satu subnet L2 (10.97.0.x), terpenuhi di testbed.

```yaml
    # [EKSTENSI] calico-noencap: IPPool tanpa enkapsulasi, rute pod via BGP (bird)
    - name: Calico tanpa enkapsulasi
      shell: |
        helm repo add projectcalico https://docs.tigera.io/calico/charts --force-update
        kubectl create namespace tigera-operator --dry-run=client -o yaml | kubectl apply -f -
        helm upgrade --install calico projectcalico/tigera-operator --version {{ calico_version }} \
          --namespace tigera-operator \
          --set 'installation.calicoNetwork.bgp=Enabled' \
          --set 'installation.calicoNetwork.ipPools[0].cidr={{ pod_cidr }}' \
          --set 'installation.calicoNetwork.ipPools[0].encapsulation=None' \
          --set 'installation.calicoNetwork.ipPools[0].natOutgoing=Enabled'
      when: cni == "calico-noencap"
```

Task Calico yang lama tetap `when: cni == "calico"`, jadi varian lama tidak berubah.

### 3.2 `cilium-native-kpr`

**(a) Cluster tanpa kube-proxy** (`overlay/plays/6-kubeadm.yml`). KPR mensyaratkan
kube-proxy tidak terpasang:

```yaml
    - name: Kubeadm init
      shell: >
        kubeadm init --pod-network-cidr={{ pod_cidr }}
        --apiserver-advertise-address={{ ansible_ssh_host }}
        {{ '--skip-phases=addon/kube-proxy' if cni | default('') == 'cilium-native-kpr' else '' }}
      args:
        creates: /etc/kubernetes/admin.conf
```

`scripts/07-cluster.sh` meneruskan `-e cni=$cni` ke semua playbook cluster, termasuk
`plays/6-kubeadm.yml` (di `replikasi_dakic` hanya ke `plays/cni.yml`).

**(b) Pemasangan Cilium** (`overlay/plays/cni.yml`):

```yaml
    # [EKSTENSI] cilium-native-kpr: routing native + kube-proxy replacement eBPF
    # + BPF masquerade (mengaktifkan BPF host-routing pada kernel >= 5.10)
    - name: Cilium native + KPR
      shell: |
        helm repo add cilium https://helm.cilium.io/ --force-update
        helm upgrade --install cilium cilium/cilium --version {{ cilium_version }} \
          --namespace kube-system \
          --set routingMode=native \
          --set autoDirectNodeRoutes=true \
          --set ipv4NativeRoutingCIDR={{ pod_cidr }} \
          --set ipam.mode=kubernetes \
          --set kubeProxyReplacement=true \
          --set k8sServiceHost={{ ansible_ssh_host }} \
          --set k8sServicePort=6443 \
          --set bpf.masquerade=true
      when: cni == "cilium-native-kpr"
```

Catatan:
- `ipam.mode=kubernetes` wajib. IPAM bawaan Cilium (`cluster-pool` 10.0.0.0/8)
  tumpang-tindih dengan IP node 10.97.0.x, sehingga routing native akan rusak.
  Perbedaan IPAM dengan varian `cilium` tidak memengaruhi data plane.
- `k8sServiceHost/Port` wajib karena tanpa kube-proxy pod Cilium tidak bisa mencapai
  API server lewat ClusterIP `kubernetes`.
- Versi tetap 1.15.6 (= paper) agar varian sebanding.
- Playbook berjalan di node control-plane, jadi `ansible_ssh_host` = IP API server.

### 3.3 `cilium-native`

Sama dengan `cilium-native-kpr`, tetapi `kubeProxyReplacement=false`, tanpa
`bpf.masquerade`, dan cluster tetap memakai kube-proxy. Host-routing Cilium tetap
`Legacy`. Satu-satunya beda dengan `cilium` adalah enkapsulasi (A).

### 3.4 Daftar varian (`config.env`)

```bash
EXT_PATH_VARIANTS="${EXT_PATH_VARIANTS:-calico-noencap cilium cilium-native cilium-native-kpr}"
```

### 3.5 File yang diubah atau ditambah (relatif terhadap `replikasi_dakic`)

| File | Perubahan |
|---|---|
| `overlay/plays/cni.yml` | + task `calico-noencap`, `cilium-native`, `cilium-native-kpr` |
| `overlay/plays/6-kubeadm.yml` | `--skip-phases=addon/kube-proxy` bila `cni=cilium-native-kpr` |
| `scripts/07-cluster.sh` | `-e cni=<varian>` ke semua playbook cluster |
| `scripts/06-run-ekstensi.sh` | + `env/path-mode.txt` dan verifikasi otomatis (§4) |
| `scripts/08-run-path-variants.sh` | **baru**: menjalankan semua varian berurutan, melewati yang sudah `.done` |
| `scripts/05-analyze.sh` | hanya analisis ekstensi |
| `analysis/ekstensi.py` | + `path_analysis()`: ringkasan per varian, uji per pasangan, 2 grafik |
| `config.env` | + `EXT_PATH_VARIANTS` |
| dihapus | `03-run-os-baseline.sh`, `04-run-cni.sh`, `run-tests.sh`, `parse.py`, `plot.py` (khusus replikasi) |

## 4. Verifikasi varian (wajib sebelum mengukur)

Hasil hanya sah bila varian benar-benar aktif. `06-run-ekstensi.sh` menambahkan file
`env/path-mode.txt` berisi keluaran berikut (dijalankan di node klien):

| Varian | Perintah | Hasil yang diharapkan |
|---|---|---|
| semua | `ip -d link show; ip route` | tidak ada `vxlan`/`tunl0` aktif untuk varian routing; rute pod via `eth0` |
| semua | MTU antarmuka pod (sudah ada di `pod-network.txt`) | overlay: 1450/1480; routing: 1500 |
| `calico`, `calico-noencap` | `kubectl get ippools.crd.projectcalico.org -o jsonpath='{..ipipMode} {..vxlanMode}'` | `calico`: `Always Never` (konfirmasi IP-in-IP); `calico-noencap`: `Never Never` |
| `calico-noencap` | `ip route \| grep bird` | rute 10.244.x.0/26 via 10.97.0.x `proto bird` |
| `cilium*` | `kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose` | `cilium`: `Routing: Network: Tunnel [vxlan]`, `KubeProxyReplacement: False`; `cilium-native-kpr`: `Network: Native`, `Host Routing: BPF`, `KubeProxyReplacement: True`, `Masquerading: BPF` |
| `cilium-native-kpr` | `kubectl -n kube-system get ds kube-proxy` dan `iptables-save \| grep -c KUBE-SVC` | DaemonSet tidak ada; hitungan 0 |

Jika `Host Routing` tercatat `Legacy`, varian C tidak aktif. Ini harus dicatat dan
hasilnya dibaca sebagai A + B saja.

**Verifikasi otomatis.** `06-run-ekstensi.sh` memeriksa keluaran di atas sebelum mengukur
dan menulis `# VERIFIKASI: SESUAI` atau `# VERIFIKASI: TIDAK SESUAI` di akhir
`env/path-mode.txt`. Bila tidak sesuai, skrip berhenti agar satu jam pengukuran tidak
terbuang untuk varian yang salah. Timpa dengan `EXT_ALLOW_MODE_MISMATCH=true` bila memang
disengaja, mis. `cilium-native-kpr` yang host-routing-nya ternyata `Legacy` di VM.
Status verifikasi ikut tercatat di kolom `verifikasi` pada `ekstensi_path_summary.csv`.

## 5. Cara menjalankan

Folder ini berdiri sendiri. Salin seluruh `modifikasi_dakic/` ke mesin controller (yang
sama dengan replikasi), lalu:

```bash
cd modifikasi_dakic
cp ../replikasi_dakic/config.local.env .    # IP node, user, NIC (bila ada)
./scripts/00-setup-controller.sh            # virtualenv (sekali saja)
./scripts/01-build-work.sh                  # work/ = upstream + overlay modifikasi
./scripts/08-run-path-variants.sh           # semua varian EXT_PATH_VARIANTS + analisis
```

Satu varian saja: `./scripts/07-cluster.sh calico-noencap && ./scripts/06-run-ekstensi.sh calico-noencap`.
Node sudah disiapkan oleh replikasi, jadi `02-prepare-nodes.sh` hanya perlu bila node baru.

Opsional, untuk membuktikan mode Calico yang sudah diukur (IP-in-IP):
`./scripts/07-cluster.sh calico && EXT_ITERATIONS=1 ./scripts/06-run-ekstensi.sh calico`.
Perhatian: perintah ini menimpa data impor `results/ekstensi/cni-calico`, jadi salin
dulu folder itu bila ingin menyimpannya.

**Estimasi waktu:** ±70 menit per varian (5 lapisan × 5 tes termasuk idle × 5 iterasi ×
30 s ≈ 63 menit, plus reset dan deploy cluster), total ±4,5–5 jam untuk 4 varian. `08-run-path-variants.sh` aman
diulang: varian yang sudah `.done` dilewati.

## 6. Analisis

`analysis/ekstensi.py` tetap menghasilkan keluaran ekstensi 1 (`ekstensi_runs/summary/stats.csv`,
`ext_*.png`; untuk data impor hasilnya identik dengan `replikasi_dakic`), ditambah:

1. **`results/summary/ekstensi_path_summary.csv`**: per varian × lapisan (L0, L2, L3, L4),
   berisi faktor A/B/C, TCP/UDP Gbit/s, overhead, p50/p99 TCP_RR, CPU, Gbit/s per %CPU,
   dan status verifikasi.
2. **`results/summary/ekstensi_path_stats.csv`**: per pasangan §2.2 × metrik × lapisan
   (L2–L4), berisi rerata a/b, selisih absolut dan %, Cliff's delta (besar efek, −1…1),
   p Mann–Whitney U, dan p Holm. Metrik: `tcp_gbps`, `udp_gbps`, `tcprr_p50_us`,
   `tcprr_p99_us`, `tcp_cpu_pct`, `tcp_gbps_per_cpu`.
   - Keluarga Holm = (pasangan, metrik) atas ≤3 lapisan. Dengan n=5 per kelompok, p
     Mann–Whitney terkecil yang mungkin adalah 0,0079. Keluarga yang lebih besar (mis. 12
     uji) akan membuat tidak ada hasil yang bisa signifikan.
   - Cliff's delta = ±1 berarti kelima iterasi varian b seluruhnya di atas/di bawah varian a.
3. **Dekomposisi biaya**: dibaca langsung dari `delta` pasangan A (biaya enkapsulasi) dan
   B+C (biaya Service + jalur host) pada L2, L3, L4.
4. **Grafik**: `results/figures/ext_path_throughput.png` (TCP per varian, batang L0/L2/L3/L4)
   dan `ext_path_latency.png` (p50 pekat, p99 pudar).

Analisis sudah diuji pada data impor (3 varian). Hasilnya, pasangan `flannel` vs
`flannel-hostgw` signifikan di L2 dan L3 untuk throughput dan p99 (Cliff's δ = ±1), tetapi
tidak di L4. Ini konsisten dengan temuan bahwa jalur NodePort tidak melewati overlay.

## 7. Pertanyaan riset dan hipotesis

- **RQ4:** Seberapa besar biaya enkapsulasi (A) dibanding biaya Service (B) dan jalur host (C)
  pada throughput, latensi p99, dan CPU?
- **RQ5:** Apakah arsitektur eBPF penuh (A+B+C) melampaui CNI routing berbasis iptables, atau
  hanya setara?

| Hipotesis | Pernyataan | Dasar |
|---|---|---|
| **H4** | Routing langsung mengembalikan throughput L2 hingga overhead ≤5% untuk semua CNI | `host-gw` = 3,5% |
| **H5** | Service eBPF (KPR) menurunkan latensi p50/p99 dan CPU di L3/L4 dibanding iptables | DNAT di socket/tc, bukan per paket di netfilter |
| **H6** | `cilium-native-kpr` memberi latensi L2 lebih rendah daripada `flannel-hostgw` | BPF host-routing melewati upper stack |
| **H7** | Efek setiap keputusan arsitektur (A) > efek terbesar setelan OS (+5,5%; angka ini dari Calico, lintas CNI terkoreksi +18,5%) | menjawab langsung fokus Dakić |

## 8. Integrasi ke laporan (`laporan/main.tex`)

- **Bagian V (Usulan):** subbagian baru "Variasi Arsitektur Jalur" berisi Tabel varian (§2.1),
  RQ4–RQ5, dan H4–H7.
- **Hasil Awal:** tabel varian × L2/L3/L4 dan satu grafik `ext_path_throughput.png`.
- **Kesimpulan:** satu kalimat perbandingan "arsitektur vs setelan OS" dengan angka.
- Perhatikan batas 8 halaman. Bila perlu, pindahkan `latency_local.png` ke lampiran.

## 9. Risiko dan keterbatasan

| Risiko | Dampak | Mitigasi |
|---|---|---|
| Testbed = 2 VM di 1 host fisik | Throughput dibatasi CPU/virtio, bukan NIC; biaya relatif tetap sah | Nyatakan di laporan; ulangi di server fisik bila tersedia |
| Host-routing BPF tidak aktif di VM | H6 tidak teruji | Verifikasi §4; laporkan apa adanya |
| B dan C Cilium tercampur | Tidak bisa memisah KPR vs host-routing | Varian opsional `cilium-native` |
| Calico BGP gagal *peering* | Pod antar-node tidak terhubung | Cek `calicoctl node status` / log `calico-node` |
| RAPL tidak tersedia di VM | ε (Gbit/s per watt) kosong | Sama dengan ekstensi 1; dicatat |
| Hanya Antrea yang tidak diuji | Cakupan CNI tidak lengkap | Antrea `noEncap` dapat ditambah dengan pola sama |

## 10. Checklist pengerjaan

- [x] Tambah task `calico-noencap`, `cilium-native`, `cilium-native-kpr` di `overlay/plays/cni.yml`
- [x] Tambah `--skip-phases=addon/kube-proxy` bersyarat di `overlay/plays/6-kubeadm.yml`
- [x] Teruskan `-e cni=$cni` ke `plays/6-kubeadm.yml` di `scripts/07-cluster.sh`
- [x] Tambah `EXT_PATH_VARIANTS` di `config.env`
- [x] Tambah pencatatan dan verifikasi `env/path-mode.txt` di `scripts/06-run-ekstensi.sh`
- [x] Tambah `scripts/08-run-path-variants.sh`
- [x] Tambah analisis per varian dan grafik di `analysis/ekstensi.py` (diuji pada data impor)
- [x] Impor data `flannel`, `flannel-hostgw`, `calico` dari `replikasi_dakic`
- [ ] Jalankan 4 varian di testbed; pastikan `path-mode.txt` berakhir `VERIFIKASI: SESUAI`
- [ ] (opsional) Verifikasi mode IP-in-IP `calico` yang diimpor
- [ ] Perbarui `laporan/main.tex` (§8) dan `laporan/perbandingan_dakic.md`
