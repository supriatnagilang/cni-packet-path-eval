#!/usr/bin/env python3
"""Klien Kubernetes kecil untuk replikasi (pengganti kubectl di controller).

  wait-ready                 keluar 0 bila semua node Ready
  delete-jobs                hapus semua Job uji di namespace default
  collect <out_dir> <opt>    ambil log pod uji (padanan parsers/fetch-k8s-logs.sh penulis)

Penamaan file mengikuti fetch-k8s-logs.sh penulis:
  <out_dir>/<config>/bandwidth/<proto>-mtu-<mtu>-packet-<packet>-<run>.log
  <out_dir>/<config>/latency/<proto>-mtu-<mtu>-<run>.log
Penulis tidak menghapus pod yang gagal; di sini hanya pod Succeeded yang dipakai,
pod lain dicatat di pods.csv.
"""
import csv
import os
import sys
from collections import defaultdict

from kubernetes import client, config

APPS = {
    "bandwidth-tcp-test": "bandwidth",
    "bandwidth-udp-test": "bandwidth",
    "latency-tcp-test": "latency",
    "latency-udp-test": "latency",
}


def api():
    config.load_kube_config(os.environ.get("KUBECONFIG"))
    return client.CoreV1Api(), client.BatchV1Api()


def wait_ready():
    core, _ = api()
    nodes = core.list_node(_request_timeout=10).items
    if not nodes:
        return 1
    for n in nodes:
        ready = [c for c in n.status.conditions if c.type == "Ready"]
        if not ready or ready[0].status != "True":
            return 1
    return 0


def delete_jobs():
    _, batch = api()
    for app in APPS:
        batch.delete_collection_namespaced_job(
            "default", label_selector=f"app={app}", propagation_policy="Background"
        )
    return 0


def collect(out_dir, opt):
    core, _ = api()
    pods = []
    for app, kind in APPS.items():
        for p in core.list_namespaced_pod(
            "default", label_selector=f"app={app},optimization={opt}"
        ).items:
            pods.append((kind, p))
    pods.sort(key=lambda kp: kp[1].metadata.creation_timestamp)

    runs = defaultdict(int)
    rows = []
    for kind, p in pods:
        lb = p.metadata.labels
        phase = p.status.phase
        cfg, proto, mtu = lb.get("config"), lb.get("protocol"), lb.get("mtu")
        packet = lb.get("packet", "")
        fname = ""
        if phase == "Succeeded":
            key = (kind, cfg, proto, mtu, packet)
            runs[key] += 1
            d = os.path.join(out_dir, cfg, kind)
            os.makedirs(d, exist_ok=True)
            if kind == "bandwidth":
                fname = f"{proto}-mtu-{mtu}-packet-{packet}-{runs[key]}.log"
            else:
                fname = f"{proto}-mtu-{mtu}-{runs[key]}.log"
            text = core.read_namespaced_pod_log(p.metadata.name, "default")
            with open(os.path.join(d, fname), "w") as f:
                f.write(text)
        st = p.status
        cs = (st.container_statuses or [None])[0]
        term = cs.state.terminated if cs and cs.state else None
        rows.append({
            "pod": p.metadata.name, "kind": kind, "config": cfg, "protocol": proto,
            "mtu": mtu, "packet": packet, "phase": phase, "node": p.spec.node_name,
            "pod_ip": st.pod_ip, "started": term.started_at if term else "",
            "finished": term.finished_at if term else "", "file": fname,
        })

    with open(os.path.join(out_dir, "pods.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()) if rows else ["pod"])
        w.writeheader()
        w.writerows(rows)
    ok = sum(r["phase"] == "Succeeded" for r in rows)
    print(f"collect {opt}: {ok}/{len(rows)} pod Succeeded")
    # Tumpang-tindih: tes berikutnya dimulai sebelum tes sebelumnya selesai (jeda tetap penulis)
    done = sorted((r["started"], r["finished"]) for r in rows if r["started"] and r["finished"])
    overlap = sum(1 for a, b in zip(done, done[1:]) if b[0] < a[1])
    if overlap:
        print(f"PERINGATAN: {overlap} pasang tes berjalan tumpang-tindih (lihat pods.csv)")
    return 0 if ok else 1


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        if cmd == "wait-ready":
            sys.exit(wait_ready())
        if cmd == "delete-jobs":
            sys.exit(delete_jobs())
        if cmd == "collect":
            sys.exit(collect(sys.argv[2], sys.argv[3]))
    except Exception as e:  # noqa: BLE001
        print(f"k8s_tool: {e}", file=sys.stderr)
        sys.exit(2)
    print(__doc__)
    sys.exit(2)
