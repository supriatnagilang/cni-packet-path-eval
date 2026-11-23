#!/usr/bin/env bash
# Membuat work/ = salinan kode penulis (upstream/, tidak pernah diubah) + tambalan
# minimal agar bisa berjalan di testbed lain. Semua perubahan dicatat di
# work/PERUBAHAN.diff (diff terhadap upstream) untuk lampiran laporan.
source "$(dirname "$0")/lib.sh"

[[ -d "$UPSTREAM/.git" ]] || git clone https://github.com/vEddYcro/cni-performance-testing.git "$UPSTREAM"
git -C "$UPSTREAM" checkout -q "$UPSTREAM_COMMIT"
[[ -z "$(git -C "$UPSTREAM" status --porcelain)" ]] || die "upstream/ berubah. Jangan edit upstream/; kembalikan dengan: git -C upstream checkout ."

KUBECONFIG_PATH="$WORK/kubeconfig"
log "Menyalin upstream -> work"
rm -rf "$WORK"
mkdir -p "$WORK"
(cd "$UPSTREAM" && git archive HEAD) | tar -x -C "$WORK"
# Kubeconfig milik cluster penulis ikut ter-commit di repo mereka; tidak dipakai.
rm -f "$WORK/kubeconfig"

log "Menerapkan overlay (file tambahan/pengganti)"
cp -R "$ROOT/overlay/." "$WORK/"

log "Mengganti nilai yang di-hardcode penulis"
# 1) user 'matej' -> SSH_USER ('matejbasic/...' nama image tidak ikut berubah)
# 2) NIC uji 'eno2' -> TEST_NIC
# 3) path kubeconfig relatif -> path absolut
find "$WORK" -type f \( -name '*.yml' -o -name '*.cfg' -o -name '*.sh' \) -print0 | xargs -0 perl -pi -e "
	s/\\bmatej\\b/$SSH_USER/g;
	s/\\beno2\\b/$TEST_NIC/g;
	s#\"\\.\\./\\.\\./kubeconfig\"#\"$KUBECONFIG_PATH\"#g;
	s#\"\\.\\./kubeconfig\"#\"$KUBECONFIG_PATH\"#g;
"
# 4) Bug: server iperf3 mode OS mendengar di port 8080, padahal klien memakai 30080.
#    Juga memakai -D (daemon) karena 'nohup ... &' bisa ikut mati bersama sesi Ansible.
perl -pi -e 's/nohup iperf3 -s -p 8080 &/iperf3 -s -p 30080 -D/' "$WORK/test_configuration/run_iperf_server.yml"
# 5) 'netserver -D' berarti TIDAK daemon; paket netperf Ubuntu sudah menjalankan netserver
#    di port 12865, jadi cukup pastikan berjalan. Task ini dijalankan bersamaan untuk
#    dua host (play 'hosts: all' + delegate_to doktnet02): yang kalah balapan gagal bind,
#    jadi sukses = netserver akhirnya berjalan.
perl -pi -e 's/nohup netserver -D &/netserver 2>\/dev\/null; sleep 1; pgrep -x netserver/' "$WORK/test_configuration/run_netperf_server.yml"
# 6) Fetch kubeconfig ke path absolut
perl -pi -e "s#dest: \"\\.\\./kubeconfig\"#dest: \"$KUBECONFIG_PATH\"#" "$WORK/plays/7-kubeconfig.yml"

log "Menulis inventory, ansible.cfg, group_vars"
cat > "$WORK/inventory" <<EOF
[k8s-worker-nodes]
doktnet02	ansible_ssh_host=$SERVER_IP local_host_id=2 remote_host_id=1

[k8s-control-nodes]
doktnet01	ansible_ssh_host=$CLIENT_IP local_host_id=1 remote_host_id=2
EOF

cat > "$WORK/ansible.cfg" <<EOF
[defaults]
inventory = ./inventory
forks = 5
gathering = smart
host_key_checking = False
remote_user = $SSH_USER
private_key_file = $SSH_KEY
interpreter_python = auto_silent
deprecation_warnings = False
timeout = 30

[privilege_escalation]
become = True
become_method = sudo
become_user = root
become_ask_pass = False
EOF

mkdir -p "$WORK/group_vars"
cat > "$WORK/group_vars/all.yml" <<EOF
# Dibuat dari config.env oleh scripts/01-build-work.sh
k8s_minor: "$K8S_MINOR"
pod_cidr: "$POD_CIDR"
antrea_version: "$ANTREA_VERSION"
calico_version: "$CALICO_VERSION"
cilium_version: "$CILIUM_VERSION"
cilium_tunnel: "$CILIUM_TUNNEL"
flannel_version: "$FLANNEL_VERSION"
test_image: "$TEST_IMAGE"
EOF
# Task k8s penulis memakai delegate_to: localhost. Pastikan localhost memakai Python
# virtualenv (berisi pustaka 'kubernetes'), bukan /usr/bin/python3 hasil discovery.
mkdir -p "$WORK/host_vars"
cat > "$WORK/host_vars/localhost.yml" <<EOF
ansible_connection: local
ansible_python_interpreter: "$VENV/bin/python"
EOF

log "Mencatat diff terhadap upstream -> work/PERUBAHAN.diff"
diff -ruN --exclude=PERUBAHAN.diff "$UPSTREAM" "$WORK" -x .git > "$WORK/PERUBAHAN.diff" || true
log "Selesai: $(grep -c '^diff ' "$WORK/PERUBAHAN.diff") file berbeda dari upstream. Lanjutkan: scripts/02-prepare-nodes.sh"
