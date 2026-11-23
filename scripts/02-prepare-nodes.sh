#!/usr/bin/env bash
# Menyiapkan kedua node dengan playbook penulis (plays/1..5) ditambah persiapan
# replikasi (plays/0-prepare.yml, plays/5b-containerd.yml), lalu reboot.
source "$(dirname "$0")/lib.sh"
activate

[[ -d "$WORK" ]] || die "Jalankan dulu scripts/01-build-work.sh"

for p in 0-prepare 1-hosts 2-packages 3-firewall 4-kernel 5-docker 5b-containerd reboot; do
	log "Playbook plays/$p.yml"
	play "plays/$p.yml"
done
log "Node siap. Lanjutkan: scripts/03-run-os-baseline.sh"
