#!/bin/bash
# Exercise all THREE ways the FASTA index gets resolved.
#
# The real cluster run only ever took branch 3 (build it), because the malaria FASTA has no
# .fai sibling. Branches 1 and 2 are the ones a human/mouse run will actually hit -- shared
# reference stores essentially always ship GRCh38.fa.fai beside the FASTA -- so the common
# production path is the untested one. That asymmetry is worth closing before a real batch.
#
# Stub runs only: this tests channel wiring and process skipping, not DeepSAP.
set -uo pipefail

R=/scratch/project_2009297/deepsap-feasibility
PIPE=$R/code/deepsap-tsjs-nf
TESTDATA=$R/testdata/malaria_short_pe
W=$R/fai_branch_test

set +u
source /appl/profile/zz-csc-env.sh
module load nextflow
set -u

export NXF_HOME=$R/.nxf_home
export APPTAINER_TMPDIR=$R/.apptainer_tmp

rm -rf "$W"; mkdir -p "$W/refdir"
cd "$W"

# A reference directory that DOES carry a .fai sibling, the normal production shape.
ln -s "$TESTDATA/Plasmodium_falciparum.ASM276v2.dna.toplevel.fa" "$W/refdir/genome.fa"
ln -s "$TESTDATA/Plasmodium_falciparum.ASM276v2.60.gtf"          "$W/refdir/genes.gtf"
apptainer exec --bind "$R:$R" "$R/images/deepsap.sif" \
    samtools faidx "$W/refdir/genome.fa"
ls -la "$W/refdir/"

cat > samplesheet.csv <<CSV
sample,bam
s1,$R/outputdir/run_35519462/test_run_10K_default_gsnap.bam
CSV

cat > cpu.config <<'CFG'
process {
  withLabel:process_gpu { cpus = 2
 memory = 4.GB }
  withLabel:process_low { cpus = 1
 memory = 2.GB }
}
CFG

# Which processes ran is read from -with-trace, NOT from the console.
# Nextflow ABBREVIATES process names in its progress display -- PREPARE_REFERENCE renders as
# "DEE...EFERENCE" -- so grepping the console for the full name silently never matches and
# every case looks like it skipped the build. That is a test whose pattern cannot match what
# the code emits: the same defect class as the extension-based format guess and the join on a
# key the code changes. The trace file carries exact, untruncated process names.
run_case () {
    local name="$1"; shift
    echo
    echo "############ CASE: $name ############"
    rm -f "$W/trace_$name.txt"
    nextflow run "$PIPE/main.nf" -stub-run -profile standard -c cpu.config \
        -with-trace "$W/trace_$name.txt" \
        --input samplesheet.csv \
        --gtf "$W/refdir/genes.gtf" \
        --deepsap_sif "$R/images/deepsap.sif" \
        --ctmp "$R/ctmp" \
        --outdir "$W/out_$name" \
        "$@" > "$W/log_$name.txt" 2>&1
    local rc=$?
    echo "exit code: $rc"
    if [ -s "$W/trace_$name.txt" ]; then
        echo "processes that ran:"
        awk -F'\t' 'NR>1 {print "  - "$4"  ("$5")"}' "$W/trace_$name.txt" | sort -u
        if grep -q 'PREPARE_REFERENCE' "$W/trace_$name.txt"; then
            echo "PREPARE_REFERENCE: RAN"
        else
            echo "PREPARE_REFERENCE: skipped"
        fi
    else
        echo "NO TRACE FILE -- run did not start. Last lines:"
        tail -5 "$W/log_$name.txt"
    fi
    if [ -d "$W/out_$name/deepsap/s1" ]; then
        echo "published -> $(ls "$W/out_$name/deepsap/s1" | tr '\n' ' ')"
    else
        echo "published -> NOTHING"
    fi
}

# 1. sibling <fasta>.fai present  -> PREPARE_REFERENCE must NOT appear
run_case sibling --fasta "$W/refdir/genome.fa"

# 2. explicit --fai (pointing at a DIFFERENTLY NAMED index)  -> also must NOT appear
cp "$W/refdir/genome.fa.fai" "$W/elsewhere.fai"
run_case explicit --fasta "$W/refdir/genome.fa" --fai "$W/elsewhere.fai"

# 3. no index anywhere -> PREPARE_REFERENCE MUST appear (the branch the cluster run took)
run_case build --fasta "$TESTDATA/Plasmodium_falciparum.ASM276v2.dna.toplevel.fa"

echo
echo "############ EXPECTATION ############"
echo "sibling  : no PREPARE_REFERENCE line, s1 published"
echo "explicit : no PREPARE_REFERENCE line, s1 published"
echo "build    : PREPARE_REFERENCE line PRESENT, s1 published"
