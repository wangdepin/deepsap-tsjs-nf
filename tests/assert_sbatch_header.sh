#!/bin/bash
# Assert what SLURM ACTUALLY RECEIVES for the GPU task, by reading the generated .command.run.
#
# This is the companion to tests/test_resolved_resources.sh, which can only inspect profiles:
# `nextflow config` rejects --<param>, -params-file and -c ("Unknown option"), so a command-line
# override is unobservable there. The sbatch header is where it becomes observable, and it is
# also the artifact that actually failed -- the first mm10 run carried `#SBATCH --mem 4096M`
# and no --cpus-per-task at all while the config claimed 64 GB and 8 CPUs.
#
# Usage: tests/assert_sbatch_header.sh <work_dir_of_a_DEEPSAP_TSJS_task> [expected_mem_MB] [expected_cpus]
#   e.g. tests/assert_sbatch_header.sh work/cd/ceb868* 65536 8
set -o pipefail

TASKDIR="${1:?usage: assert_sbatch_header.sh <task work dir> [expected_mem_MB] [expected_cpus]}"
EXP_MEM="${2:-}"
EXP_CPUS="${3:-}"
RUN="$TASKDIR/.command.run"
[ -f "$RUN" ] || { echo "FAIL: no .command.run at $RUN"; exit 1; }

FAIL=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=1; }

echo "=== #SBATCH header of $(basename "$(dirname "$TASKDIR")")/$(basename "$TASKDIR") ==="
grep -E '^#SBATCH' "$RUN" | sed 's/^/    /'
echo

# --mem must be present. Absence is the silent case: SLURM then applies a partition default
# that has nothing to do with what the pipeline asked for.
MEM=$(grep -oE '^#SBATCH --mem[= ]+[0-9]+[MG]?' "$RUN" | grep -oE '[0-9]+[MG]?$')
if [ -z "$MEM" ]; then
    fail "--mem absent from the header (task would run on the partition default)"
else
    MEM_MB=$MEM
    case "$MEM" in *G) MEM_MB=$(( ${MEM%G} * 1024 ));; *M) MEM_MB=${MEM%M};; esac
    pass "--mem present: $MEM (${MEM_MB} MB)"
    if [ "$MEM_MB" -le 4096 ]; then
        fail "--mem is ${MEM_MB} MB, i.e. at or below the 4 GB top-level fallback -- the label was probably dropped again"
    else
        pass "--mem exceeds the 4 GB fallback, so the process_gpu label survived resolution"
    fi
    if [ -n "$EXP_MEM" ]; then
        [ "$MEM_MB" = "$EXP_MEM" ] && pass "--mem matches expected ${EXP_MEM} MB" \
                                   || fail "--mem ${MEM_MB} MB != expected ${EXP_MEM} MB"
    fi
fi

# --cpus-per-task must be present. Its absence silently gives 1 CPU, which the module then
# passes to DeepSAP as --threads 1.
CPUS=$(grep -oE '^#SBATCH (--cpus-per-task[= ]+|-c +)[0-9]+' "$RUN" | grep -oE '[0-9]+$')
if [ -z "$CPUS" ]; then
    fail "--cpus-per-task absent (SLURM gives 1; module then runs DeepSAP with --threads 1)"
else
    pass "--cpus-per-task present: $CPUS"
    [ "$CPUS" -gt 1 ] && pass "more than 1 CPU requested" \
                      || fail "only $CPUS CPU requested"
    if [ -n "$EXP_CPUS" ]; then
        [ "$CPUS" = "$EXP_CPUS" ] && pass "--cpus-per-task matches expected $EXP_CPUS" \
                                  || fail "--cpus-per-task $CPUS != expected $EXP_CPUS"
    fi
fi

# Cross-check: whatever SLURM was asked for is what the module told DeepSAP to use.
THREADS=$(grep -oE '\-\-threads +[0-9]+' "$TASKDIR/.command.sh" 2>/dev/null | grep -oE '[0-9]+$' | head -1)
if [ -n "$THREADS" ] && [ -n "$CPUS" ]; then
    [ "$THREADS" = "$CPUS" ] && pass "DeepSAP --threads ($THREADS) matches --cpus-per-task ($CPUS)" \
                             || fail "DeepSAP --threads ($THREADS) != --cpus-per-task ($CPUS)"
fi

echo
[ "$FAIL" -eq 0 ] && echo "SBATCH HEADER OK" || echo "*** SBATCH HEADER CHECKS FAILED ***"
exit "$FAIL"
