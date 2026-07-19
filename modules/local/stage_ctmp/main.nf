//
// Stage (or verify) the host directory that gets bound over the DeepSAP container's /tmp.
//
// WHY THIS PROCESS EXISTS
// ------------------------
// The TSJS checkpoint ships INSIDE the image at /tmp/83/12/bin/io/ADNRBE_T11MS50.tar.gz
// (442,457,676 bytes) and is decrypted at run time, into /tmp. Binding an empty directory
// over /tmp hides the checkpoint; leaving /tmp on the --writable-tmpfs session overlay
// gives ~64 MiB, not enough to extract 442 MB into. The only configuration that satisfies
// both "checkpoint must be readable" and "there must be GBs to extract into" is a HOST
// directory PRE-POPULATED with the image's own /tmp/83 tree, bound read-write.
//
// This is measured, not assumed -- see private_projects/deepsap-cluster-feasibility
// (scripts/common.sh, scripts/04_end_to_end.sbatch), the sibling project this pipeline's
// operational contract is drawn from. That project's `ensure_container_tmp()` is the
// origin of the check-then-stage-then-atomically-publish pattern below.
//
// ONE staged copy is maintained at params.ctmp (a persistent, shared HOST path -- e.g.
// /scratch/project_2009297/deepsap-feasibility/ctmp_canary). Each DEEPSAP_TSJS task later
// makes its OWN private copy of params.ctmp/83 before binding its own copy over /tmp --
// see modules/local/deepsap_tsjs/main.nf for why sharing one read-write copy across
// concurrent tasks is unsafe. This process only has to run the expensive extraction once;
// every later pipeline invocation (this run or a future one) finds a byte-verified copy
// already at params.ctmp and skips straight to "reusing" in a few seconds.
//
process STAGE_CTMP {
    tag 'ctmp'
    label 'process_low'

    container params.deepsap_sif
    // --no-mount tmp is REQUIRED here and only here: this is the one call in the whole
    // pipeline that has to read /tmp/83 out of the IMAGE, not out of any host-bound copy.
    // params.ctmp is bound to a container path other than /tmp so the two binds cannot
    // collide.
    containerOptions "--no-mount tmp --bind ${params.ctmp}:/ctmp_persist"

    // Runs on the HOST, before the container launches. Two jobs:
    //
    // 1. params.ctmp must exist before the engine can bind it (a bind source that does not
    //    yet exist is a hard error).
    // 2. Verify the container engine supports `--no-mount`, which the containerOptions above
    //    depend on and which is the ONE portability constraint that cannot be worked around
    //    from inside the pipeline. This has to happen in beforeScript, on the host, because
    //    if the flag is unsupported the container never launches and the script: block below
    //    never runs -- the failure would surface as an engine usage error with no connection
    //    to what actually went wrong.
    //
    //    Supported by Apptainer throughout, and by SingularityCE since 3.7.0 (2020), so this
    //    should only ever fire on a genuinely ancient install. It checks whichever engine is
    //    on PATH rather than assuming, since -profile singularity and -profile apptainer
    //    invoke different binaries.
    beforeScript """
mkdir -p '${params.ctmp}'
_engine=\$(command -v apptainer 2>/dev/null || command -v singularity 2>/dev/null || true)
if [ -n "\$_engine" ] && ! "\$_engine" exec --help 2>&1 | grep -q -- '--no-mount'; then
    echo "[stage_ctmp] FATAL: \$_engine does not support --no-mount." >&2
    echo "[stage_ctmp] STAGE_CTMP needs it to read the TSJS checkpoint out of the image's own" >&2
    echo "[stage_ctmp] /tmp/83, which the engine otherwise hides by mounting the host /tmp over it." >&2
    echo "[stage_ctmp] Apptainer has always had this flag; SingularityCE has had it since 3.7.0." >&2
    echo "[stage_ctmp] Either upgrade the engine, or stage --ctmp once by hand on a machine that" >&2
    echo "[stage_ctmp] has a newer one and point --ctmp at the result: this process then finds a" >&2
    echo "[stage_ctmp] byte-verified copy and skips the extraction entirely." >&2
    exit 1
fi
"""

    output:
    path "versions.yml", emit: versions

    script:
    // Measured against CONTAINER_DIGEST sha256:d437752a03761b8c73aab1962e1aed877c58f99844f
    // 7b4856b676a2257becebf on 2026-07-18/19 in deepsap-cluster-feasibility. If NVIDIA ever
    // republishes this checkpoint at a different size under the same or a new digest, this
    // check will correctly refuse to accept it as "already staged" -- but the pipeline does
    // NOT auto-detect a legitimate new size; see README "What I could not verify".
    //
    // Every line below is deliberately flush-left, including inside if-blocks. A heredoc
    // terminator must sit at column 0 to match (or match after stripping leading TABS for
    // <<-, which does not touch leading SPACES) -- an earlier, more visually indented
    // version of this script wrote a heredoc terminator nested inside an `if`, which broke
    // silently: `-stub-run` never exercises this script: block at all (only stub:), so it
    // takes an actual, non-stub execution to catch a bug like that. One was run, and it did.
    """
set -euo pipefail

CKPT_REL="83/12/bin/io/ADNRBE_T11MS50.tar.gz"
CKPT_BYTES=442457676
REUSED_BYTES=""

if [ -f "/ctmp_persist/\${CKPT_REL}" ]; then
have=\$(stat -c%s "/ctmp_persist/\${CKPT_REL}" 2>/dev/null || echo 0)
if [ "\${have}" = "\${CKPT_BYTES}" ]; then
echo "[stage_ctmp] ${params.ctmp}/83 already holds a byte-verified checkpoint (\${have} bytes) -- reusing, not restaging."
REUSED_BYTES="\${have}"
else
echo "[stage_ctmp] existing copy at ${params.ctmp}/83 is \${have} bytes, expected \${CKPT_BYTES} -- treating as a partial/stale copy and restaging."
fi
else
echo "[stage_ctmp] no staged checkpoint at ${params.ctmp}/83 yet -- staging from the image."
fi

if [ -n "\${REUSED_BYTES}" ]; then
cat <<END_VERSIONS > versions.yml
"${task.process}":
    deepsap_checkpoint_bytes: "\${REUSED_BYTES}"
    action: "reused"
END_VERSIONS
exit 0
fi

# Stage under a per-job name and publish by rename, so a killed task can never leave a
# truncated tree at the real path for a later run to accept as valid.
STAGE_DIR="/ctmp_persist/.staging.\$\$"
rm -rf "\${STAGE_DIR}"
mkdir -p "\${STAGE_DIR}"
cp -r /tmp/83 "\${STAGE_DIR}/83"

have=\$(stat -c%s "\${STAGE_DIR}/\${CKPT_REL}" 2>/dev/null || echo 0)
if [ "\${have}" != "\${CKPT_BYTES}" ]; then
echo "[stage_ctmp] FATAL: extracted checkpoint is \${have} bytes, expected \${CKPT_BYTES}. Refusing to publish a partial copy." >&2
rm -rf "\${STAGE_DIR}"
exit 1
fi

rm -rf /ctmp_persist/83
mv "\${STAGE_DIR}/83" /ctmp_persist/83
rmdir "\${STAGE_DIR}" 2>/dev/null || true
echo "[stage_ctmp] staged and byte-verified: \${have} bytes at ${params.ctmp}/83"

cat <<END_VERSIONS > versions.yml
"${task.process}":
    deepsap_checkpoint_bytes: "\${have}"
    action: "staged"
END_VERSIONS
"""

    stub:
    """
echo "[stage_ctmp] stub: skipping real extraction/verification"
cat <<END_VERSIONS > versions.yml
"${task.process}":
    deepsap_checkpoint_bytes: "442457676"
    action: "stub"
END_VERSIONS
"""
}
