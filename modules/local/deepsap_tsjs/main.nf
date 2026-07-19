//
// Score an existing BAM with DeepSAP's TSJS transformer only (-s/--sam mode). No GSNAP
// alignment: the aligner is never invoked in this mode, so nothing here needs GPU-capable
// alignment code -- the GPU is used exclusively by the transformer, per the project's own
// measured finding that gsnap/gmap in this image carry no device code at all.
//
// EVERYTHING below that looks like an odd workaround has a specific, measured reason.
// Comments point at the operational source of truth: private_projects/deepsap-cluster-
// feasibility (scripts/common.sh, scripts/04_end_to_end.sbatch, red_team_brief.md), which
// this pipeline's entire container-invocation contract is drawn from.
//
process DEEPSAP_TSJS {
    tag "$meta.id"
    label 'process_gpu'

    container params.deepsap_sif

    // Nextflow launches containerized processes with `apptainer exec` against the
    // generated .command.sh, which does NOT go through the image's ENTRYPOINT
    // (`sh /scripts/DeepSAP_wrapper.sh`). That wrapper is what supplies six of DeepSAP's
    // required arguments (--config, --model_name, --max_seq, --window, --model_path,
    // --kmer) plus --batch 32, and it expands "$@" LAST, so our own flags win. Skipping it
    // and calling /DeepSAP/DeepSAP directly would fail argparse on the missing required
    // flags -- it is invoked explicitly below, by name, for exactly this reason.
    containerOptions {
        // --home's destination is the HOST's own $HOME (resolved here, on the host, before
        // apptainer runs -- NOT inside the container, where it would be empty/wrong). This
        // mirrors common.sh's `--home "$FAKEHOME:$HOME"`: it keeps the container's view of
        // $HOME pointed at an empty per-task directory instead of auto-mounting the real
        // one, which would leak a login-quota-limited $HOME into the run.
        "--nv --cleanenv --home ${task.workDir}/fakehome:${System.getenv('HOME')} " +
        "--writable-tmpfs --bind ${task.workDir}/ctmp_local:/tmp --pwd ${task.workDir}"
    }

    // Runs on the HOST before the container launches -- for BOTH a real run and a
    // `-stub-run` (Nextflow still launches the configured container either way; only the
    // script/stub body differs -- confirmed empirically, not assumed). Makes THIS TASK'S
    // OWN private copy of the pre-staged checkpoint tree (params.ctmp/83) rather than
    // binding the shared params.ctmp directory itself read-write. Two concurrent DeepSAP
    // processes writing into the SAME /tmp/83 extraction target collide; per-task copies
    // avoid that entirely at the cost of ~442 MB and a few seconds of local copy per task --
    // cheap next to a GPU allocation. (Sharing one staged dir read-only was flagged in the
    // operational notes as "verify, do not assume" and was never verified against this
    // pipeline's concurrency pattern, so the safer, verified-by-construction option is used
    // instead.)
    //
    // Skipped under -stub-run: a stub run is meant to be free and instant, and params.ctmp
    // legitimately has no real /83 tree to copy yet on a first-ever checkout (STAGE_CTMP's
    // own stub is a no-op for the same reason -- there is no image to extract from without
    // a real container). `mkdir -p ctmp_local` still runs so the bind target in
    // containerOptions always exists.
    beforeScript {
        workflow.stubRun
            ? "mkdir -p ctmp_local fakehome"
            : "mkdir -p ctmp_local fakehome && cp -r '${params.ctmp}/83' ctmp_local/83"
    }

    // stageAs pins the three reference files to fixed names in the task directory, so the
    // script body can refer to `reference.fasta` regardless of whether the user passed
    // GRCh38.primary_assembly.genome.fa or Mus_musculus.GRCm39.dna.toplevel.fa. Critically it
    // also puts the index at `reference.fasta.fai` -- i.e. as a sibling of the FASTA under
    // exactly the name samtools/pysam/pyfaidx look for -- which is what makes read-only
    // symlink staging safe and removes the old per-task `cp -L`.
    input:
    tuple val(meta), path(bam)
    path(fasta, stageAs: 'reference.fasta')
    path(fai,   stageAs: 'reference.fasta.fai')
    path(gtf,   stageAs: 'reference.gtf')

    output:
    tuple val(meta), path("outdir/${prefix}")                    , emit: scored_bam
    tuple val(meta), path("outdir/${prefix}_junctions.tsv")       , emit: junctions
    tuple val(meta), path("outdir/${prefix}_prediction_batch_*")  , emit: prediction_batches, optional: true
    path "versions.yml"                                          , emit: versions

    script:
    prefix = task.ext.prefix ?: meta.id
    def args = task.ext.args ?: ''
    def threads = params.threads ?: task.cpus
    // Batch/set_size ladder for CUDA-OOM retries (see errorStrategy in conf/modules.config).
    // attempt 1 = params.batch (default 32, the wrapper's own default, unmodified).
    // attempt 2/3 = the exact rungs measured to clear device OOM on this container on a
    // Puhti V100 32GB in deepsap-cluster-feasibility's Stage 4 (04_end_to_end.sbatch).
    // These pairs are carried over verbatim, not re-guessed.
    def batchLadder   = [ (params.batch ?: 32) as Integer, 16, 8 ]
    def setSizeLadder = [ params.set_size, 5000, 2000 ]
    def rung    = Math.min(task.attempt - 1, batchLadder.size() - 1)
    def batch   = batchLadder[rung]
    def setSize = setSizeLadder[rung]
    // Every line below is deliberately flush-left, including inside if-blocks: a heredoc
    // terminator must sit at column 0 to match (or match after stripping leading TABS for
    // <<-, which does not touch leading SPACES). A more visually indented version of the
    // sibling STAGE_CTMP module wrote a heredoc terminator nested inside an `if` and it
    // broke silently -- `-stub-run` never exercises a script: block, only stub:, so it took
    // an actual, non-stub execution to catch it. Kept flush-left everywhere here too rather
    // than trusting indentation to dedent uniformly.
    """
set +e

# NO per-task copy of the reference. DeepSAP cuts +/-150bp windows around each junction
# (--window 150 --max_seq 150, wrapper-injected), which means random FASTA access, and
# every standard route to that (samtools faidx, pysam, pyfaidx) creates <fa>.fai as a
# SIBLING of the FASTA on first open. That write is the only reason a writable reference
# was ever needed -- and it does not happen when the .fai already exists.
#
# So PREPARE_REFERENCE builds the index ONCE and both files are staged here as symlinks.
# The earlier `cp -L` of FASTA and GTF cost ~4.5 GB of Lustre traffic PER SAMPLE on a
# human reference (GRCh38 ~3.1 GB + GENCODE GTF ~1.4 GB) plus a redundant faidx of a
# 3 GB genome in every task. For a batch of 20 BAMs that is ~90 GB copied to produce
# identical bytes 20 times, on a filesystem whose file-count quota this project has
# already exhausted twice.
#
# `reference.fasta.fai` must sit beside `reference.fasta` in the task dir for this to
# hold; the input block stages exactly that pair. If the .fai is ever missing, the line
# below rebuilds it locally rather than failing -- correctness first, speed second.
[ -s reference.fasta.fai ] || samtools faidx reference.fasta

# Cheap preflight, before spending any of the GPU allocation on prediction: confirm the
# BAM and FASTA share at least one contig name. A silent zero-overlap reference mismatch
# is exactly the kind of failure this project's operational history warns is easy to
# misattribute to DeepSAP itself. This still happens inside the GPU-scheduled task (it
# does not save queue time), only compute time within the allocation -- see README for
# how to move it earlier if that matters for your scheduler.
samtools view -H ${bam} | awk -F'\\t' '/^@SQ/{for(i=1;i<=NF;i++) if(\$i ~ /^SN:/) print substr(\$i,4)}' | sort -u > bam_contigs.txt
cut -f1 reference.fasta.fai | sort -u > fasta_contigs.txt
if [ ! -s bam_contigs.txt ] || [ -z "\$(comm -12 bam_contigs.txt fasta_contigs.txt)" ]; then
echo "[deepsap_tsjs] FATAL: no contig names in common between ${bam} and the FASTA." >&2
echo "[deepsap_tsjs] BAM contigs (first 5):" >&2; head -5 bam_contigs.txt >&2 || true
echo "[deepsap_tsjs] FASTA contigs (first 5):" >&2; head -5 fasta_contigs.txt >&2 || true
exit 1
fi

export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1

mkdir -p outdir

# --model_path is DELIBERATELY NOT passed. The wrapper's default
# (/tmp/83/12/bin/io/ADNRBE_T11MS50.tar.gz) is the real, trained TSJS checkpoint,
# reachable because containerOptions bound this task's private ctmp_local over /tmp.
# Overriding it with anything else (e.g. a bare pretrained DNABERT-6 path) would load an
# UNTRAINED classification head and score every junction with random weights while still
# exiting 0 -- a false PASS on the one thing this module exists to compute.
sh /scripts/DeepSAP_wrapper.sh \\
    --sam ${bam} \\
    --fasta reference.fasta \\
    --gtf reference.gtf \\
    --out ./outdir/ \\
    --prefix ${prefix} \\
    --threads ${threads} \\
    --batch ${batch} \\
    ${setSize ? "--set_size ${setSize}" : ''} \\
    ${args} \\
    > deepsap.log 2>&1
rc=\$?
set -e

if [ \$rc -ne 0 ]; then
cat deepsap.log >&2
if grep -qiE 'CUDA out of memory|CUDA_ERROR_OUT_OF_MEMORY' deepsap.log; then
echo "[deepsap_tsjs] CUDA OOM detected at batch=${batch} (attempt ${task.attempt}) -- signalling retry via exit 137." >&2
exit 137
fi
echo "[deepsap_tsjs] DeepSAP exited \$rc (not a recognised OOM signature) -- see deepsap.log above." >&2
exit \$rc
fi

# Do not declare success on exit code alone (the rule this project's own operational
# history was built around): confirm the scored output exists at the exact documented
# name -- it has NO FILE EXTENSION, so a *.bam glob would silently match nothing -- and
# passes samtools quickcheck before this task is allowed to report success.
if [ ! -s "outdir/${prefix}" ]; then
echo "[deepsap_tsjs] FATAL: outdir/${prefix} (the TSJS-scored BAM) is missing or empty." >&2
ls -la outdir >&2 || true
exit 1
fi
samtools quickcheck "outdir/${prefix}"

if [ ! -s "outdir/${prefix}_junctions.tsv" ]; then
echo "[deepsap_tsjs] FATAL: outdir/${prefix}_junctions.tsv is missing or empty." >&2
exit 1
fi

cat <<END_VERSIONS > versions.yml
"${task.process}":
    deepsap: "0.0.3"
    container_digest: "sha256:d437752a03761b8c73aab1962e1aed877c58f99844f7b4856b676a2257becebf"
END_VERSIONS
"""

    stub:
    prefix = task.ext.prefix ?: meta.id
    """
mkdir -p outdir "outdir/${prefix}_prediction_batch_0"
touch "outdir/${prefix}"
printf "ID\\tSignla\\tType\\tScore\\tDonor\\tAcceptor\\n" > "outdir/${prefix}_junctions.tsv"
touch "outdir/${prefix}_prediction_batch_0/dev.csv"
touch "outdir/${prefix}_prediction_batch_0/dev_6mer.json"
touch "outdir/${prefix}_prediction_batch_0/probs.npy"

cat <<END_VERSIONS > versions.yml
"${task.process}":
    deepsap: "0.0.3"
    container_digest: "sha256:d437752a03761b8c73aab1962e1aed877c58f99844f7b4856b676a2257becebf"
END_VERSIONS
"""
}
