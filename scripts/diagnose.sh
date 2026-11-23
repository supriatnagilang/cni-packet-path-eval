#!/usr/bin/env bash
# Diagnosis tes Kubernetes (mis. Flannel tidak menghasilkan data).
# Mengumpulkan log, keadaan cluster, dan menguji jalur jaringan pod secara langsung.
# Pemakaian: ./scripts/diagnose.sh [cni]   -> hasil di results/diagnose.txt
source "$(dirname "$0")/lib.sh"
CNI=${1:-flannel}
OUT="$RESULTS/raw/cni-$CNI"
REPORT="$RESULTS/diagnose.txt"
mkdir -p "$RESULTS"
k() { ssh_node "$CLIENT_IP" "kubectl $*" 2>&1; }

{
echo "===== 1. File hasil cni-$CNI"
ls -la "$OUT" "$OUT"/*/ 2>&1 | head -40
echo; echo "jumlah log tes:"; find "$OUT" -path '*local*' -name '*.log' 2>/dev/null | wc -l

echo; echo "===== 2. deploy.log (galat)"
grep -nE "fatal|FAILED|ERROR|Error" "$OUT/deploy.log" 2>/dev/null | head -20
tail -15 "$OUT/deploy.log" 2>/dev/null

for opt in "$OUT"/*/; do
	[[ -f "$opt/test.log" ]] || continue
	echo; echo "===== 3. test.log $(basename "$opt") (galat + akhir)"
	grep -nE "fatal|FAILED|failed=|unreachable|Failed to import|ModuleNotFound" "$opt/test.log" | head -20
	grep -E "^doktnet|^localhost" "$opt/test.log" | tail -5
	echo "--- pods.csv"; head -12 "$opt/pods.csv" 2>/dev/null
done

echo; echo "===== 4. Controller"
"$VENV/bin/python" -c "import kubernetes, ansible; print('kubernetes', kubernetes.__version__)" 2>&1
ls -la "$WORK/kubeconfig" 2>&1
grep server: "$WORK/kubeconfig" 2>&1
KUBECONFIG="$WORK/kubeconfig" "$VENV/bin/python" "$ROOT/analysis/k8s_tool.py" wait-ready && echo "API dapat dijangkau, node Ready" || echo "API TIDAK dapat dijangkau / node tidak Ready"

echo; echo "===== 5. Cluster"
k "get nodes -o wide"
echo; k "get pods -A -o wide"
echo; k "get jobs,pods,svc,deploy -n default -o wide"
echo; ssh_node "$CLIENT_IP" "helm list -A" 2>&1
bad=$(k "get pods -n default --no-headers" | awk '$3!="Completed" && $3!="Running"{print $1}' | head -1)
if [[ -n "$bad" ]]; then
	echo; echo "--- describe pod bermasalah: $bad"; k "describe pod -n default $bad" | tail -25
	echo "--- logs $bad"; k "logs -n default $bad" | tail -15
fi

echo; echo "===== 6. Uji jalur jaringan langsung (pod doktnet01 -> pod doktnet02)"
k "delete ns diag --ignore-not-found --wait=true" >/dev/null
k "create ns diag" >/dev/null
ssh_node "$CLIENT_IP" "kubectl apply -n diag -f -" <<EOF
apiVersion: v1
kind: Pod
metadata: {name: srv, labels: {app: diag}}
spec:
  nodeSelector: {kubernetes.io/hostname: doktnet02}
  containers: [{name: s, image: $TEST_IMAGE, command: ["iperf3","-s","-p","5201"]}]
---
apiVersion: v1
kind: Pod
metadata: {name: cli}
spec:
  nodeSelector: {kubernetes.io/hostname: doktnet01}
  containers: [{name: c, image: $TEST_IMAGE, command: ["sleep","3600"]}]
---
apiVersion: v1
kind: Service
metadata: {name: srv}
spec:
  type: NodePort
  selector: {app: diag}
  ports: [{port: 5201, targetPort: 5201, nodePort: 30999, protocol: TCP}]
EOF
k "wait -n diag --for=condition=Ready pod --all --timeout=180s"
k "get pods -n diag -o wide"
SRV_IP=$(k "get pod -n diag srv -o jsonpath='{.status.podIP}'")
echo "--- pod -> IP pod ($SRV_IP)";        k "exec -n diag cli -- iperf3 -c $SRV_IP -p 5201 -t 3" | tail -4
echo "--- pod -> NodePort ($SERVER_IP:30999, jalur penulis)"; k "exec -n diag cli -- iperf3 -c $SERVER_IP -p 30999 -t 3" | tail -4
k "delete ns diag --wait=false" >/dev/null
} > "$REPORT" 2>&1

cat "$REPORT"
echo
log "Laporan diagnosis: $REPORT (kirim isinya ke Claude)"
