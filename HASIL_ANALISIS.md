# Hasil Analisis: Variasi Arsitektur Jalur Paket (`results-1`)

Data: `results-1/` (run server, diunduh 20 Nov 2026) + 3 varian impor dari replikasi.
7 varian × 5 lapisan × 5 tes × 5 iterasi = **875 run, 0 error**. Profil OS: default.
Analisis: `RESULTS_DIR=results-1 python analysis/ekstensi.py` →
`results-1/summary/ekstensi_path_{summary,stats}.csv`, `results-1/figures/ext_path_*.png`.

## 1. Verifikasi mode jalur

Keempat varian baru semula tercatat `TIDAK SESUAI`, tetapi pemeriksaan ulang terhadap bukti
mentah di `env/path-mode.txt` menunjukkan **semuanya aktif sesuai rancangan**. Penyebabnya
pemeriksaan yang keliru: Cilium 1.15 tidak mencetak baris `Routing: Network: …`, dan kueri
IPPool Calico menghasilkan keluaran kosong. Aturan di `scripts/06-run-ekstensi.sh` sudah
diganti ke bukti yang selalu ada (antarmuka tunnel + rute pod node lain), lalu diuji pada
keempat file asli dan dua kasus negatif. Hasil pemeriksaan ulang ditambahkan sebagai baris
`# VERIFIKASI ULANG` di akhir tiap `path-mode.txt`. Baris aslinya tidak diubah.

| Varian | Bukti | Status |
|---|---|---|
| `flannel` (impor) | MTU pod 1450 (VXLAN) | sesuai |
| `flannel-hostgw` (impor) | MTU pod 1500 | sesuai |
| `calico` (impor) | rute pod `via 10.97.0.17 dev tunl0 proto bird`, `tunl0` di semua profil | **IP-in-IP terkonfirmasi** |
| `calico-noencap` | tanpa `tunl0`; `10.244.151.64/26 via 10.97.0.17 dev eth0 proto bird` | sesuai |
| `cilium` | `cilium_vxlan`; rute pod lewat `cilium_host` MTU 1450; KPR False; Host Routing Legacy | sesuai |
| `cilium-native` | tanpa tunnel; `10.244.1.0/24 via 10.97.0.17 dev eth0`; KPR False; Legacy | sesuai |
| `cilium-native-kpr` | tanpa tunnel, rute native; tanpa kube-proxy; 0 rantai `KUBE-SVC`; KPR True; **Host Routing BPF**; Masquerading BPF | sesuai (A+B+C aktif) |

## 2. Hasil utama (TCP, L2 = pod → IP pod)

Overhead dihitung terhadap L0 cluster masing-masing, karena baseline L0 antar-cluster sedikit
berbeda (TCP_RR p50 64–72 µs).

| Varian | A / B / C | TCP L2 (Gbit/s) | Overhead L2 | +p50 TCP_RR L2−L0 (µs) | +p99 L2−L0 (µs) | Gbit/s per %CPU L2 |
|---|---|---|---|---|---|---|
| flannel | VXLAN / iptables / netfilter | 3,37 | 80,7% | +16,4 | +24,2 | 0,23 |
| calico | IP-in-IP / iptables / netfilter | 3,43 | 79,5% | +16,2 | +22,4 | 0,23 |
| cilium | VXLAN / iptables / netfilter | 3,37 | 80,3% | +12,6 | +20,4 | **0,15** |
| flannel-hostgw | routing / iptables / netfilter | 16,88 | 3,5% | +8,6 | +13,2 | 0,84 |
| calico-noencap | routing / iptables / netfilter | 16,18 | 3,2% | +7,2 | +12,0 | 0,77 |
| cilium-native | routing / iptables / netfilter | 16,09 | 6,3% | +11,0 | +18,2 | 0,79 |
| **cilium-native-kpr** | routing / **eBPF** / **BPF** | **16,85** | **0,3%** | **−0,6** | **−0,6** | 0,82 |

Grafik: `results-1/figures/ext_path_throughput.png`, `ext_path_latency.png`.

## 3. Efek per keputusan arsitektur

Semua selisih di bawah ini signifikan (Mann–Whitney, Holm < 0,05, Cliff's δ = ±1, yaitu 5 dari
5 iterasi konsisten), kecuali bila disebut lain.

**A. Enkapsulasi: faktor dominan.** Menghapus tunnel menaikkan throughput TCP L2 hampir 5×
pada ketiga CNI:

| Pasangan (hanya A berbeda) | TCP L2 | p50 TCP_RR L2 | Gbit/s per %CPU L2 |
|---|---|---|---|
| flannel → flannel-hostgw | 3,37 → 16,88 (+401%) | 83,8 → 76,4 µs (−8,8%, n.s. setelah Holm) | 0,23 → 0,84 |
| calico → calico-noencap | 3,43 → 16,18 (+372%) | 87,8 → 79,0 µs (−10,0%) | 0,23 → 0,77 |
| cilium → cilium-native | 3,37 → 16,09 (+378%) | 82,8 → 81,2 µs (−1,9%) | 0,15 → 0,79 |

UDP (`-b 0`) L2 juga naik +92% s.d. +291%. Pada L4 (NodePort) efek A hampir hilang
(+0,8 s.d. +2,1%), karena jalur NodePort tidak melewati tunnel (temuan ekstensi 1).

**B+C. Service eBPF + BPF host-routing (`cilium-native` → `cilium-native-kpr`).**
- TCP L2/L3/L4: +3,4 s.d. +4,8%. Gbit/s per %CPU +3,1 s.d. +4,8%.
- TCP_RR p50: 81 → 71 µs (−12,6%) dan p99: 118 → 104 µs (−12,4%), **sama besar di L2, L3,
  dan L4**. Karena L2 (pod → IP pod) tidak melewati Service sama sekali, perbaikan latensi
  ini berasal dari **C (BPF host-routing)**, bukan dari B. Data ini memisahkan sebagian
  faktor yang secara konfigurasi tidak bisa dipisah.
- Biaya Service (L3−L2) mendekati nol untuk **semua** varian (−0,4 s.d. +0,8 µs), baik
  iptables maupun eBPF. Pada testbed ini, dengan satu Service dan satu endpoint, B hampir
  tidak berpengaruh.

**Implementasi CNI dengan arsitektur sama:**
- VXLAN: Flannel dan Cilium sama-sama 3,37 Gbit/s, tetapi Cilium memakai CPU lebih banyak
  (Gbit/s per %CPU 0,15 vs 0,23, −33%). Sebaliknya, UDP Cilium lebih tinggi (1,47 vs
  0,85 Gbit/s).
- Routing + iptables: `flannel-hostgw` lebih baik daripada `calico-noencap` (TCP +4%, p99
  −7%, Gbit/s per %CPU +8%).

## 4. Temuan tak terduga: biaya UDP pada kube-proxy replacement

Pada `cilium-native-kpr`, **UDP_RR** jauh lebih lambat di **semua lapisan, termasuk L0
host → host** (di luar Kubernetes):

| | UDP_RR p50 L0 | UDP_RR p50 L3/L4 | CPU klien UDP_RR L0 / L3 | TCP_RR p50 L0 |
|---|---|---|---|---|
| varian lain | 64–69 µs | 73–84 µs | 7–8% / 7–11% | 64–72 µs |
| cilium-native-kpr | **106,6 µs** | **113,6–114,4 µs** | **16% / 29%** | 71,6 µs (normal) |

Kelima iterasi konsisten (105–115 µs). TCP tidak terpengaruh, dan throughput UDP juga tidak
berbeda signifikan dari `cilium-native`.

**Dugaan penyebab (belum diverifikasi):** *socket-LB* Cilium (bagian dari kube-proxy
replacement) memasang hook BPF `cgroup/sendmsg4` dan `recvmsg4` di cgroup root. Untuk TCP,
translasi alamat terjadi sekali saat `connect()`. Untuk UDP tanpa koneksi, seperti
netperf UDP_RR, hook ini berjalan **setiap paket**, termasuk untuk proses di host. Ini cocok
dengan pola datanya: hanya UDP yang terkena, semua lapisan terkena, dan CPU per transaksi
naik. Cara memverifikasinya:
`bpftool cgroup tree /sys/fs/cgroup | grep sock_addr`, lalu bandingkan dengan Helm
`--set socketLB.hostNamespaceOnly=true` atau `--set socketLB.enabled=false`.

Implikasinya: kube-proxy replacement **bukan perbaikan gratis**. Arsitektur ini memberi
latensi TCP terbaik, tetapi menambah sekitar 40 µs per transaksi UDP request-response
(DNS, QUIC, game, telemetri) untuk seluruh node.

## 5. Jawaban RQ dan hipotesis

**RQ4. Besar efek A vs B vs C.**
- A (enkapsulasi) adalah faktor terbesar untuk throughput dan efisiensi: sekitar 75–80 poin
  persen throughput dan 3,4–5,1× Gbit/s per %CPU. Untuk latensi efeknya lebih kecil dan
  bergantung CNI: tambahan p50 TCP_RR berkurang 7,8–9,0 µs (Flannel, Calico) tetapi hanya
  1,6 µs pada Cilium; p99 berkurang 10–11 µs vs 2,2 µs.
- C (BPF host-routing) memberi tambahan +3–5% throughput dan −10 µs (−12%) p50/p99 TCP_RR,
  tetapi bersama B menambah sekitar 40 µs UDP_RR.
- B (Service eBPF vs iptables) tidak terukur pada skala 1 Service.

**RQ5. Apakah eBPF penuh melampaui routing berbasis iptables?** Untuk TCP, ya:
`cilium-native-kpr` vs `calico-noencap` memberi TCP +3,4 s.d. +4,1%, p50 −10 s.d. −12%,
p99 −11 s.d. −13%, Gbit/s per %CPU +5,5 s.d. +6,5% (semua signifikan). Ini satu-satunya
varian yang overhead L2-nya praktis nol (0,3%; tambahan latensi −0,6 µs). Untuk UDP
request-response, tidak (lihat §4).

| Hipotesis | Hasil | Keterangan |
|---|---|---|
| **H4**: routing langsung → overhead L2 ≤5% | **Sebagian diterima** | hostgw 3,5%, calico-noencap 3,2%, kpr 0,3%; `cilium-native` 6,3% sedikit di atas batas |
| **H5**: Service eBPF menurunkan latensi/CPU di L3/L4 | **Ditolak sebagai efek B** | Penurunan latensi sama besar di L2 (tanpa Service), jadi berasal dari C. Biaya Service ≈0 pada kedua implementasi. UDP_RR justru memburuk. |
| **H6**: kpr memberi latensi L2 lebih rendah daripada hostgw | **Diterima untuk TCP** | Tambahan p50 L2−L0: −0,6 vs +8,6 µs; p99: −0,6 vs +13,2 µs. Ditolak untuk UDP_RR (L0 sendiri sudah membengkak). |
| **H7**: efek arsitektur > efek setelan OS terbesar (dirumuskan +5,5% dari Calico; lintas CNI terkoreksi +18,5%) | **Diterima** (pada testbed ini) | Menghapus enkapsulasi +372 s.d. +401%. Besarnya diperbesar oleh virtio tanpa offload tunnel (terkonfirmasi, §6), tetapi selisih sekitar 20× (satu orde besaran) dengan efek OS terbesar membuat arahnya kuat. C saja (+3–5%) lebih kecil daripada efek setelan OS terbesar. |

## 6. Validitas data

**Validitas pengukuran: kuat.**

| Pemeriksaan | Hasil |
|---|---|
| Kelengkapan | 7 × 125 run, 0 error, tidak ada throughput 0 atau transaksi 0 |
| CV antar-iterasi | TCP median 0,6% (maks. 1,2%); TCP_RR/UDP_RR median 0,6% (maks. 1,4%) |
| Tren selama run | maks. 0,6% per iterasi |
| Reproduksibilitas antar-hari | L0 `calico` (18 Nov) vs `calico-noencap` (20 Nov): 16,71 vs 16,72 Gbit/s; TCP_RR p50 71,6 vs 71,8 µs |
| Mode jalur | ketujuh varian terbukti dari bukti mentah (§1) |

**Ancaman yang harus dinyatakan di laporan:**

1. **Besar penalti overlay kemungkinan artefak testbed virtual.** Tiga implementasi
   overlay yang berbeda (VXLAN kernel, IP-in-IP, VXLAN eBPF) mentok di 3,37–3,43 Gbit/s
   dengan CPU **tidak** penuh (server ±20% vs ±25,5% saat routing) dan retransmisi tinggi
   (466–910 per run). Pola ini menunjukkan hambatan bersama di luar CNI.
   **Terkonfirmasi untuk VXLAN (20 Nov 2026)**: `ethtool -k eth0` pada doktnet01 menunjukkan
   `tx-udp_tnl-segmentation: off [fixed]` dan `tx-udp_tnl-csum-segmentation: off [fixed]`.
   NIC virtio tidak dapat melakukan offload segmentasi paket tunnel UDP, sehingga kernel
   memecah setiap paket VXLAN (Flannel, Cilium) secara software. Hal yang sama berlaku untuk
   IP-in-IP (Calico): `tx-ipxip4-segmentation: off [fixed]` (juga `tx-gre-segmentation`).
   Jadi **ketiga overlay terkena batas yang sama**, yang menjelaskan throughput identik
   3,37–3,43 Gbit/s walau implementasinya berbeda. Arah efek (enkapsulasi = faktor terbesar) valid, tetapi
   angka "80%/5×" **tidak boleh digeneralisasi** ke NIC fisik yang mendukung offload VXLAN.
2. **Throughput varian routing dibatasi satu inti CPU** (server ±25,5% dari 4 vCPU). Selisih
   3–5% antar-varian routing = selisih biaya CPU per paket, bukan kapasitas jalur.
   Gbit/s per %CPU di sini hampir identik dengan throughput.
3. **Throughput UDP berisik** (CV L2/L3 hingga 16–30%). Hanya perbedaan UDP besar (≥2×) yang
   layak disimpulkan.
4. **L0 tidak netral sepenuhnya**: berbeda hingga 4,6% antar-cluster (Calico lebih rendah di
   kedua hari), dan pada KPR L0 UDP_RR ikut terdampak. Overhead relatif terhadap L0 sendiri
   karena itu meremehkan biaya UDP_RR KPR.
5. **Satu pembangunan cluster per varian.** Variasi antar-cluster hanya terlihat tidak langsung
   dari reproduksibilitas L0 Calico.

## 7. Keterbatasan

- Testbed: 2 VM di 1 host fisik (virtio). Throughput dibatasi CPU satu inti (routing) atau
  oleh segmentasi software paket tunnel (overlay; virtio tanpa offload tunnel, terkonfirmasi).
  Besar efek enkapsulasi kemungkinan jauh lebih kecil di NIC fisik dengan offload VXLAN (§6).
  Temuan ini sekaligus menunjukkan bahwa **kemampuan offload NIC adalah bagian dari arsitektur
  jalur**: overlay di VM/cloud tanpa offload tunnel jauh lebih mahal.
- Varian impor (`flannel`, `flannel-hostgw`, `calico`) diukur pada 18 Nov, sedangkan varian
  baru pada 20 Nov. Baseline L0 antar-cluster berbeda hingga sekitar 5 µs, jadi
  perbandingan latensi memakai selisih terhadap L0 masing-masing.
- Satu Service dengan satu endpoint, sehingga efek B (iptables vs eBPF) yang biasanya
  membesar seiring jumlah Service tidak teruji. Skala Service (mis. 1.000 Service) adalah
  eksperimen lanjutan yang wajar.
- Penyebab biaya UDP pada KPR baru berupa dugaan (§4).
- Energi (RAPL) tidak tersedia di VM.
