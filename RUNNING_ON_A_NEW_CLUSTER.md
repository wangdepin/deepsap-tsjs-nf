# Running deepsap-tsjs-nf on a new cluster

A single ordered runbook. The scattered detail lives in `README.md`; this is the sequence to
follow start to finish. It assumes a SLURM cluster with GPU nodes. Values you must fill in are
written `<like_this>`.

Everything here has been run end to end on CSC Puhti (V100 32 GB). What is *not* yet verified
on a genuinely different site is called out inline — treat your first small run as the real
test, never a full batch.

---

## 0. Prerequisites

| Need | Why | How to check |
|---|---|---|
| SLURM with GPU nodes | the scoring task is a GPU job | `sinfo -o '%P %G'` |
| **Apptainer**, or **SingularityCE ≥ 3.7.0** | the container, and `--no-mount tmp` (see step 5) | `apptainer --version` / `singularity --version` |
| Nextflow ≥ 23.10 + Java 11+ | runs the pipeline | `nextflow -version` |
| A GPU where `--nv` works | CUDA passthrough | step 5 smoke test |
| Head-node outbound internet **or** a pre-pulled `.sif` | to get the 12 GB image | `curl -sI https://nvcr.io` |

GPU architecture: verified on **V100 (sm_70)**. The TSJS path is PyTorch, so an A100/H100
almost certainly works through PyTorch's bundled kernels, but that is **unverified** — your
canary in step 7 is the test. A pre-Pascal GPU is too old.

---

## 1. Get Nextflow and the pipeline

```bash
# Nextflow: use your site's module if it has one, else install locally
module load nextflow            # OR: curl -s https://get.nextflow.io | bash

git clone https://github.com/wangdepin/deepsap-tsjs-nf.git
cd deepsap-tsjs-nf
```

---

## 2. Get the container (pick ONE)

### Option A — pre-pull once (recommended)

Simplest and reusable. Do it on a node with internet and enough scratch:

```bash
apptainer pull /scratch/<proj>/deepsap.sif \
  docker://nvcr.io/nvidia/clara/clara-parabricks-deepsap@sha256:d437752a03761b8c73aab1962e1aed877c58f99844f7b4856b676a2257becebf
```

Anonymous pull — no NGC login. ~19.3 GB / 83 layers → ~12 GB SIF. Then pass
`--deepsap_sif /scratch/<proj>/deepsap.sif` in step 6.

### Option B — let Nextflow auto-pull

Leave `--deepsap_sif` unset (it defaults to the digest above) but **set all three cache vars
first**. Each was learned from a separate multi-GB failure:

```bash
export NXF_APPTAINER_CACHEDIR=/scratch/<proj>/sifcache   # final .img  → shared FS (1 file)
export APPTAINER_CACHEDIR=<local_or_high_inode_disk>/cache  # layer blobs → NOT $HOME
export APPTAINER_TMPDIR=<local_or_high_inode_disk>/tmp      # rootfs unpack → NOT $HOME
```

Why: `NXF_APPTAINER_CACHEDIR` only places the finished `.img`; `apptainer pull` still writes
blobs to `$APPTAINER_CACHEDIR` (default `$HOME/.apptainer/cache`) and unpacks a CUDA+Python
rootfs (hundreds of thousands of `.pyc` files) in `$APPTAINER_TMPDIR`. On a quota'd `$HOME` or
an **inode**-limited Lustre scratch this dies mid-pull with `disk quota exceeded` even when TBs
are free. Point both at node-local disk (e.g. `/local_scratch/$USER`) or a filesystem with a
generous file-count quota. If Nextflow says *"increase apptainer.pullTimeout"* — ignore it,
that is never the real cause here.

SingularityCE users: swap `APPTAINER_*` → `SINGULARITY_*` and `NXF_APPTAINER_CACHEDIR` →
`NXF_SINGULARITY_CACHEDIR`.

---

## 3. Prepare the checkpoint dir (`--ctmp`)

Just give an **empty, writable, persistent** path:

```bash
mkdir -p /scratch/<proj>/deepsap_ctmp
```

`STAGE_CTMP` populates it from the image on the first run (the TSJS checkpoint lives inside the
image at `/tmp/83`, 442 MB) and every later run reuses it. Nothing to download by hand.

---

## 4. Prepare inputs

- **FASTA** — uncompressed, and its contig names **must match the BAM headers**. GENCODE
  `chr1` vs Ensembl `1` is the classic STAR-BAM mismatch; the scoring module preflights it and
  aborts loudly, but check first with:
  ```bash
  diff <(samtools view -H your.bam | awk '$1=="@SQ"{sub("SN:","",$2);print $2}' | sort) \
       <(grep '^>' ref.fa | sed 's/>//;s/ .*//' | sort) | head
  ```
  The BAM's contigs must be a subset of the FASTA's. `.fai` is optional — the pipeline builds
  it once via `PREPARE_REFERENCE` if absent.
- **GTF** — matching the FASTA.
- **samplesheet.csv** — one row per BAM:
  ```
  sample,bam
  sampleA,/path/to/sampleA.bam
  sampleB,/path/to/sampleB.bam
  ```

---

## 5. Confirm the one hard portability constraint: `--no-mount tmp`

The engine **must** support `--no-mount tmp` — it is the only way to read the checkpoint out of
the image's own `/tmp/83`. Apptainer always has it; SingularityCE since 3.7.0. Check before
spending a GPU allocation:

```bash
apptainer exec --help 2>&1 | grep -- --no-mount   # must print a line
```

`STAGE_CTMP`'s `beforeScript` also checks this and fails with an actionable message, but
checking now saves a queue wait. If your engine lacks it: stage `--ctmp` once on any machine
with a newer engine, copy the populated dir over, and point `--ctmp` at it — the extraction is
then skipped and nothing else needs `--no-mount`.

Also confirm CUDA passthrough works on a GPU node (interactive shell or a 5-min job):

```bash
apptainer exec --nv /scratch/<proj>/deepsap.sif python -c "import torch; print(torch.cuda.is_available())"
# expect: True
```

---

## 6. Assemble the run command

Apptainer is the **default engine** — you do not name it. Fill in the SLURM params for your
site; each flag is emitted only when its param is set.

```bash
nextflow run main.nf -profile slurm \
    --account          <my_project> \       # omit if the cluster has no accounting
    --gpu_partition    <gpu_partition> \
    --cpu_partition    <cpu_partition> \     # light tasks; falls back to gpu_partition if unset
    --gpu_gres         'gpu:v100:1' \        # or 'gpu:1', or null if GPUs come from the partition
    --container_module <apptainer> \         # ONLY if apptainer is module-only on compute nodes
    --deepsap_sif      /scratch/<proj>/deepsap.sif \   # omit to auto-pull (step 2B)
    --ctmp             /scratch/<proj>/deepsap_ctmp \
    --input            samplesheet.csv \
    --fasta            ref.fa \
    --gtf              ref.gtf \
    --outdir           results
```

Notes on the tricky ones:

- **`--container_module`** loads an environment module on the **compute node** before the
  container runs. Drop it if `apptainer` is already on the compute-node PATH; include it
  otherwise. This is the trap a site like Puhti (apptainer at `/usr/bin`) cannot reveal — the
  failure is `apptainer: command not found` from a job that submitted perfectly. Colon-separate
  several: `--container_module 'apptainer:cuda'`.
- **`--gpu_gres null`** (or `''`) omits `--gres` entirely, for clusters that allocate GPUs by
  partition alone. `--gpu_extra '<flags>'` appends arbitrary sbatch flags verbatim.
- **`-profile slurm,singularity`** to use SingularityCE instead of apptainer.
- **GPU resources** default to 8 CPU / 64 GB / 2 h (`--gpu_cpus` / `--gpu_memory` / `--gpu_time`
  to change). Measured need on a full mouse BAM (15.7 M records) was 26.9 GB and 10 min, so the
  defaults are comfortable for a mammalian genome. Read actual use from `sacct -j <id>
  --format=MaxRSS,Elapsed` afterwards, **not** from Nextflow's trace (it samples and
  under-reports peak RSS by ~25×).

**Add a site permanently** by copying `conf/puhti.config` (a 20-line instantiation of
`conf/slurm.config`) to `conf/<yoursite>.config`, changing the four params, and adding a
`<yoursite>` profile in `nextflow.config`.

---

## 7. Canary first — never a full batch

Run **one** small BAM (or subset one chromosome) before committing the batch. If the site has a
short-queue GPU partition, use it with a tight walltime:

```bash
nextflow run main.nf -profile slurm \
    --gpu_partition <short_gpu_partition> --gpu_time '15.m' \
    ... (same params as step 6, one-sample samplesheet)
```

Then verify, in order:

1. **It completed** — `nextflow` exits 0, both tasks `COMPLETED`.
2. **The real GPU task header is right** — find the `DEEPSAP_TSJS (<sample>)` work dir and run
   `tests/assert_sbatch_header.sh <that_dir> <expected_mem_MB> <expected_cpus>`. (Match the
   exact leaf name — `grep DEEPSAP_TSJS` also matches `DEEPSAP_TSJS_WF:STAGE_CTMP`.)
3. **The junction table looks sane** — three cheap controls on
   `results/deepsap/<sample>/<sample>_junctions.tsv`:
   ```bash
   # annotated fraction should be high (>80%) for a well-annotated genome; a low value means
   # the GTF is not matching and any score reading is meaningless
   awk -F'\t' 'NR>1{n++; if($3!="Novel")a++} END{printf "annotated %d/%d = %.0f%%\n",a,n,100*a/n}' J.tsv
   # canonical motif GT-AG should dominate (~98%)
   awk -F'\t' 'NR>1{m[$2]++} END{for(k in m) print m[k],k}' J.tsv | sort -rn | head
   ```

---

## 8. Calibration — what to actually look at (this changed)

The known quirk is **not** a species miscalibration. Annotated junctions that score low are
explained by **window truncation on short introns**: DeepSAP cuts ±150 bp windows around donor
and acceptor, and when the intron is shorter than the window the input is truncated and
out-of-distribution, scoring ~0. Verified across mouse and *P. falciparum* — the fraction of
annotated junctions scoring <50 equals the fraction with an intron <150 bp to within ~1 point
every time (mouse 12–18 %, *P. falciparum* ~49 %), and essentially 100 % of low scorers have a
truncated window.

Check it on your data directly:

```bash
# if scored junctions carry the donor/acceptor windows, the truncation is visible per-row;
# otherwise compute intron length from the ID (chrom__strand__start__end):
awk -F'\t' 'NR>1 && $3!="Novel"{
  n=split($1,p,"__"); ilen=p[n]-p[n-1]+1;
  a++; if($4<50)lo++; if(ilen<150)sh++
} END{printf "annotated %d | <50 %.1f%% | intron<150bp %.1f%%\n",a,100*lo/a,100*sh/a}' \
  results/deepsap/*/*_junctions.tsv
```

If the two percentages track each other, the low scores are the short-intron artifact and the
tool is discriminating fine where the window is intact (a strong positive control: spurious
junctions with full windows — e.g. all mouse chrM junctions — do score low). The **consequence
is asymmetric**: annotated junctions are kept at any score, but a **novel** junction scoring
<50 is *rejected and un-spliced in the BAM* (see step 9), so genuine novel **short** introns are
discarded — ~97 % of short novel junctions in the mouse data. If your biology cares about novel
short-intron splicing, handle this before trusting the novel calls.

---

## 9. Outputs, and two post-processing caveats

Per sample under `results/deepsap/<sample>/`:

| File | What |
|---|---|
| `<sample>` (no extension) | the TSJS-scored BAM, BGZF |
| `<sample>_junctions.tsv` | junction table: `ID, Signla, Type, Score, Donor, Acceptor` (`Signla` is upstream's typo for the splice motif) |
| `<sample>_prediction_batch_N/` | `probs.npy`, `dev.csv`, `dev_6mer.json` |

Two things about the scored BAM (measured on real mouse M_H2, 15.7 M records):

1. **It is not the input plus tags — it rewrites alignments.** A rejected junction is
   un-spliced in place: the far block becomes a soft clip and **POS moves** (e.g.
   `16M297863N35M`@46213852 → `16S35M`@46511731). Record count, SEQ and MAPQ are preserved; it
   adds `js`/`jt`/`nj` tags and a `@PG` line. On well-annotated mouse only 0.6 % of spliced
   reads were touched (vs 47 % on *P. falciparum*), because annotated junctions are always kept.
   **Keep the input BAM** — the rewrite is not reversible from the output.
2. **The header says `SO:coordinate` but the records are not fully sorted** — the rewrite moves
   POS without re-sorting (3,204 out-of-order positions in M_H2). **Re-sort before indexing:**
   ```bash
   samtools sort -o <sample>.sorted.bam results/deepsap/<sample>/<sample>
   samtools index <sample>.sorted.bam
   ```

Scratch filesystems usually auto-purge (Puhti: 90 days). Move the scored BAMs and junction
tables somewhere durable if you need to keep them.
