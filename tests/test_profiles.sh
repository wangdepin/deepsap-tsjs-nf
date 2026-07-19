#!/bin/bash
# Verify the profile restructure: engines, generic slurm, and that -profile puhti still
# resolves to exactly what it did before.
#
# The important check is NOT "does it run" but "does it generate the right sbatch flags".
# A profile that silently drops --account or --gres produces jobs that never schedule, and
# `nextflow run` on a working cluster hides that because the site defaults happen to be right.
# So this reads the RESOLVED CONFIG (`nextflow config`) rather than trusting a green run.
set -uo pipefail

R=/scratch/project_2009297/deepsap-feasibility
PIPE=$R/code/deepsap-tsjs-nf

set +u
source /appl/profile/zz-csc-env.sh
module load nextflow
set -u
export NXF_HOME=$R/.nxf_home

cd "$PIPE"

show () {
    local label="$1"; shift
    echo
    echo "############ $label ############"
    nextflow config -profile "$@" 2>&1 | grep -E \
        "executor|queue|clusterOptions|apptainer|singularity|enabled|autoMounts" \
        | grep -vE "^\s*$" | sed 's/^/  /' | head -25
}

show "puhti (regression: must be unchanged)"        puhti
show "slurm + singularity (generic site)"           slurm,singularity
show "slurm + apptainer"                            slurm,apptainer
show "standard (local)"                             standard

echo
echo "############ engine selection, explicit ############"
# `nextflow config` prints NESTED BLOCKS (apptainer {\n enabled = true), not dotted keys, so
# grepping for 'apptainer.enabled = true' matches nothing and every profile reads as "off" --
# which is what the first version of this test did. Flatten with -flat before asking.
for p in apptainer singularity puhti standard slurm; do
    cfg=$(nextflow config -flat -profile "$p" 2>/dev/null)
    a=$(echo "$cfg" | grep -c 'apptainer.enabled = true')
    s=$(echo "$cfg" | grep -c 'singularity.enabled = true')
    printf '  %-12s apptainer=%s singularity=%s\n' "$p" "$a" "$s"
done

echo
echo "############ RESOLVED sbatch headers (the thing that actually matters) ############"
# clusterOptions is a closure, so `nextflow config` shows it unevaluated and proves nothing.
# The only honest check is the #SBATCH lines Nextflow actually generates. Submitting a stub
# to gputest/test costs seconds and reads them from .command.run.
hdr_check () {
    local label="$1"; shift
    local d="$R/profile_hdr_$label"
    rm -rf "$d"; mkdir -p "$d"; cd "$d"
    printf 'sample,bam\ns1,%s\n' "$R/outputdir/run_35519462/test_run_10K_default_gsnap.bam" > ss.csv
    # Puhti's `test` and `gputest` partitions both cap at 15 min, while process_low asks for
    # 1 h and process_gpu for 2 h. Without this override sbatch rejects the FIRST task
    # ("Requested time limit is invalid") and the run aborts before DEEPSAP_TSJS is ever
    # created -- so the GPU header, the only one carrying --gres, never gets generated and the
    # check silently passes on the CPU tasks alone. Short times here are purely so the quick
    # partitions accept a stub; they say nothing about real resource needs.
    printf 'process {\n  withLabel:process_gpu { time = 10.min }\n  withLabel:process_low { time = 10.min }\n}\n' > short.config
    nextflow run "$PIPE/main.nf" -stub-run -c short.config "$@" \
        --input ss.csv \
        --fasta "$R/testdata/malaria_short_pe/Plasmodium_falciparum.ASM276v2.dna.toplevel.fa" \
        --gtf   "$R/testdata/malaria_short_pe/Plasmodium_falciparum.ASM276v2.60.gtf" \
        --deepsap_sif "$R/images/deepsap.sif" --ctmp "$R/ctmp" \
        --outdir "$d/out" > "$d/log.txt" 2>&1
    local rc=$?
    echo
    echo "  --- $label (exit $rc) ---"
    local any=0
    # Show BOTH a CPU-label and the GPU-label task: --gres only ever appears on the GPU one,
    # so grabbing just the first .command.run (which is whichever task started first) can
    # report a clean header while the GPU flags are wrong.
    for f in $(find "$d/work" -name .command.run 2>/dev/null); do
        local proc
        proc=$(grep -m1 '^#SBATCH -J' "$f" | sed 's/.*nf-DEEPSAP_TSJS_WF_//')
        echo "    [$proc]"
        grep '^#SBATCH' "$f" | grep -E '\-p |account|gres|gpu' | sed 's/^/      /'
        any=1
        if grep '^#SBATCH' "$f" | grep -qw 'null'; then
            echo "      *** FAIL: literal 'null' reached an sbatch flag ***"
        fi
    done
    [ "$any" = 1 ] && echo "    ok: no literal 'null' in any sbatch flag" || {
        echo "    no .command.run generated; last lines:"; tail -6 "$d/log.txt" | sed 's/^/      /'; }
}

# Assert against the GPU task's header specifically -- it is the only one carrying --gres.
# `want` = must be present, `notwant` = must be absent. Returns non-zero on violation so the
# script's own exit code means something.
FAILURES=0
assert_gpu_header () {
    local label="$1" mode="$2" needle="$3"
    local d="$R/profile_hdr_$label" f hdr
    # Anchor on the GPU job's own -J line. `grep -l DEEPSAP_TSJS` matches EVERY task, because
    # all process names begin with the workflow name DEEPSAP_TSJS_WF -- so `head -1` returned
    # whichever file find happened to list first, and the assertion passed or failed depending
    # on directory hash order. It passed one run and failed the next on identical code.
    f=$(grep -l '^#SBATCH -J nf-DEEPSAP_TSJS_WF_DEEPSAP_TSJS' $(find "$d/work" -name .command.run 2>/dev/null) 2>/dev/null | head -1)
    if [ -z "$f" ]; then
        echo "  ASSERT $label: NO GPU HEADER GENERATED -- cannot check '$needle'"
        FAILURES=$((FAILURES+1)); return
    fi
    hdr=$(grep '^#SBATCH' "$f")
    if [ "$mode" = want ]; then
        if grep -q -- "$needle" <<<"$hdr"; then echo "  ASSERT $label: contains '$needle'  OK"
        else echo "  ASSERT $label: MISSING '$needle'  FAIL"; FAILURES=$((FAILURES+1)); fi
    else
        if grep -q -- "$needle" <<<"$hdr"; then echo "  ASSERT $label: unexpectedly contains '$needle'  FAIL"; FAILURES=$((FAILURES+1))
        else echo "  ASSERT $label: absent '$needle'  OK"; fi
    fi
}

# ORDER MATTERS: the assert_gpu_header calls live AFTER the hdr_check calls that produce the
# work directories they read. An earlier version of this file called them first, so they
# inspected the PREVIOUS invocation's leftover directories (hdr_check rm -rf's at its start)
# and reported "ALL PROFILE ASSERTIONS PASSED" without testing the current run at all.

# All params supplied -- the normal case on a new cluster.
hdr_check populated -profile slurm,apptainer \
    --account project_2009297 --gpu_partition gputest --cpu_partition test --gpu_gres 'gpu:v100:1'

# gpu_gres disabled via the literal string 'null' -- the spelling a user is most likely to
# reach for, and the one that would silently emit `--gres=null` without the guard in
# conf/slurm.config. Must produce a GPU header with NO --gres line at all.
hdr_check gres_null -profile slurm,apptainer \
    --account project_2009297 --gpu_partition gputest --cpu_partition test --gpu_gres null

# No account at all -- clusters without accounting. Must emit no --account line.
hdr_check no_account -profile slurm,apptainer \
    --gpu_partition gputest --cpu_partition test --gpu_gres 'gpu:v100:1'

# -profile slurm with NO engine named: must still get apptainer (the default lives outside the
# profiles block for exactly this reason) and must emit the `module load` line when
# --container_module is set. Uses a real Puhti module so the load actually succeeds; the point
# is that the line reaches .command.run at all, not which module it is.
hdr_check default_engine -profile slurm \
    --account project_2009297 --gpu_partition gputest --cpu_partition test \
    --gpu_gres 'gpu:v100:1' --container_module 'biokit'

echo
echo "############ default engine + container_module ############"
_d=$R/profile_hdr_default_engine
_f=$(grep -l '^#SBATCH -J nf-DEEPSAP_TSJS_WF_DEEPSAP_TSJS' $(find "$_d/work" -name .command.run 2>/dev/null) 2>/dev/null | head -1)
if [ -n "$_f" ]; then
    # Match the CALL SITE `nxf_module_load biokit`, not the string 'module load'. Nextflow's
    # .command.run always DEFINES a helper containing the literal `module load $new_module`
    # around line 35, whether or not any module was requested -- so grepping 'module load'
    # reports OK even when the directive was never set. Same for the engine: `apptainer exec`
    # appears inside the nxf_launch() definition, so a line-number comparison against the
    # definitions says nothing about execution order. Both are anchored to real invocations.
    if grep -qE '^\s*nxf_module_load [a-zA-Z]' "$_f"; then
        echo "  module call: $(grep -m1 -E '^\s*nxf_module_load [a-zA-Z]' "$_f" | sed 's/^ *//')  OK"
    else
        echo "  MISSING nxf_module_load CALL in .command.run  FAIL"; FAILURES=$((FAILURES+1))
    fi
    if grep -qE 'apptainer (exec|run)' "$_f"; then
        echo "  engine: apptainer invoked without naming an engine profile  OK"
    else
        echo "  FAIL: no apptainer invocation found in .command.run"; FAILURES=$((FAILURES+1))
        grep -E 'singularity|apptainer' "$_f" | head -3 | sed 's/^/    /'
    fi
    # Execution order: the nxf_module_load CALL must precede the nxf_launch CALL.
    # Exclude the DEFINITION lines. `nxf_launch() {` sits at ~line 123 while the actual call
    # is inside `(set -o pipefail; (nxf_launch | tee .command.out) ...)` at ~line 180, so an
    # anchored '^\s*nxf_launch' matches the definition and makes a correctly-ordered script
    # look inverted. This is the third pattern in this file that had to be re-aimed at a call
    # site rather than a declaration.
    _ml=$(grep -nE '^\s*nxf_module_load [a-zA-Z]' "$_f" | head -1 | cut -d: -f1)
    _nl=$(grep -n 'nxf_launch' "$_f" | grep -v 'nxf_launch() *{' | head -1 | cut -d: -f1)
    if [ -n "$_ml" ] && [ -n "$_nl" ] && [ "$_ml" -lt "$_nl" ]; then
        echo "  ordering: nxf_module_load call (line $_ml) precedes nxf_launch call (line $_nl)  OK"
    else
        echo "  FAIL: module call at ${_ml:-none}, launch call at ${_nl:-none} -- wrong order"
        FAILURES=$((FAILURES+1))
    fi
else
    echo "  no GPU .command.run generated  FAIL"; FAILURES=$((FAILURES+1))
fi

echo
echo "############ ASSERTIONS on the GPU task header ############"
echo "  (exit 1 from gres_null / no_account is EXPECTED and is the point: Puhti rejects a GPU"
echo "   job with no --gres, and any job with no --account. The header is written BEFORE"
echo "   submission, which is what these assert.)"
assert_gpu_header populated  want    '--gres=gpu:v100:1'
assert_gpu_header populated  want    '--account=project_2009297'
assert_gpu_header gres_null  notwant '--gres'
assert_gpu_header gres_null  want    '--account=project_2009297'
# no_account is asserted against ANY generated header, not the GPU one. On Puhti an
# account-less job is rejected at submission, so the run aborts on the first task and
# DEEPSAP_TSJS never gets a .command.run at all -- there is no GPU header to inspect. The
# contract ("--account appears nowhere") is fully checkable on the headers that do exist.
# Asserting it on the GPU task instead would be unfalsifiable here: it can only ever report
# "cannot check", which an earlier looser matcher silently rendered as a pass.
_na_files=$(find "$R/profile_hdr_no_account/work" -name .command.run 2>/dev/null)
if [ -n "$_na_files" ]; then
    if grep -h '^#SBATCH' $_na_files | grep -q -- '--account'; then
        echo "  ASSERT no_account: unexpectedly contains '--account'  FAIL"; FAILURES=$((FAILURES+1))
    else
        echo "  ASSERT no_account: absent '--account' across $(echo "$_na_files" | wc -l) header(s)  OK"
    fi
else
    echo "  ASSERT no_account: no headers generated at all  FAIL"; FAILURES=$((FAILURES+1))
fi

echo
echo "############ does -profile slurm,singularity actually launch? ############"
# Stub run only: proves param wiring and that singularity.enabled does not break the DAG.
# On Puhti `singularity` is a symlink to apptainer, so this tests the WIRING, not SingularityCE.
W=$R/profile_test; rm -rf "$W"; mkdir -p "$W"; cd "$W"
printf 'sample,bam\ns1,%s\n' "$R/outputdir/run_35519462/test_run_10K_default_gsnap.bam" > ss.csv
printf 'process {\n  withLabel:process_gpu { cpus = 2\n memory = 4.GB }\n  withLabel:process_low { cpus = 1\n memory = 2.GB }\n}\n' > cpu.config

nextflow run "$PIPE/main.nf" -stub-run -profile singularity -c cpu.config \
    -with-trace "$W/trace.txt" \
    --input ss.csv \
    --fasta "$R/testdata/malaria_short_pe/Plasmodium_falciparum.ASM276v2.dna.toplevel.fa" \
    --gtf   "$R/testdata/malaria_short_pe/Plasmodium_falciparum.ASM276v2.60.gtf" \
    --deepsap_sif "$R/images/deepsap.sif" --ctmp "$R/ctmp" \
    --outdir "$W/out" > "$W/log.txt" 2>&1
echo "  exit: $?"
if [ -s "$W/trace.txt" ]; then
    awk -F'\t' 'NR>1 {print "  ran: "$4"  ("$5")"}' "$W/trace.txt" | sort -u
else
    echo "  NO TRACE. last lines:"; tail -8 "$W/log.txt" | sed 's/^/    /'
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "############ ALL PROFILE ASSERTIONS PASSED ############"
    exit 0
else
    echo "############ $FAILURES PROFILE ASSERTION(S) FAILED ############"
    exit 1
fi
