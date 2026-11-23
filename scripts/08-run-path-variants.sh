#!/usr/bin/env bash
# [MODIFIKASI] Menjalankan semua varian arsitektur jalur secara berurutan:
#   per varian: 07-cluster.sh (reset -> kubeadm -> CNI) -> 06-run-ekstensi.sh (L0..L4)
# Varian yang sudah punya results/ekstensi/cni-<v>/.done dilewati (aman diulang
# setelah gagal di tengah jalan). Hapus .done untuk mengukur ulang.
# Pemakaian: ./scripts/08-run-path-variants.sh [varian ...]   (bawaan: EXT_PATH_VARIANTS)
source "$(dirname "$0")/lib.sh"

variants=("$@")
[[ ${#variants[@]} -gt 0 ]] || read -r -a variants <<< "$EXT_PATH_VARIANTS"
log "Varian: ${variants[*]} | $EXT_ITERATIONS iterasi × ${EXT_DURATION}s per tes"

failed=()
for v in "${variants[@]}"; do
	if [[ -f "$RESULTS/ekstensi/cni-$v/.done" ]]; then
		log "Lewati $v (sudah .done)"; continue
	fi
	# Subshell: die() di skrip anak tidak menghentikan varian berikutnya
	if ( "$ROOT/scripts/07-cluster.sh" "$v" && "$ROOT/scripts/06-run-ekstensi.sh" "$v" ); then
		log "Selesai: $v"
	else
		warn "Varian $v gagal; lanjut ke varian berikutnya"; failed+=("$v")
	fi
done

"$ROOT/scripts/05-analyze.sh"
[[ ${#failed[@]} -eq 0 ]] || die "Gagal: ${failed[*]} (lihat results/raw/cni-<v>/deploy.log dan results/ekstensi/cni-<v>/env/path-mode.txt)"
log "Semua varian selesai. Ringkasan: results/summary/ekstensi_path_*.csv"
