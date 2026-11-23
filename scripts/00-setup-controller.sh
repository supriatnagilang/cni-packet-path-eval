#!/usr/bin/env bash
# Menyiapkan mesin controller (yang menjalankan Ansible): virtualenv berisi Ansible,
# koleksi yang dipakai kode penulis (kubernetes.core, community.general, ansible.posix),
# pustaka Python 'kubernetes', dan pustaka analisis (pandas, matplotlib).
# Controller bisa salah satu node (doktnet01), host server Multipass, atau laptop
# yang bisa menjangkau kedua node lewat SSH dan port 6443.
source "$(dirname "$0")/lib.sh"

# ansible 10 = ansible-core 2.17: butuh Python 3.10–3.12, masih menerima sintaks
# when: "... {{ }}" milik penulis (2.19+ menolaknya), dan modul k8s-nya tidak crash
# di OpenSSL baru (core 2.16 memakai ssl.PROTOCOL_TLSv1 yang sudah tidak ada).
PY="${PYTHON:-}"
if [[ -z "$PY" ]]; then
	for c in python3.12 python3.11 python3.10 python3; do
		if command -v "$c" >/dev/null && "$c" -c 'import sys; exit(not ((3,10) <= sys.version_info[:2] <= (3,12)))'; then
			PY=$c; break
		fi
	done
fi
[[ -n "$PY" ]] || die "Butuh Python 3.10–3.12. Ubuntu 22.04/24.04 sudah ada; di macOS: brew install python@3.12"

if command -v apt-get >/dev/null && ! "$PY" -m venv --help >/dev/null 2>&1; then
	sudo apt-get update && sudo apt-get install -y python3-venv
fi

log "Membuat virtualenv di $VENV dengan $PY"
"$PY" -m venv "$VENV"
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet -r "$ROOT/analysis/requirements.txt"

[[ -f "$SSH_KEY" ]] || die "Kunci SSH $SSH_KEY tidak ada. Buat: ssh-keygen -t ed25519, lalu ssh-copy-id ke kedua node"

log "Cek SSH ke kedua node"
for ip in "$CLIENT_IP" "$SERVER_IP"; do
	ssh_node "$ip" 'sudo -n true' || die "SSH atau sudo tanpa password gagal ke $ip (lihat README, bagian Prasyarat)"
done

"$VENV/bin/ansible" --version | head -1
log "Selesai. Lanjutkan: scripts/01-build-work.sh"
