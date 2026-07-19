#!/bin/bash
# Where did ~1000 spliced records go?
#
# Two earlier measurements disagree:
#   (a) N-CIGAR record count: 2203 in -> 1171 out, a drop of 1032;
#   (b) a (qname,flag,pos) join: only 8 records lost their N.
# Both cannot be right. (b) used `join` on a key with 207 duplicates, so it silently formed a
# cross product and dropped ~500 non-matching keys -- it is the suspect one. This script
# re-derives everything without join, and cross-checks each count two independent ways, so
# the answer does not rest on a single line of awk.
set -uo pipefail

R=/scratch/project_2009297/deepsap-feasibility
IMG=$R/images/deepsap.sif
IN=$R/star_test/star_Aligned.sortedByCoord.out.bam
OUT=$R/nf_star_compat/results/deepsap/star/star
SX="apptainer exec --bind $R:$R $IMG"

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

$SX samtools view "$IN"  > "$W/in.sam"
$SX samtools view "$OUT" > "$W/out.sam"

echo "=== spliced counts, two independent methods ==="
for f in in out; do
    a=$(cut -f6 "$W/$f.sam" | grep -c 'N')
    b=$(awk -F'\t' 'index($6,"N")>0 {n++} END {print n+0}' "$W/$f.sam")
    printf '%-4s grep=%s  awk=%s  %s\n' "$f" "$a" "$b" "$([ "$a" = "$b" ] && echo AGREE || echo DISAGREE)"
done

echo
echo "=== total N operations (not records) ==="
for f in in out; do
    printf '%-4s N-ops: %s\n' "$f" \
      "$(cut -f6 "$W/$f.sam" | grep -o 'N' | wc -l)"
done

echo
echo "=== reads (qnames) with at least one spliced alignment ==="
cut -f1,6 "$W/in.sam"  | awk -F'\t' 'index($2,"N")>0 {print $1}' | sort -u > "$W/in.qn"
cut -f1,6 "$W/out.sam" | awk -F'\t' 'index($2,"N")>0 {print $1}' | sort -u > "$W/out.qn"
printf 'input  spliced qnames: %s\n' "$(wc -l < "$W/in.qn")"
printf 'output spliced qnames: %s\n' "$(wc -l < "$W/out.qn")"
printf 'lost   (in only):      %s\n' "$(comm -23 "$W/in.qn" "$W/out.qn" | wc -l)"
printf 'gained (out only):     %s\n' "$(comm -13 "$W/in.qn" "$W/out.qn" | wc -l)"

echo
echo "=== 3 reads that were spliced on input and are not on output ==="
for q in $(comm -23 "$W/in.qn" "$W/out.qn" | head -3); do
    echo "--- $q"
    echo "  IN : $(awk -F'\t' -v q="$q" '$1==q {printf "flag=%s pos=%s cigar=%s | ", $2, $4, $6}' "$W/in.sam")"
    echo "  OUT: $(awk -F'\t' -v q="$q" '$1==q {printf "flag=%s pos=%s cigar=%s | ", $2, $4, $6}' "$W/out.sam")"
done

echo
echo "=== is the whole delta explained by SECONDARY alignments? ==="
for f in in out; do
    p=$(awk -F'\t' 'and($2,256)==0 && index($6,"N")>0 {n++} END {print n+0}' "$W/$f.sam")
    s=$(awk -F'\t' 'and($2,256)!=0 && index($6,"N")>0 {n++} END {print n+0}' "$W/$f.sam")
    printf '%-4s spliced primary=%s  spliced secondary=%s\n' "$f" "$p" "$s"
done
