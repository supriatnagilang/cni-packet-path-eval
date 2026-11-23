#!/usr/bin/env python3
"""Analisis usulan pengembangan (overhead berlapis).

Masukan : results/ekstensi/cni-<x>/<layer>/iter_XX_<test>.{out,client.mon,server.mon}
Keluaran: results/summary/ekstensi_runs.csv, ekstensi_summary.csv, ekstensi_stats.csv
          results/figures/ext_throughput.png, ext_latency.png, ext_efficiency.png

Metrik per lapisan l (rumus di laporan):
  O_l   = 1 - T_l / T_L0                (overhead throughput relatif)
  dC_l  = C_l - C_L0                    (tambahan CPU, rerata klien+server, % busy)
  eta_l = T_l / C_l                     (Gbit/s per %CPU)
  eps_l = T_l / P_l                     (Gbit/s per watt, RAPL paket CPU, bila ada)
Uji statistik: Kruskal-Wallis antar-lapisan, lalu Mann-Whitney U antar-lapisan
berurutan dengan koreksi Holm (alpha 0,05).
"""
import json
import re
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd
from scipy import stats

ROOT = Path(__file__).resolve().parent.parent
import os
RES = Path(os.environ.get("RESULTS_DIR", ROOT / "results"))
EXT = RES / "ekstensi"
SUM = RES / "summary"
FIG = RES / "figures"
LAYERS = ["L0-host", "L1-hostnet-pod", "L2-pod-ip", "L3-clusterip", "L4-nodeport"]
NAME = re.compile(r"iter_(\d+)_(idle|tcp|udp|tcprr|udprr)\.out$")


def read_mon(path):
    """-> (cpu_busy_mean, mem_mean, watt or None)"""
    if not path.exists():
        return None, None, None
    rows, watt = [], None
    for line in path.read_text().splitlines():
        if line.startswith("# energy_uj"):
            _, _, uj, _, sec = line.split()
            watt = int(uj) / 1e6 / float(sec)
        elif line and line[0].isdigit():
            rows.append([float(x) for x in line.split()])
    if not rows:
        return None, None, watt
    df = pd.DataFrame(rows)
    return df[0].mean(), df[5].mean(), watt


def parse_out(test, text):
    r = {}
    if test in ("tcp", "udp"):
        try:
            j = json.loads(text[text.index("{"):])
        except (ValueError, json.JSONDecodeError):
            return {"error": True}
        end = j.get("end", {})
        if test == "tcp":
            r["gbps"] = end.get("sum_received", {}).get("bits_per_second", 0) / 1e9
            r["retrans"] = end.get("sum_sent", {}).get("retransmits")
        else:
            s = end.get("sum_received") or end.get("sum", {})
            r["gbps"] = s.get("bits_per_second", 0) / 1e9
            r["udp_loss_pct"] = end.get("sum", {}).get("lost_percent")
        r["error"] = "error" in j
    elif test in ("tcprr", "udprr"):
        vals = None
        for line in reversed(text.strip().splitlines()):
            parts = line.split(",")
            if len(parts) == 8:
                try:
                    vals = [float(x) for x in parts]
                    break
                except ValueError:
                    continue
        if vals is None:
            return {"error": True}
        keys = ["lat_min", "lat_mean", "lat_p50", "lat_p90", "lat_p99", "lat_max", "lat_std", "trans_per_s"]
        r = dict(zip(keys, vals))
        # netperf mencetak baris nol bila koneksi data gagal ("connect_data_socket failed")
        r["error"] = r["trans_per_s"] <= 0
    else:
        r["error"] = False
    return r


def holm(pvals):
    order = sorted(range(len(pvals)), key=lambda i: pvals[i])
    adj, m, run = [0.0] * len(pvals), len(pvals), 0.0
    for rank, i in enumerate(order):
        run = max(run, min(1.0, (m - rank) * pvals[i]))
        adj[i] = run
    return adj


def main():
    rows = []
    for f in sorted(EXT.glob("cni-*/*/iter_*.out")):
        m = NAME.search(f.name)
        if not m:
            continue
        cni, layer = f.parent.parent.name, f.parent.name
        base = f.with_suffix("")
        c_cpu, c_mem, c_w = read_mon(Path(f"{base}.client.mon"))
        s_cpu, s_mem, s_w = read_mon(Path(f"{base}.server.mon"))
        r = parse_out(m[2], f.read_text(errors="replace"))
        watts = [w for w in (c_w, s_w) if w is not None]
        rows.append({"cni": cni, "layer": layer, "iter": int(m[1]), "test": m[2], **r,
                     "cpu_client": c_cpu, "cpu_server": s_cpu,
                     "cpu_mean": None if c_cpu is None else (c_cpu + (s_cpu or c_cpu)) / 2,
                     "mem_client_mb": c_mem, "mem_server_mb": s_mem,
                     "watt_total": sum(watts) if watts else None})
    if not rows:
        print("Tidak ada data ekstensi.")
        return
    SUM.mkdir(parents=True, exist_ok=True); FIG.mkdir(parents=True, exist_ok=True)
    df = pd.DataFrame(rows)
    df.to_csv(SUM / "ekstensi_runs.csv", index=False)
    ok = df[~df["error"].fillna(False).astype(bool)].copy()
    for col in ["gbps", "udp_loss_pct", "lat_p50", "lat_p99", "cpu_mean", "watt_total"]:
        if col not in ok:
            ok[col] = float("nan")
        ok[col] = pd.to_numeric(ok[col], errors="coerce")

    agg = ok.groupby(["cni", "layer", "test"]).agg(
        gbps=("gbps", "mean"), gbps_std=("gbps", "std"), loss=("udp_loss_pct", "mean"),
        p50=("lat_p50", "mean"), p99=("lat_p99", "mean"),
        cpu=("cpu_mean", "mean"), watt=("watt_total", "mean"), n=("iter", "count")).reset_index()
    l0 = agg[agg.layer == "L0-host"].set_index(["cni", "test"])
    agg["overhead_pct"] = [100 * (1 - r.gbps / l0.loc[(r.cni, r.test), "gbps"])
                           if (r.cni, r.test) in l0.index and l0.loc[(r.cni, r.test), "gbps"] else None
                           for r in agg.itertuples()]
    agg["dcpu"] = [r.cpu - l0.loc[(r.cni, r.test), "cpu"] if (r.cni, r.test) in l0.index else None
                   for r in agg.itertuples()]
    agg["gbps_per_cpu"] = agg["gbps"] / agg["cpu"]
    agg["gbps_per_watt"] = agg["gbps"] / agg["watt"]
    agg.to_csv(SUM / "ekstensi_summary.csv", index=False)

    st = []
    for (cni, test), g in ok.groupby(["cni", "test"]):
        metric = "gbps" if test in ("tcp", "udp") else ("lat_p99" if test.endswith("rr") else None)
        if metric is None or metric not in g:
            continue
        groups = [g[g.layer == l][metric].dropna() for l in LAYERS if l in set(g.layer)]
        present = [l for l in LAYERS if l in set(g.layer)]
        if len(groups) >= 2 and all(len(x) >= 2 for x in groups):
            kw = stats.kruskal(*groups)
            pairs = list(zip(present, present[1:]))
            ps = [stats.mannwhitneyu(g[g.layer == a][metric], g[g.layer == b][metric]).pvalue for a, b in pairs]
            for (a, b), p, pa in zip(pairs, ps, holm(ps)):
                st.append({"cni": cni, "test": test, "metric": metric, "kruskal_p": kw.pvalue,
                           "pair": f"{a} vs {b}", "mwu_p": p, "holm_p": pa, "signif_0.05": pa < 0.05})
    pd.DataFrame(st).to_csv(SUM / "ekstensi_stats.csv", index=False)

    cnis = sorted(agg.cni.unique())
    # Throughput per lapisan
    fig, axes = plt.subplots(1, 2, figsize=(7.2, 3), sharey=False)
    for ax, test in zip(axes, ["tcp", "udp"]):
        d = agg[agg.test == test]
        w = 0.8 / max(len(cnis), 1)
        for i, c in enumerate(cnis):
            dc = d[d.cni == c].set_index("layer").reindex(LAYERS)
            x = [j + (i - (len(cnis) - 1) / 2) * w for j in range(len(LAYERS))]
            ax.bar(x, dc.gbps, w, yerr=dc.gbps_std, capsize=2, label=c.replace("cni-", ""))
        ax.set_xticks(range(len(LAYERS))); ax.set_xticklabels([l.split("-")[0] for l in LAYERS])
        ax.set_title(f"{test.upper()} ({'-b 0' if test == 'udp' else 'iperf3'})", fontsize=9)
        ax.set_ylabel("Gbit/s"); ax.grid(axis="y", alpha=0.3)
    axes[0].legend(fontsize=7)
    fig.tight_layout(); fig.savefig(FIG / "ext_throughput.png", dpi=200); plt.close(fig)

    # Latensi p50/p99
    if "p99" in agg:
        fig, ax = plt.subplots(figsize=(7.2, 3))
        d = agg[agg.test == "tcprr"]
        w = 0.8 / max(len(cnis), 1)
        for i, c in enumerate(cnis):
            dc = d[d.cni == c].set_index("layer").reindex(LAYERS)
            x = [j + (i - (len(cnis) - 1) / 2) * w for j in range(len(LAYERS))]
            ax.bar(x, dc.p99, w, alpha=0.35, color=f"C{i}")
            ax.bar(x, dc.p50, w, color=f"C{i}", label=c.replace("cni-", ""))
        ax.set_xticks(range(len(LAYERS))); ax.set_xticklabels(LAYERS, fontsize=7)
        ax.set_ylabel("TCP_RR latensi (µs)\nbatang pekat = p50, pudar = p99"); ax.legend(fontsize=7)
        ax.grid(axis="y", alpha=0.3)
        fig.tight_layout(); fig.savefig(FIG / "ext_latency.png", dpi=200); plt.close(fig)

    # Efisiensi
    fig, axes = plt.subplots(1, 2, figsize=(7.2, 3))
    d = agg[agg.test == "tcp"]
    for ax, col, lab in zip(axes, ["gbps_per_cpu", "gbps_per_watt"], ["Gbit/s per %CPU", "Gbit/s per watt (RAPL)"]):
        for i, c in enumerate(cnis):
            dc = d[d.cni == c].set_index("layer").reindex(LAYERS)
            ax.plot([l.split("-")[0] for l in LAYERS], dc[col], marker="o", label=c.replace("cni-", ""))
        ax.set_title(lab, fontsize=9); ax.grid(alpha=0.3)
    axes[0].legend(fontsize=7)
    fig.tight_layout(); fig.savefig(FIG / "ext_efficiency.png", dpi=200); plt.close(fig)
    print(f"Ekstensi: {len(df)} run -> {SUM}/ekstensi_*.csv, {FIG}/ext_*.png")
    path_analysis(ok, agg)


# ----------------------------------------------------------------------------
# [MODIFIKASI] Analisis varian arsitektur jalur (ARSITEKTUR_JALUR.md §2 dan §6)
# ----------------------------------------------------------------------------
# varian -> (A: enkapsulasi, B: implementasi Service, C: jalur host)
VARIANT_INFO = {
    "cni-flannel":           ("VXLAN", "iptables", "netfilter"),
    "cni-flannel-hostgw":    ("routing", "iptables", "netfilter"),
    "cni-calico":            ("IP-in-IP", "iptables", "netfilter"),
    "cni-calico-noencap":    ("routing", "iptables", "netfilter"),
    "cni-cilium":            ("VXLAN", "iptables", "netfilter"),
    "cni-cilium-native":     ("routing", "iptables", "netfilter"),
    "cni-cilium-native-kpr": ("routing", "eBPF", "BPF"),
    "cni-antrea":            ("Geneve", "iptables", "OVS"),
}
# (varian a, varian b, faktor yang berbeda)
PAIRS = [
    ("cni-flannel", "cni-flannel-hostgw", "A (Flannel)"),
    ("cni-calico", "cni-calico-noencap", "A (Calico)"),
    ("cni-cilium", "cni-cilium-native", "A (Cilium)"),
    ("cni-cilium-native", "cni-cilium-native-kpr", "B+C (Cilium)"),
    ("cni-cilium", "cni-cilium-native-kpr", "A+B+C (Cilium)"),
    ("cni-flannel-hostgw", "cni-calico-noencap", "implementasi (routing+iptables)"),
    ("cni-flannel", "cni-cilium", "implementasi (VXLAN+iptables)"),
    ("cni-calico-noencap", "cni-cilium-native-kpr", "B+C (+implementasi)"),
]
PATH_LAYERS = ["L2-pod-ip", "L3-clusterip", "L4-nodeport"]
# (nama metrik, tes, kolom)
PATH_METRICS = [("tcp_gbps", "tcp", "gbps"), ("udp_gbps", "udp", "gbps"),
                ("tcprr_p50_us", "tcprr", "lat_p50"), ("tcprr_p99_us", "tcprr", "lat_p99"),
                ("tcp_cpu_pct", "tcp", "cpu_mean"), ("tcp_gbps_per_cpu", "tcp", "eta")]


def cliffs_delta(a, b):
    a, b = list(a), list(b)
    if not a or not b:
        return float("nan")
    s = sum((x > y) - (x < y) for x in a for y in b)
    return s / (len(a) * len(b))


def verification(cni):
    """Baris terakhir '# VERIFIKASI' di env/path-mode.txt, atau status impor."""
    d = EXT / cni
    f = d / "env" / "path-mode.txt"
    if f.exists():
        for line in reversed(f.read_text(errors="replace").splitlines()):
            if line.startswith("# VERIFIKASI"):
                return line[2:].strip()
    return "diimpor, mode tidak diverifikasi" if (d / "IMPORTED.txt").exists() else "tidak ada path-mode.txt"


def path_analysis(ok, agg):
    present = [v for v in VARIANT_INFO if v in set(ok.cni)]
    if len(present) < 2:
        return
    ok = ok.copy()
    ok["eta"] = ok["gbps"] / ok["cpu_mean"]

    # Ringkasan per varian x lapisan
    rows = []
    for v in present:
        a, b, c = VARIANT_INFO[v]
        for layer in ["L0-host"] + PATH_LAYERS:
            g = agg[(agg.cni == v) & (agg.layer == layer)].set_index("test")
            get = lambda t, col: g.loc[t, col] if t in g.index else float("nan")
            rows.append({"variant": v.replace("cni-", ""), "A_encap": a, "B_service": b, "C_host_path": c,
                         "layer": layer, "tcp_gbps": get("tcp", "gbps"), "tcp_overhead_pct": get("tcp", "overhead_pct"),
                         "udp_gbps": get("udp", "gbps"), "udp_loss_pct": get("udp", "loss"),
                         "tcprr_p50_us": get("tcprr", "p50"), "tcprr_p99_us": get("tcprr", "p99"),
                         "tcp_cpu_pct": get("tcp", "cpu"), "tcp_gbps_per_cpu": get("tcp", "gbps_per_cpu"),
                         "verifikasi": verification(v)})
    summ = pd.DataFrame(rows)
    summ.to_csv(SUM / "ekstensi_path_summary.csv", index=False)

    # Uji per pasangan. Holm per (pasangan, metrik) atas <=3 lapisan: dengan n=5 per
    # kelompok, p Mann-Whitney terkecil = 0,0079, jadi keluarga uji harus kecil agar
    # perbedaan yang konsisten (5 dari 5) tetap bisa signifikan.
    st = []
    for va, vb, factor in PAIRS:
        if va not in present or vb not in present:
            continue
        for name, test, col in PATH_METRICS:
            block = []
            for layer in PATH_LAYERS:
                xa = ok[(ok.cni == va) & (ok.layer == layer) & (ok.test == test)][col].dropna()
                xb = ok[(ok.cni == vb) & (ok.layer == layer) & (ok.test == test)][col].dropna()
                if len(xa) < 2 or len(xb) < 2:
                    continue
                p = stats.mannwhitneyu(xa, xb).pvalue
                ma, mb = xa.mean(), xb.mean()
                block.append({"pair": f"{va[4:]} vs {vb[4:]}", "factor": factor, "metric": name, "layer": layer,
                              "mean_a": ma, "mean_b": mb, "delta": mb - ma,
                              "delta_pct": 100 * (mb / ma - 1) if ma else float("nan"),
                              "cliffs_delta": cliffs_delta(xb, xa), "n_a": len(xa), "n_b": len(xb), "mwu_p": p})
            for r, pa in zip(block, holm([r["mwu_p"] for r in block])):
                r["holm_p"] = pa
                r["signif_0.05"] = pa < 0.05
            st.extend(block)
    pd.DataFrame(st).to_csv(SUM / "ekstensi_path_stats.csv", index=False)

    # Grafik: throughput TCP per varian, batang per lapisan
    labels = [v.replace("cni-", "") for v in present]
    lay = ["L0-host"] + PATH_LAYERS
    fig, ax = plt.subplots(figsize=(7.2, 3.2))
    w = 0.8 / len(lay)
    for i, layer in enumerate(lay):
        d = summ[summ.layer == layer].set_index("variant").reindex(labels)
        x = [j + (i - (len(lay) - 1) / 2) * w for j in range(len(labels))]
        ax.bar(x, d.tcp_gbps, w, label=layer.split("-")[0] + " " + layer.split("-", 1)[1], color=f"C{i}")
    ax.set_xticks(range(len(labels)))
    ax.set_xticklabels([f"{l}\n{'/'.join(VARIANT_INFO['cni-' + l][:2])}" for l in labels], fontsize=6.5)
    ax.set_ylabel("TCP Gbit/s"); ax.grid(axis="y", alpha=0.3)
    ax.legend(fontsize=7, ncol=4, loc="lower center", bbox_to_anchor=(0.5, 1.0), frameon=False)
    fig.tight_layout(); fig.savefig(FIG / "ext_path_throughput.png", dpi=200); plt.close(fig)

    # Grafik: latensi TCP_RR p50 (pekat) dan p99 (pudar) per varian, lapisan L2..L4
    fig, ax = plt.subplots(figsize=(7.2, 3.2))
    w = 0.8 / len(PATH_LAYERS)
    for i, layer in enumerate(PATH_LAYERS):
        d = summ[summ.layer == layer].set_index("variant").reindex(labels)
        x = [j + (i - (len(PATH_LAYERS) - 1) / 2) * w for j in range(len(labels))]
        ax.bar(x, d.tcprr_p99_us, w, alpha=0.35, color=f"C{i + 1}")
        ax.bar(x, d.tcprr_p50_us, w, color=f"C{i + 1}", label=layer)
    ax.set_xticks(range(len(labels))); ax.set_xticklabels(labels, fontsize=7)
    ax.set_ylabel("TCP_RR (µs)\npekat = p50, pudar = p99"); ax.grid(axis="y", alpha=0.3)
    ax.legend(fontsize=7, ncol=3, loc="lower center", bbox_to_anchor=(0.5, 1.0), frameon=False)
    fig.tight_layout(); fig.savefig(FIG / "ext_path_latency.png", dpi=200); plt.close(fig)
    print(f"Varian jalur: {len(present)} varian -> {SUM}/ekstensi_path_*.csv, {FIG}/ext_path_*.png")


if __name__ == "__main__":
    main()
