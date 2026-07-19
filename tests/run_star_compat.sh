#!/bin/bash
#
# First REAL run of deepsap-tsjs-nf: two samples, one Nextflow invocation, GPU via SLURM.
#
#   star  -- a genuine STAR BAM (coordinate-sorted, 796 secondary alignments, 2203 spliced
#            records). This is the input class the pipeline is actually aimed at and the one
#            NOTHING in this project has ever fed to DeepSAP.
#   gsnap -- the GSNAP BAM from canary 35519462, whose TSJS output is already known byte-for-
#            byte from job 35520334. It rides along as a CONTROL: if it reproduces its known
#            result, then any difference in the STAR sample is attributable to the STAR BAM
#            rather than to the pipeline's own container invocation.
#
# Two samples in one run also exercises the batch path (concurrent tasks, each with its own
# private /tmp/83 copy), which is how this will be used on a real batch of BAMs.
#
set -euo pipefail

ROOT=/scratch/project_2009297/deepsap-feasibility
RUN=$ROOT/nf_star_compat
PIPE=$ROOT/code/deepsap-tsjs-nf
TESTDATA=$ROOT/testdata/malaria_short_pe

mkdir -p "$RUN"
cd "$RUN"

cat > samplesheet.csv <<'CSV'
sample,bam
star,/scratch/project_2009297/deepsap-feasibility/star_test/star_Aligned.sortedByCoord.out.bam
gsnap,/scratch/project_2009297/deepsap-feasibility/outputdir/run_35519462/test_run_10K_default_gsnap.bam
CSV

set +u
source /appl/profile/zz-csc-env.sh
module load nextflow
set -u

export NXF_HOME=$ROOT/.nxf_home
export APPTAINER_TMPDIR=$ROOT/.apptainer_tmp
mkdir -p "$NXF_HOME" "$APPTAINER_TMPDIR"

nextflow run "$PIPE/main.nf" \
    -profile puhti \
    -resume \
    --input samplesheet.csv \
    --fasta "$TESTDATA/Plasmodium_falciparum.ASM276v2.dna.toplevel.fa" \
    --gtf "$TESTDATA/Plasmodium_falciparum.ASM276v2.60.gtf" \
    --ctmp "$ROOT/ctmp" \
    --outdir "$RUN/results"
