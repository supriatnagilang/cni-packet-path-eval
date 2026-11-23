#!/bin/sh
# Sampler CPU/RAM node per detik (+ energi Intel RAPL bila mesin fisik).
# Kolom: cpu-busy cpu-user cpu-system cpu-softirq cpu-steal memory-used(MB)
#   cpu-busy = 100 - idle - iowait (termasuk irq/softirq, tempat sebagian besar
#   pemrosesan paket jaringan terjadi).
# Pemakaian: sudo sh sample.sh <durasi_detik>
DUR=${1:-10}
RAPL=/sys/class/powercap/intel-rapl:0

read_cpu() { awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8,$9}' /proc/stat; } # user nice system idle iowait irq softirq steal
mem_used() { awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{printf "%d", (t-a)/1024}' /proc/meminfo; }

e0=$(cat "$RAPL/energy_uj" 2>/dev/null)
echo "cpu-busy cpu-user cpu-system cpu-softirq cpu-steal memory-used"
prev=$(read_cpu)
i=0
while [ "$i" -lt "$DUR" ]; do
	sleep 1
	cur=$(read_cpu)
	echo "$prev $cur $(mem_used)" | awk '{
		tot = 0
		for (k = 1; k <= 8; k++) { d[k] = $(k + 8) - $k; tot += d[k] }
		if (tot == 0) tot = 1
		printf "%.2f %.2f %.2f %.2f %.2f %d\n", 100*(tot-d[4]-d[5])/tot, 100*(d[1]+d[2])/tot, 100*(d[3]+d[6])/tot, 100*d[7]/tot, 100*d[8]/tot, $17
	}'
	prev=$cur
	i=$((i + 1))
done

e1=$(cat "$RAPL/energy_uj" 2>/dev/null)
if [ -n "$e0" ] && [ -n "$e1" ]; then
	delta=$((e1 - e0))
	[ "$delta" -lt 0 ] && delta=$((delta + $(cat "$RAPL/max_energy_range_uj")))
	echo "# energy_uj $delta seconds $DUR"
fi
