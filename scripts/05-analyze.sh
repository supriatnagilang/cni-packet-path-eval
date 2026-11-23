#!/usr/bin/env bash
# Log ekstensi -> CSV -> grafik (per lapisan + per varian arsitektur jalur)
source "$(dirname "$0")/lib.sh"
activate
python "$ROOT/analysis/ekstensi.py"
