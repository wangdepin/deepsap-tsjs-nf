#!/bin/bash
# Assert that every resource label SURVIVES config resolution under every profile.
#
# WHY THIS TEST EXISTS
#
# conf/base.config set `withLabel: process_gpu { cpus 8; memory 64.GB; time 2.h }` and
# conf/slurm.config separately declared `withLabel: process_gpu { queue; clusterOptions }`.
# Identical selector strings across config files REPLACE rather than merge, so under
# -profile slurm the resources were deleted and DEEPSAP_TSJS ran on the top-level fallback
# of 1 CPU and 4 GB. Nothing detected it for the entire P. falciparum campaign -- including a
# from-scratch end-to-end validation that was reported as PASSED -- because a 23 MB genome
# fits in 4 GB and finishes in 25 s. The first mm10 run was killed by SLURM in three minutes.
#
# Every check that existed at the time read the SOURCE config files, where the numbers are
# plainly present. None read the RESOLVED config, which is the only place the collision is
# visible. That is the gap this file closes.
#
# Run:  tests/test_resolved_resources.sh [/path/to/pipeline]
set -o pipefail

PIPE="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
command -v nextflow >/dev/null || { echo "SKIP: nextflow not on PATH"; exit 0; }

FAIL=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=1; }

# Resolve config for a profile and emit flattened key=value lines.
resolve() { nextflow config "$PIPE" -profile "$1" -flat 2>/dev/null; }

# Every label that carries resources, and the directives each must retain.
LABELS="process_single process_low process_medium process_high process_gpu"

for PROF in standard slurm puhti "slurm,apptainer" "slurm,singularity"; do
    echo "=== -profile $PROF ==="
    CFG=$(resolve "$PROF")
    if [ -z "$CFG" ]; then fail "$PROF: config did not resolve at all"; continue; fi

    for L in $LABELS; do
        for D in cpus memory time; do
            # -flat renders these as: process.'withLabel:process_gpu'.memory = '64 GB'
            if printf '%s\n' "$CFG" | grep -qF "process.'withLabel:${L}'.${D} ="; then
                pass "$PROF  $L.$D present"
            else
                fail "$PROF  $L.$D MISSING (selector-collision regression)"
            fi
        done
    done

    # The GPU task must never silently inherit the top-level fallback. Assert the resolved
    # value DIFFERS from it, so that a future edit setting gpu_memory back to 4 GB by accident
    # is caught too -- 'present' alone would not catch that.
    GPUMEM=$(printf '%s\n' "$CFG" | sed -n "s/^process\.'withLabel:process_gpu'\.memory = //p" | tr -d "'")
    TOPMEM=$(printf '%s\n' "$CFG" | sed -n "s/^process\.memory = //p" | tr -d "'")
    if [ -n "$GPUMEM" ] && [ "$GPUMEM" != "$TOPMEM" ]; then
        pass "$PROF  process_gpu.memory ($GPUMEM) != top-level fallback ($TOPMEM)"
    else
        fail "$PROF  process_gpu.memory ('$GPUMEM') is missing or equals fallback ('$TOPMEM')"
    fi
done

# NOT TESTED HERE, DELIBERATELY: whether --gpu_memory / --gpu_cpus on the command line reach
# the directive. `nextflow config` accepts ONLY -profile and -flat; it rejects --<param>,
# -params-file and -c alike with "Unknown option". An assertion written against any of those
# routes fails no matter whether the pipeline is correct, so it measures the harness rather
# than the code -- the first draft of this file did exactly that and reported two red lines
# against a pipeline that was fine. The override is asserted instead where it is observable:
# tests/assert_sbatch_header.sh reads --mem/--cpus-per-task straight out of a generated
# .command.run, which is the value SLURM actually receives.
echo "=== param override ==="
echo "  n/a  checked at run time by tests/assert_sbatch_header.sh (see comment above)"

echo
[ "$FAIL" -eq 0 ] && echo "ALL RESOLVED-RESOURCE CHECKS PASSED" || echo "*** RESOLVED-RESOURCE CHECKS FAILED ***"
exit "$FAIL"
