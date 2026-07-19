#!/bin/bash
#SBATCH --job-name=deepsap_star_bam
#SBATCH --account=project_2009297
#SBATCH --partition=small
#SBATCH --cpus-per-task=8
#SBATCH --mem=16G
#SBATCH --time=00:30:00
#SBATCH --output=/scratch/project_2009297/deepsap-feasibility/logs/star_bam_%j.out
#SBATCH --error=/scratch/project_2009297/deepsap-feasibility/logs/star_bam_%j.err
#
# Produce a REAL STAR-aligned BAM, so the deepsap-tsjs-nf pipeline can be tested against the
# kind of input it is actually aimed at.
#
# Why this exists: every verified DeepSAP --sam invocation in this project so far fed back a
# GSNAP BAM that DeepSAP itself had produced moments earlier. That BAM is in read order,
# single-alignment-per-read, and carries GSNAP's own tags. A STAR BAM differs on all three
# counts -- coordinate-sorted, up to 20 secondary alignments per read by default, different
# optional tags -- and NONE of those differences has been tested against this container.
# Assuming they are immaterial is exactly the kind of unchecked-instrument claim this project
# has been burned by repeatedly, so this builds the real thing on the same reads and the same
# reference, and the scoring result is then compared against the known-good GSNAP result.
#
# P. falciparum stands in for human/mouse here on purpose: it exercises the same code path at
# a size that fits a 30-minute CPU allocation. It does NOT test human-scale memory or runtime.

set -euo pipefail

ROOT=/scratch/project_2009297/deepsap-feasibility
TESTDATA=$ROOT/testdata/malaria_short_pe
OUT=$ROOT/star_test
FASTA=$TESTDATA/Plasmodium_falciparum.ASM276v2.dna.toplevel.fa
GTF=$TESTDATA/Plasmodium_falciparum.ASM276v2.60.gtf

mkdir -p "$OUT"
cd "$OUT"

# `set -u` must be lifted across CSC's own env script: /appl/profile/zz-csc-env.sh line 67
# dereferences LC_CTYPE unconditionally, so under `set -u` sourcing it aborts the job at
# 00:00:00 with "LC_CTYPE: unbound variable" and no other output. Observed on job 35520844.
set +u
source /appl/profile/zz-csc-env.sh
module load star/2.7.11b
set -u
STAR --version

# --genomeSAindexNbases must be scaled DOWN for small genomes: STAR's own manual gives
# min(14, log2(genomeLength)/2 - 1). For 23,681,631 bp that is 11. Leaving the default 14
# does not error -- it silently produces a bad index and a poor alignment rate, which would
# then look like a DeepSAP problem rather than an indexing problem.
if [ ! -s "$OUT/star_idx/SA" ]; then
    mkdir -p "$OUT/star_idx"
    STAR --runMode genomeGenerate \
         --runThreadN "${SLURM_CPUS_PER_TASK:-8}" \
         --genomeDir "$OUT/star_idx" \
         --genomeFastaFiles "$FASTA" \
         --sjdbGTFfile "$GTF" \
         --sjdbOverhang 149 \
         --genomeSAindexNbases 11 \
         --outFileNamePrefix "$OUT/idx_"
fi

# Coordinate-sorted output, which is STAR's usual setting and the one that differs most from
# the read-ordered GSNAP BAM this pipeline was verified against.
STAR --runMode alignReads \
     --runThreadN "${SLURM_CPUS_PER_TASK:-8}" \
     --genomeDir "$OUT/star_idx" \
     --readFilesIn "$TESTDATA/SRR14793977_10K_1.fastq.gz" "$TESTDATA/SRR14793977_10K_2.fastq.gz" \
     --readFilesCommand zcat \
     --outSAMtype BAM SortedByCoordinate \
     --outFileNamePrefix "$OUT/star_"

BAM=$OUT/star_Aligned.sortedByCoord.out.bam
[ -s "$BAM" ] || { echo "FATAL: STAR produced no BAM" >&2; exit 1; }

set +u
module purge
module load biokit 2>/dev/null || true
set -u

echo "=== STAR BAM summary ==="
samtools quickcheck "$BAM" && echo "quickcheck: OK"
echo "records:           $(samtools view -c "$BAM")"
echo "primary:           $(samtools view -c -F 0x900 "$BAM")"
echo "secondary(0x100):  $(samtools view -c -f 0x100 "$BAM")"
echo "supplementary:     $(samtools view -c -f 0x800 "$BAM")"
echo "spliced (N CIGAR): $(samtools view "$BAM" | awk '$6 ~ /N/' | wc -l)"
echo "sort order (@HD):  $(samtools view -H "$BAM" | grep '^@HD' || echo NONE)"
echo "contigs (first 3): $(samtools view -H "$BAM" | awk '/^@SQ/{print $2}' | head -3 | tr '\n' ' ')"
echo "tags on record 1:  $(samtools view "$BAM" | head -1 | cut -f12-)"

echo "STAR_BAM=$BAM"
