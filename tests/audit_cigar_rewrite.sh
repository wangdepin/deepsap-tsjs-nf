#!/bin/bash
# Does DeepSAP REWRITE alignments, or only annotate them?
#
# The STAR run went in with 2203 N-CIGAR (spliced) records and came out with 1171, while the
# total record count stayed at exactly 19966. Something changed CIGARs. This pairs input and
# output records by (qname, flag, pos) and prints the ones whose CIGAR differs, so the answer
# comes from the actual bytes rather than from a plausible story about what a junction filter
# "would" do.
set -uo pipefail

R=/scratch/project_2009297/deepsap-feasibility
IMG=$R/images/deepsap.sif
IN=$R/star_test/star_Aligned.sortedByCoord.out.bam
OUT=$R/nf_star_compat/results/deepsap/star/star
SX="apptainer exec --bind $R:$R $IMG"

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

$SX samtools view "$IN"  | awk -F'\t' '{print $1"|"$2"|"$4"\t"$6}' | sort > "$W/in.tsv"
$SX samtools view "$OUT" | awk -F'\t' '{print $1"|"$2"|"$4"\t"$6}' | sort > "$W/out.tsv"

echo "=== key counts (qname|flag|pos) ==="
printf 'input keys:  %s (unique %s)\n' "$(wc -l < "$W/in.tsv")"  "$(cut -f1 "$W/in.tsv"  | sort -u | wc -l)"
printf 'output keys: %s (unique %s)\n' "$(wc -l < "$W/out.tsv")" "$(cut -f1 "$W/out.tsv" | sort -u | wc -l)"

join -t'	' "$W/in.tsv" "$W/out.tsv" > "$W/joined.tsv"
printf 'joined on key: %s\n' "$(wc -l < "$W/joined.tsv")"

echo
echo "=== CIGAR changed? ==="
awk -F'\t' '$2 != $3' "$W/joined.tsv" > "$W/changed.tsv"
printf 'records whose CIGAR changed: %s\n' "$(wc -l < "$W/changed.tsv")"

echo
echo "=== of those, how many lost an N (spliced -> unspliced)? ==="
printf 'N in input, none in output: %s\n' "$(awk -F'\t' '$2 ~ /N/ && $3 !~ /N/' "$W/changed.tsv" | wc -l)"
printf 'no N in input, N in output: %s\n' "$(awk -F'\t' '$2 !~ /N/ && $3 ~ /N/' "$W/changed.tsv" | wc -l)"
printf 'N in both, but different:   %s\n' "$(awk -F'\t' '$2 ~ /N/ && $3 ~ /N/'  "$W/changed.tsv" | wc -l)"

echo
echo "=== 5 examples: key, INPUT cigar -> OUTPUT cigar ==="
head -5 "$W/changed.tsv" | awk -F'\t' '{printf "%-28s %-24s ->  %s\n", $1, $2, $3}'

echo
echo "=== does the read SEQUENCE change too, or only the CIGAR? ==="
$SX samtools view "$IN"  | awk -F'\t' '{print $1"|"$2"|"$4"\t"$10}' | sort > "$W/inseq.tsv"
$SX samtools view "$OUT" | awk -F'\t' '{print $1"|"$2"|"$4"\t"$10}' | sort > "$W/outseq.tsv"
printf 'records whose SEQ differs: %s\n' "$(join -t'	' "$W/inseq.tsv" "$W/outseq.tsv" | awk -F'\t' '$2 != $3' | wc -l)"
