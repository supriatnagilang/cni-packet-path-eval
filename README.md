# Modifikasi Dakić et al. (2024): Variasi Arsitektur Jalur Paket

Proyek ini mengembangkan replikasi Dakić et al. (2024), *Electronics* 13(19):3972
(kode penulis: https://github.com/vEddYcro/cni-performance-testing, commit `b0e55c4`).
Dakić et al. mengoptimasi
kinerja CNI lewat **setelan sistem operasi**. Di sini profil OS dikunci di *default*, dan
yang divariasikan adalah **arsitektur jalur paket**:

- **A. Enkapsulasi**: overlay (VXLAN / IP-in-IP) vs routing langsung
- **B. Implementasi Service**: kube-proxy iptables vs eBPF (*kube-proxy replacement*)
- **C. Jalur host**: netfilter vs BPF host-routing

Rancangan lengkap, hipotesis, verifikasi, dan cara membaca hasil ada di
**[ARSITEKTUR_JALUR.md](ARSITEKTUR_JALUR.md)**.

## Varian

| Varian | A | B | C | Data |
|---|---|---|---|---|
| `flannel` | VXLAN | iptables | netfilter | diimpor dari replikasi |
| `flannel-hostgw` | routing | iptables | netfilter | diimpor dari replikasi |
| `calico` | IP-in-IP | iptables | netfilter | diimpor dari replikasi |
| `calico-noencap` | routing (BGP) | iptables | netfilter | `results-1/` |
| `cilium` | VXLAN | iptables | netfilter | `results-1/` |
| `cilium-native` | routing | iptables | netfilter | `results-1/` |
| `cilium-native-kpr` | routing | eBPF | BPF | `results-1/` (cluster tanpa kube-proxy) |

Setiap varian diukur dengan alat ukur ekstensi 1 yang tidak diubah: lapisan L0 host, L1
hostNetwork, L2 IP pod, L3 ClusterIP, dan L4 NodePort, masing-masing 5 iterasi × 30 s
untuk TCP, UDP `-b 0`, TCP_RR, dan UDP_RR, ditambah CPU kedua node.

## Menjalankan

```bash
# di mesin controller yang sama dengan replikasi (node sudah disiapkan)
cd modifikasi_dakic
cp config.local.env.example config.local.env   # isi IP node, user SSH, NIC
./scripts/00-setup-controller.sh           # sekali saja
./scripts/01-build-work.sh
./scripts/08-run-path-variants.sh          # ±4,5–5 jam; aman diulang (varian .done dilewati)
```

Sebelum mengukur, setiap varian diverifikasi otomatis (`results/ekstensi/cni-<v>/env/path-mode.txt`).
Bila mode jalurnya tidak sesuai rancangan, skrip berhenti.

## Isi folder

```
modifikasi_dakic/
├── ARSITEKTUR_JALUR.md        # rancangan + panduan (baca ini dulu)
├── PERUBAHAN_KODE.md          # diff kode terhadap replikasi_dakic, per file
├── config.env                 # + EXT_PATH_VARIANTS
├── upstream/                  # kode penulis apa adanya (commit b0e55c4)
├── overlay/plays/             # cni.yml (+3 varian), 6-kubeadm.yml (opsi tanpa kube-proxy)
├── scripts/
│   ├── 00..02                 # sama dengan replikasi (controller, work/, persiapan node)
│   ├── 05-analyze.sh          # analisis ekstensi + varian jalur
│   ├── 06-run-ekstensi.sh     # L0..L4 + verifikasi mode jalur
│   ├── 07-cluster.sh          # reset -> kubeadm -> CNI varian
│   └── 08-run-path-variants.sh  # BARU: semua varian berurutan
├── analysis/ekstensi.py       # + path_analysis(): ekstensi_path_{summary,stats}.csv, ext_path_*.png
├── tools/sample.sh            # sampler CPU/RAM/RAPL
└── results/
    ├── ekstensi/cni-*/        # data mentah per varian (IMPORTED.txt = dari replikasi)
    ├── summary/               # CSV
    └── figures/               # PNG
```

## Hasil

`results-1/` berisi run lengkap ketujuh varian (875 run, CV ≤ 1,4%) beserta
`summary/` dan `figures/`. Analisis, validitas, dan keterbatasan ada di
**[HASIL_ANALISIS.md](HASIL_ANALISIS.md)**. `results/` hanya berisi tiga varian yang diimpor
dari replikasi sebelum run lengkap. Analisis ulang:
`RESULTS_DIR=results-1 ./scripts/05-analyze.sh`.

Catatan: `upstream/` adalah *git submodule* ke repo penulis pada commit `b0e55c4` (tanpa
perubahan). Setelah clone, jalankan `git submodule update --init`.
