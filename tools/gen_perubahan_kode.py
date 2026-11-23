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
