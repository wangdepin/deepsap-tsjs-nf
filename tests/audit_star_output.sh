#!/bin/bash
# Audit the TSJS-scored STAR BAM against its own input.
#
# Run as a FILE, not as an inline `raca ssh "..."` string: the awk field references and
# regexes in here do not survive the layers of shell quoting that an inline command goes
# through, and a mangled awk does not necessarily fail -- it can print a plausible-looking
# number. That has already produced one wrong answer in this project (a fabricated record
# count from a mis-dispatched grep), so the check runs from disk where the text is exact.
set -uo pipefail

R=/scratch/project_2009297/deepsap-feasibility
IMG=$R/images/deepsap.sif
IN=$R/star_test/star_Aligned.sortedByCoord.out.bam
OUT=$R/nf_star_compat/results/deepsap/star/star

echo "=== inputs exist? ==="
ls -la "$IN" "$OUT" 2>&1

# Bind the project root explicitly rather than relying on whatever apptainer automounts.
SX="apptainer exec --bind $R:$R $IMG"

echo
echo "=== record counts ==="
printf 'input  total:      %s\n' "$($SX samtools view -c "$IN")"
printf 'output total:      %s\n' "$($SX samtools view -c "$OUT")"
printf 'input  secondary:  %s\n' "$($SX samtools view -c -f 0x100 "$IN")"
printf 'output secondary:  %s\n' "$($SX samtools view -c -f 0x100 "$OUT")"
printf 'input  spliced:    %s\n' "$($SX samtools view "$IN"  | cut -f6 | grep -c N)"
printf 'output spliced:    %s\n' "$($SX samtools view "$OUT" | cut -f6 | grep -c N)"

echo
echo "=== TSJS tags present in output? (js/jt/nj) ==="
printf 'records with js: %s\n' "$($SX samtools view "$OUT" | grep -c 'js:')"
printf 'records with jt: %s\n' "$($SX samtools view "$OUT" | grep -c 'jt:')"
printf 'records with nj: %s\n' "$($SX samtools view "$OUT" | grep -c 'nj:')"
printf 'input records with js (should be 0): %s\n' "$($SX samtools view "$IN" | grep -c 'js:')"

echo
echo "=== first 2 spliced output records (name, flag, pos, cigar, tags) ==="
$SX samtools view "$OUT" | grep 'N' | grep 'js:' | head -2 | cut -f1-6,12-

echo
echo "=== do any SECONDARY records carry js tags? ==="
printf 'secondary with js: %s\n' "$($SX samtools view -f 0x100 "$OUT" | grep -c 'js:')"

echo
echo "=== header sort order ==="
$SX samtools view -H "$OUT" | grep '^@HD'

echo
echo "=== junction score distribution (star_junctions.tsv) ==="
J=$R/nf_star_compat/results/deepsap/star/star_junctions.tsv
awk -F'\t' 'NR>1 {n++; s+=$4; if ($3=="Novel") nov++; else ann++;
                  if ($3!="Novel" && $4<50) annlow++}
            END {printf "junctions:            %d\n", n;
                 printf "mean score:           %.1f\n", s/n;
                 printf "annotated:            %d\n", ann;
                 printf "novel:                %d\n", nov;
                 printf "annotated below 50:   %d (%.1f%% of annotated)\n", annlow, 100*annlow/ann}' "$J"
