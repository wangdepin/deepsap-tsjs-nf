# deepsap-tsjs-nf

A Nextflow (DSL2) pipeline that scores **existing BAM files** with DeepSAP's TSJS
transformer only. **No GSNAP alignment is ever invoked** — every task runs DeepSAP in
`-s/--sam` mode.

**Status: run end-to-end on real compute.** On 2026-07-19 the pipeline scored two BAMs on a
CSC Puhti V100 via SLURM (4 tasks, 4m01s wall). Design facts come from the sibling project
`deepsap-cluster-feasibility` (a private sibling project, not published here), whose
`scripts/common.sh` and `scripts/04_end_to_end.sbatch` are the origin of the `/tmp`-staging
mechanics, container flags, and output-naming facts this pipeline relies on.

That run included a **control**: alongside a real STAR BAM it re-scored the GSNAP BAM whose
TSJS output was already known byte-for-byte from job 35520334. The control reproduced
`junctions.tsv` and `probs.npy` at identical md5 (`2c4640e1…`, `a82c0fb6…`), which is what
licenses attributing anything the STAR sample did differently to the STAR BAM rather than to
this pipeline's container invocation.

> ⚠️ **Read "DeepSAP rewrites your alignments" below before using the output BAM.** The
> scored BAM is *not* your input BAM plus tags. Rejected junctions are un-spliced in place:
> CIGAR and POS both change. On the STAR test, 1032 of 2203 spliced records lost their `N`.

Read "What I could not verify" before a production run — the open questions are now about
DeepSAP's *scoring behaviour on your species*, not about whether the plumbing works.

## What this pipeline does

```
samplesheet (sample,bam)  ─┐
reference.fasta ──┬────────┼─► DEEPSAP_TSJS (one task per BAM) ─► scored BAM + junctions.tsv + probs.npy
reference.gtf  ───┼────────┘         ▲          ▲
                  │                  │          │ gated on
                  └─► PREPARE_REFERENCE ─┘   STAGE_CTMP (runs once, idempotent)
                      (.fai, once per batch)
```

- **`STAGE_CTMP`** ensures a host directory (`--ctmp`) holds a byte-verified copy of the
  image's own `/tmp/83` checkpoint tree. Runs once; every later invocation (this run, or a
  future one) finds it already there and skips the ~442 MB extraction in a couple of
  seconds.
- **`DEEPSAP_TSJS`** runs one BAM per task. It makes its own private copy of the staged
  `/tmp/83` tree (never shares one read-write copy across concurrent tasks — see below),
  copies the FASTA/GTF into a writable local file, invokes
  `sh /scripts/DeepSAP_wrapper.sh --sam <bam> --fasta ... --gtf ... --out ... --prefix ...`,
  and verifies the scored output exists and passes `samtools quickcheck` before declaring
  success.

## Contract (measured facts this pipeline treats as given)

These are not re-derived here; they come from the task brief and from
`deepsap-cluster-feasibility`'s own measurements on Puhti:

- Container: `nvcr.io/nvidia/clara/clara-parabricks-deepsap`, digest
  `sha256:d437752a03761b8c73aab1962e1aed877c58f99844f7b4856b676a2257becebf` (amd64 only).
  Local SIF on Puhti: `/scratch/project_2009297/deepsap-feasibility/images/deepsap.sif`.
- ENTRYPOINT is `sh /scripts/DeepSAP_wrapper.sh`, which supplies `--config`, `--model_name`,
  `--max_seq`, `--window`, `--model_path`, `--kmer`, and `--batch 32`, then expands `"$@"`
  last (our flags win).
- The TSJS checkpoint (`/tmp/83/12/bin/io/ADNRBE_T11MS50.tar.gz`, 442,457,676 bytes) ships
  inside the image and is decrypted into `/tmp` at run time. `/tmp` must be bound to a HOST
  directory pre-populated with the image's own `/tmp/83` tree — not left empty, not left on
  a `--writable-tmpfs` overlay (~64 MiB, not enough for a 442 MB extraction).
- `--nv` is required; verified on a Puhti V100 32GB (sm_70). `gsnap`/`gmap` carry no device
  code — in `-s/--sam` mode the GPU is used only by the transformer.
- Full verified CLI flag list, and DeepSAP v0.0.3's measured output naming (the scored BAM
  has **no file extension**), are in the task brief this pipeline was built from and are not
  repeated here — see the module source comments for exactly which flags are used and why.

## Running it

```bash
# Local (apptainer, no SLURM) -- still requires a GPU node with --nv working:
nextflow run main.nf -profile standard \
    --input samplesheet.csv --fasta ref.fa --gtf ref.gtf \
    --deepsap_sif /path/to/deepsap.sif --ctmp /path/to/ctmp_dir \
    --outdir results

# Puhti, real run:
nextflow run main.nf -profile puhti \
    --input samplesheet.csv --fasta ref.fa --gtf ref.gtf \
    --ctmp /scratch/project_2009297/deepsap-feasibility/ctmp_canary \
    --outdir results
# (--deepsap_sif defaults to the known Puhti SIF path in conf/puhti.config)

# Cheap CI / dry-run on gputest (15 min limit, --test => "don't perform prediction"):
nextflow run main.nf -profile puhti,test --input <a real small BAM glob or samplesheet>
```

`samplesheet.csv`:
```csv
sample,bam
sample1,/path/to/sample1.bam
sample2,/path/to/sample2.bam
```
`--input` also accepts a bare glob, e.g. `--input '/path/to/bams/*.bam'` — `meta.id` is then
derived from each file's basename.

### Nextflow `-stub-run` vs DeepSAP's own `--test`

Two different "don't really run it" modes are wired up, deliberately kept separate:

- `nextflow run main.nf -stub-run ...` — Nextflow's own dry-run. The `stub:` block in each
  module runs instead of `script:`, touching placeholder files matching the real output
  naming — free, instant, tests only the pipeline's plumbing. **Note, confirmed by actually
  running it**: with a container engine enabled, Nextflow still launches the configured
  container for a stub run; only the script body run *inside* it changes. It does not skip
  the container. `DEEPSAP_TSJS`'s `beforeScript` (which stages this task's private `/tmp`
  copy) is written to detect `workflow.stubRun` and skip the real `cp` in that case, since a
  stub run has no real `--ctmp` content to copy on a first-ever checkout.
- `-profile test` (→ `params.test = true` → DeepSAP's own `--test` flag, "don't perform
  prediction") — actually launches the container and runs everything up to prediction. Costs
  a real (short) GPU allocation. Combine with `puhti` to route it to `gputest`.

## Validation performed

No cluster job was run for this pipeline (per the task brief). What *was* done, on the
machine this pipeline was written on, using a real local Nextflow install (no
apptainer/singularity available there, so the actual container was never launched):

- `nextflow lint .` — clean, zero errors, across all `.nf` and `.config` files. Caught two
  real errors (top-level statements outside a `workflow {}` block in `main.nf` — a pattern
  that breaks under current/strict Nextflow syntax) and several deprecation warnings
  (`Channel.xxx` → `channel.xxx`, an implicit closure `it`, a `workflow.onError` config
  handler), all fixed.
- A full `-stub-run` against a two-sample dummy samplesheet (fake FASTA/GTF/BAM content,
  container disabled) — exercised the complete DAG: samplesheet parsing, the `STAGE_CTMP` →
  `DEEPSAP_TSJS` gate via `.combine()`, `meta.id`/`--prefix` propagation, stub output
  generation, and `publishDir`. This is what caught a real bug: the initial `publishDir`
  configuration preserved DeepSAP's own `outdir/` output subdirectory in the published path
  (`<outdir>/deepsap/<sample>/outdir/<sample>`, not `<outdir>/deepsap/<sample>/<sample>` as
  documented) — fixed with a `saveAs` that strips the `outdir/` prefix, then re-verified.
- The same `-stub-run` re-run with `-resume`: `cached=3`, confirming the pipeline is
  resume-safe as designed.
- The glob form of `--input` (as opposed to a samplesheet CSV), confirmed to derive
  `meta.id` correctly from each file's basename.
- Running with a required param (`--fasta`) omitted, confirming `validateParameters()`
  reports the specific missing parameter clearly rather than failing opaquely.
- `DEEPSAP_TSJS`'s **real** (non-stub) `script:` block, run standalone against dummy
  fixtures with fake `samtools`/`sh` stand-ins on `PATH` and the container disabled. This
  reached (and correctly failed at) the point of invoking
  `sh /scripts/DeepSAP_wrapper.sh` — everything before that (the per-task `/tmp` copy via
  `beforeScript`, the FASTA/GTF copy, `samtools faidx`, the contig-overlap preflight) ran
  and produced correct intermediate files. This is also what caught a second real bug: a
  `cat <<-END_VERSIONS` heredoc terminator indented to visually nest inside an `if` block
  did not match after Nextflow's script dedenting (`<<-` strips leading *tabs*, not spaces),
  producing `syntax error: unexpected end of file` — invisible to `-stub-run`, which never
  executes a `script:` block, only `stub:`. Fixed by writing every heredoc (in both modules)
  fully flush-left, and `bash -n` was run against the generated `.command.sh` for both
  modules' real script bodies to confirm clean syntax.
- `nextflow_schema.json` / `assets/schema_input.json` needed `$schema` updated from draft-07
  to `https://json-schema.org/draft/2020-12/schema` — the installed nf-schema (2.7.3)
  refuses draft-07. The plugin version is now pinned to `nf-schema@2.7.3` (nf-schema itself
  refuses to run unpinned).

### Correction: the local validation above did not include a working `-stub-run`

The list above claims a `-stub-run` was performed. On the first real invocation
(Nextflow 25.10.2, Puhti) the pipeline **could not start at all**: `conf/modules.config`
contained an empty `withName: 'STAGE_CTMP' { }` block, which Nextflow parses as an assignment
to an unknown attribute and aborts on, before any task is scheduled:

```
ERROR ~ Unknown config attribute `process.withName:STAGE_CTMP`
```

An empty selector block is not an inert placeholder. Whatever ran locally, it cannot have been
this config. Fixed by deleting the block (the note in its place explains why it must stay
deleted). Treat the local-validation list as unverified provenance; the cluster results below
are the ones that were observed here.

### Cluster validation, 2026-07-19 (observed)

- `-stub-run` on Puhti after the config fix: full DAG green, `publishDir` layout correct.
- Real SLURM run, two samples, 4 tasks, 4m01s: `PREPARE_REFERENCE` and `STAGE_CTMP` on
  `small`, two `DEEPSAP_TSJS` tasks on `gpu` with `--gres=gpu:v100:1`.
- **Regression control passed**: the `gsnap` sample reproduced job 35520334's
  `junctions.tsv` and `probs.npy` at identical md5.
- STAR sample scored successfully: 1807 junctions, `js`/`jt`/`nj` tags on 1161 records, and
  the alignment rewrite documented below.

- `tests/test_fai_branches.sh`: all three index-resolution branches exercised. Sibling
  `<fasta>.fai` present → `PREPARE_REFERENCE` skipped; explicit `--fai` under a different
  filename → skipped; no index anywhere → it runs. All three publish. Worth doing separately
  because the cluster run only ever took the *build* branch (the malaria FASTA has no `.fai`),
  while branches 1 and 2 are what a human/mouse reference store will actually hit.

  The first version of that test reported "skipped" for **all three** cases, including the one
  that demonstrably builds the index. The bug was the test's: Nextflow abbreviates process
  names in its progress display (`PREPARE_REFERENCE` renders as `DEE…EFERENCE`), so grepping
  the console for the full name could never match. Re-done against `-with-trace`, which
  carries exact names. Same defect class as the two below — a measurement that returns a
  plausible answer instead of an error.

Two environment bugs found and fixed while doing this, both worth knowing for any sbatch here:
`set -u` aborts on `source /appl/profile/zz-csc-env.sh` (line 67 dereferences `LC_CTYPE`
unconditionally — job 35520844 died at 00:00:00 with no other output), and the Puhti login
node has 4 CPUs / 25 GB, so `process_gpu`'s 8 CPU / 64 GB cannot be stub-run there with the
`local` executor.

## The `/tmp` trap, and why every task stages its own copy

The full rationale is in `modules/local/stage_ctmp/main.nf` and
`modules/local/deepsap_tsjs/main.nf`. In short: `--ctmp` names a **persistent** host
directory that `STAGE_CTMP` populates once with a byte-verified copy of the image's
`/tmp/83`. Each `DEEPSAP_TSJS` task then `cp -r`'s `${ctmp}/83` into its own task work
directory and binds *that private copy* over `/tmp` — never the shared `--ctmp` directory
itself, read-write, across concurrent tasks. The task brief this pipeline was built from
explicitly flagged sharing one staged dir across concurrent tasks as unsafe and said
"verify, do not assume" for a read-only shared alternative; since this pipeline cannot run
compute to verify that, it defaults to the option that is safe by construction (independent
copies) at the cost of a few hundred MB and a few seconds of local copy per task — cheap
next to a GPU allocation.

## OOM handling

`DEEPSAP_TSJS`'s script greps its own captured log for a CUDA-OOM signature
(`CUDA out of memory` / `CUDA_ERROR_OUT_OF_MEMORY`) and, **only** on a positive match, exits
137. `conf/modules.config` retries exit-137 tasks up to twice, at `--batch 16 --set_size
5000` then `--batch 8 --set_size 2000` — the exact rungs measured to clear device OOM for
this container on a Puhti V100 32GB in `deepsap-cluster-feasibility`'s Stage 4. Any other
non-zero exit is never retried: `deepsap-cluster-feasibility`'s own operational history is
explicit that retrying an unrelated failure as though it were a capacity problem just burns
a second GPU allocation on the same bug.

## Judgement calls made

These were not spelled out in the task brief; here is what was decided and why.

1. **Explicit `sh /scripts/DeepSAP_wrapper.sh` invocation.** Nextflow's default containerized
   execution uses `apptainer/singularity exec` against the generated `.command.sh`, which
   bypasses the image's `ENTRYPOINT` entirely. Calling `/DeepSAP/DeepSAP` directly (skipping
   the wrapper) would miss six required flags the wrapper injects and fail argparse. This
   is a consequence of how Nextflow launches containers, not a new fact — but it is easy to
   get wrong, so the module invokes the wrapper explicitly and says why in a comment.
2. **`--home`, `--cleanenv`, `--writable-tmpfs`, and the `HF_HUB_OFFLINE=1`/
   `TRANSFORMERS_OFFLINE=1` env vars are carried over from `deepsap-cluster-feasibility`'s
   `common.sh`, not from this task's own fact list.** They address Singularity/Apptainer
   default behaviour (auto-mounting `$HOME`, host env leakage, a read-only rootfs) and an
   offline compute-node assumption (no route to Hugging Face Hub from a Puhti compute node)
   that were measured true for the *sibling* project's FASTQ-mode run on the same cluster
   and container. They have not been independently re-verified for this pipeline's `--sam`-
   mode invocation specifically.
3. **The FASTA index is built once by `PREPARE_REFERENCE`; FASTA/FAI/GTF are then staged as
   symlinks under fixed names via `stageAs`.** An earlier version instead `cp -L`'d the FASTA
   and GTF into *every* task, to dodge the case where a staged symlink points back at a
   read-only shared reference store and `.fai` creation fails late. That works on a 23 MB
   genome and is untenable at the scale this pipeline targets: GRCh38 (~3.1 GB) plus a
   GENCODE GTF (~1.4 GB) is ~4.5 GB copied *per sample*, so a 20-BAM batch moves ~90 GB to
   produce byte-identical results 20 times, and rebuilds the same index 20 times. Pre-building
   the `.fai` removes the *reason* for the copy rather than paying for it repeatedly: with the
   index already present beside the FASTA, nothing needs to write there at all. `--fai` and an
   existing `<fasta>.fai` sibling both short-circuit the build.
4. **A cheap BAM/FASTA contig-overlap preflight** was added inside the module, before
   invoking DeepSAP. Not explicitly requested, but directly operationalizes the task brief's
   own "reference compatibility" warning, and is nearly free next to a GPU allocation. It
   runs *after* the GPU has already been scheduled (it is inside the same task), so it saves
   compute time within the allocation but not queue time — a separate CPU-only preflight
   process would be needed for that; not implemented here to keep the module count down.
5. **`samtools quickcheck` + non-empty checks on the scored BAM and junctions TSV**, before
   the task is allowed to report success. Not explicitly requested; mirrors
   `deepsap-cluster-feasibility`'s own validation criteria ("do not declare success on exit
   code alone").
6. **The OOM retry ladder** (see above) is an addition beyond the literal ask ("resume-safe
   and one-BAM-per-task"). It reuses proven, measured values rather than inventing new ones,
   and is scoped narrowly (only fires on a positively identified OOM signature). Remove the
   `errorStrategy`/`maxRetries` lines in `conf/modules.config` if you'd rather fail loudly on
   the first OOM.
7. **Samplesheet parsing uses a manual `splitCsv` + validation closure**
   (`workflows/deepsap_tsjs.nf`), not nf-schema's `samplesheetToList()`, even though
   `assets/schema_input.json` is written in a form intended for that function. This pipeline
   has never been executed, so a dependency on that plugin function's exact schema-
   annotation behaviour across versions was avoided in favour of explicit, auditable code.
   Swap to `samplesheetToList()` once you've confirmed it against your pinned nf-schema
   version.
8. **GPU resourcing uses explicit `clusterOptions '--gres=gpu:v100:1'`** rather than
   Nextflow's `accelerator` directive, for certainty that the generated `sbatch` flag matches
   exactly what was measured to work.
9. **`STAGE_CTMP`'s own verification is a single byte-count check**, not the full
   manifest + path-count system `common.sh` implements (which also protects against the
   image growing new files under `/tmp/83` beyond the one checkpoint tarball). This
   pipeline's atomic stage-then-rename pattern means a killed task can never leave a
   *partial* tree at `--ctmp`, but it inherits a narrower notion of "complete" than the
   sibling project's manifest — fine for this image's measured `/tmp/83` shape (1 file / 5
   paths per `deepsap-cluster-feasibility`'s own measurement), but worth knowing if that
   shape ever changes.

## What I could not verify

Per the task brief's own instruction: these are gaps, not guesses.

**Corrected 2026-07-19.** Three items previously listed here were wrong or are now closed:

- ~~"No BAM-only (`-s/--sam`) invocation has actually been run anywhere in this workspace."~~
  **This was false when written.** Job 35520334 had already run `--sam` mode, feeding a GSNAP
  BAM back in and reproducing byte-identical `junctions.tsv`/`probs.npy`. It has since been
  run twice more through this pipeline itself.
- ~~"`conf/test.config` has no real BAM to point at."~~ Closed: two known BAMs now exist —
  `star_test/star_Aligned.sortedByCoord.out.bam` (STAR, coordinate-sorted, 19966 records) and
  `outputdir/run_35519462/test_run_10K_default_gsnap.bam` (GSNAP, with a known-good expected
  output usable as a regression control).
- ~~"`puhti_cpu_partition = 'small'` is not one of the measured facts."~~ Verified: `sinfo`
  lists `fmi gpu test large small fmitest gputest hugemem longrun interactive
  hugemem_longrun`, and both `PREPARE_REFERENCE` and `STAGE_CTMP` have since run there.

Still genuinely open:

- **Whether TSJS's scoring is calibrated for the species you are running.** The STAR test was
  *P. falciparum*, where 48.2% of junctions that the GTF itself annotates score below 50, and
  47% of spliced alignments were un-spliced. DNABERT-6 and the TSJS head are presumed
  human-trained, so this rate may be a species artefact that does not appear on human/mouse —
  **or it may not be.** Nothing here measures that. This is the single most important thing
  to check before trusting scores on your own data; see "Recommended first run".
- **Human/mouse scale.** The largest input tested is a 23 MB genome, 19966 records, 1807
  junctions. Nothing here bounds GPU memory or runtime for a human BAM with orders of
  magnitude more junctions. `process_gpu` is 8 CPU / 64 GB / 2 h, carried over from a malaria
  run; expect to raise `time` at minimum.
- **How secondary alignments are treated.** STAR emitted 796 secondary records; 792 survived
  and only 2 carried a `js` tag, so they largely pass through unscored. Whether that is
  intended, and whether you should pre-filter multimappers, is untested.
- **Whether `--test` still requires a working `--nv`/CUDA init** is unknown — "don't perform
  prediction" doesn't confirm whether model loading still happens first. Treat the `test`
  profile as intended for `gputest`, not necessarily runnable on a machine with no GPU at
  all.
- **CRAM input is not supported by this pipeline's samplesheet schema.** The verified CLI
  help text says `-s/--sam` takes "the SAM/BAM file"; CRAM is never mentioned for input, so
  `assets/schema_input.json` and the workflow's validation reject anything but `.bam`/`.sam`.
  (CRAM *does* appear in `deepsap-cluster-feasibility`'s output-name search list, but that is
  about output naming variability, not confirmed input support.)
- **`HF_HUB_OFFLINE=1`/`TRANSFORMERS_OFFLINE=1` and the `--home`/`--cleanenv`/
  `--writable-tmpfs` flags** (judgement call #2 above) were measured true for a different
  invocation mode (FASTQ, on the sibling project) and are carried over, not independently
  re-verified for `--sam` mode.
- This pipeline has not been run through `nf-core pipelines lint` or `nf-core pipelines
  schema lint` — it follows nf-core conventions where they fit, but has not been validated
  by nf-core's own tooling.

## Outputs

Published under `${outdir}/deepsap/<sample>/`:

| File | Description |
|---|---|
| `<sample>` | The TSJS-scored BAM (BGZF, **no file extension** — this is not a bug in the publish pattern) |
| `<sample>_junctions.tsv` | Columns `ID, Signla, Type, Score, Donor, Acceptor` (`Signla` is upstream's own typo, kept verbatim) |
| `<sample>_prediction_batch_N/` | `dev.csv`, `dev_6mer.json`, `probs.npy` (float32, shape `(n,3)`: donor/acceptor/neither) |

Scored-BAM tags added by TSJS: `js` (junction score 0–100), `jt` (junction type), `nj`
(junction count).

## Getting the image

**You do not have to download anything by hand.** `params.deepsap_sif` defaults to the NGC
image pinned by digest, and apptainer pulls and converts it on first use:

```
docker://nvcr.io/nvidia/clara/clara-parabricks-deepsap@sha256:d437752a03761b8c73aab1962e1aed877c58f99844f7b4856b676a2257becebf
```

Anonymous pull is confirmed working — no NGC login, no API key. It is ~19.3 GB across 83
layers and converts to a ~12 GB SIF.

**Set BOTH of these before the first run.** One is not enough, and getting it wrong fails
after several GB have already been transferred:

```bash
export NXF_APPTAINER_CACHEDIR=/scratch/<proj>/sifcache   # where Nextflow keeps the final .img
export APPTAINER_CACHEDIR=/scratch/<proj>/apptainer_cache # where apptainer keeps LAYER BLOBS
```

They are different caches owned by different tools. `NXF_APPTAINER_CACHEDIR` only decides
where the finished `.img` lands; `apptainer pull` still writes every intermediate layer blob
to `$APPTAINER_CACHEDIR`, which **defaults to `$HOME/.apptainer/cache`**. On a cluster with a
home quota that is exactly where it dies:

```
FATAL: While making image from oci registry: ... writing blob:
       write /users/<me>/.apptainer/cache/blob/oci-put-blob...: disk quota exceeded
```

Observed here on Puhti (10 GB home quota) with `NXF_APPTAINER_CACHEDIR` correctly set — the
final image location was right and the blobs still went to `$HOME`. `main.nf` now warns at
startup when a `docker://` image is requested and `APPTAINER_CACHEDIR` is unset.

**Pinned by digest, not `:latest`, on purpose.** Everything this pipeline asserts about
DeepSAP — the wrapper's injected flags, the `/tmp/83` checkpoint and its exact byte count, the
extensionless output name, the `js`/`jt`/`nj` tags — was measured against *this* image. A
floating tag would let NVIDIA change any of that silently under a pipeline that would keep
exiting 0. (At the time of pinning, this digest *was* `:latest`.)

### Where the pull actually happens

**On the head node, before any task is submitted** — not on a compute node. Verified from the
Nextflow log: `nextflow.container.SingularityCache - Pulling Apptainer image docker://...`
appears with a `Submitted process` count of zero.

(An earlier version of this section claimed the opposite. It was wrong, and the practical
consequences are the reverse of what it implied: compute nodes needing internet access is
*not* a concern, but the head node's environment and its `$HOME` quota very much are.)

### When to pre-pull instead

Pre-pulling is still worth it when you run the pipeline repeatedly, want the ~19 GB transfer
off the login node, or are on a site that restricts outbound traffic from the head node. Pull
once and point at the file:

```bash
apptainer pull /scratch/<proj>/deepsap.sif \
  docker://nvcr.io/nvidia/clara/clara-parabricks-deepsap@sha256:d437752a03761b8c73aab1962e1aed877c58f99844f7b4856b676a2257becebf

nextflow run ... --deepsap_sif /scratch/<proj>/deepsap.sif
```

`-profile puhti` already does this — it overrides `deepsap_sif` with a local SIF, so it never
pulls. Note `apptainer.pullTimeout` is raised to `3h` here: Nextflow's 20-minute default is
not reliably enough for 19 GB, and when it is not, the failure is a mid-transfer timeout that
does not name the real cause.

## Running elsewhere (Singularity, other clusters)

Profiles are composable: pick one **engine** and one **executor/site**.

| Profile | Kind | Notes |
|---|---|---|
| `apptainer` | engine | Default; enabled even when no profile is given |
| `singularity` | engine | SingularityCE |
| `standard` | executor | Local execution |
| `slurm` | executor | Generic SLURM — supply the params below |
| `puhti` | site | CSC Puhti; sets account/partitions/gres/SIF, selects apptainer |
| `test` | site | Regression run against a BAM with a known-good md5 |

On any other SLURM cluster — **apptainer is the default engine**, so it does not need naming:

```bash
nextflow run main.nf -profile slurm \
    --account          my_project \
    --gpu_partition    gpu \
    --cpu_partition    small \
    --gpu_gres         'gpu:a100:1' \
    --container_module apptainer \
    --deepsap_sif      /path/to/deepsap.sif \
    --ctmp             /scratch/me/deepsap_ctmp \
    --input samplesheet.csv --fasta ref.fa --gtf ref.gtf --outdir results
```

`--container_module` loads an environment module on the **compute node** before the container
is invoked. Drop it if apptainer is already on the compute-node PATH; include it otherwise.
This is the portability trap Puhti cannot reveal — apptainer lives at `/usr/bin` there, so no
module is needed, while on many clusters it is module-only and the failure surfaces as
`apptainer: command not found` from a job that submitted perfectly.

Every site value is a null-defaulted param and a flag is emitted **only when set** — clusters
differ on whether `--account` exists at all, and on whether GPUs come from `--gres`, a
partition alone, or `--gpus`. Set `--gpu_gres null` (or `''`) to omit `--gres` entirely;
`--gpu_extra` appends arbitrary sbatch flags.

`conf/puhti.config` is a 20-line instantiation of `conf/slurm.config`. Copying it is the
easiest way to add a site permanently.

### The one hard portability constraint

`STAGE_CTMP` requires the engine to support **`--no-mount tmp`**. It is the only way to read
the TSJS checkpoint out of the image's own `/tmp/83`, which the engine otherwise hides by
mounting the host `/tmp` over it. Apptainer has always had it; SingularityCE has had it
[since 3.7.0](https://docs.sylabs.io/guides/latest/user-guide/cli/singularity_exec.html)
(2020). `STAGE_CTMP`'s `beforeScript` checks for the flag on the host and fails with an
actionable message rather than letting the container launch die cryptically.

If you are stuck on an engine without it: stage `--ctmp` once on any machine that has a newer
one, and point `--ctmp` at the result. `STAGE_CTMP` then finds a byte-verified copy and skips
the extraction entirely — nothing else in the pipeline needs `--no-mount`.

### What is and is not verified here

Verified on Puhti by `tests/test_profiles.sh` (all assertions green): engine selection for
every profile; `-profile puhti` unchanged by the restructure; that `-profile slurm` **alone**
resolves to apptainer and actually invokes it; that `--container_module` produces a real
`nxf_module_load` call which precedes the `nxf_launch` call; and the **actual generated
`#SBATCH` headers** for three cases — all params set (`--gres` and `--account` both present),
`--gpu_gres null` (no `--gres` line, `--account` still present), and no account (no `--account`
line anywhere). Header assertions read `.command.run`, not `nextflow config`, because
`clusterOptions` is a closure that `nextflow config` prints unevaluated — it would prove
nothing.

Four of those assertions had to be re-aimed before they meant anything, all the same way —
matching a *declaration* instead of a *call site*, or matching too broadly:

| Pattern | What it actually matched | Effect |
|---|---|---|
| `grep 'apptainer.enabled = true'` | nothing — `nextflow config` prints nested blocks | every profile read as "engine off" |
| `grep 'module load'` | the `nxf_module_load()` **body**, always present | OK even when no module was set |
| `grep '^\s*nxf_launch'` | the function **definition** at line 123 | correct order reported as inverted |
| `grep -l 'DEEPSAP_TSJS'` | **every** task (all names start `DEEPSAP_TSJS_WF`) | passed or failed by directory hash order |

The last one is the instructive one: it passed one run and failed the next on identical code.
A test that is right by luck is indistinguishable from one that is right.

**Not verified: real SingularityCE.** Puhti ships `singularity` as a symlink to apptainer
1.3.6, so exercising the profile there tests the Nextflow wiring and nothing about Sylabs'
implementation. Treat the first run on a genuine SingularityCE site as the real test.

## DeepSAP rewrites your alignments

**The scored BAM is not the input BAM plus three tags.** When TSJS rejects a junction, the
supporting alignment is *un-spliced in place*: the block on the far side of the intron is
converted to a soft clip and **POS moves**. Measured on the STAR test:

```
IN : flag=99  pos=831258  cigar=49M205N102M
OUT: flag=99  pos=831512  cigar=49S102M          (831258 + 49 + 205 = 831512)

IN : flag=83  pos=1362174 cigar=145M125N5M
OUT: flag=83  pos=1362444 cigar=145S5M
```

Aggregate effect on that run (19966 records in and out — the record *count* is preserved,
which is why this is easy to miss):

| | input | output |
|---|---|---|
| spliced (N-CIGAR) records | 2203 | 1171 |
| total N operations | 2597 | 1367 |
| reads with ≥1 spliced alignment | 1235 | 1118 |
| secondary (0x100) records | 796 | 792 |

So **47% of STAR's spliced alignments were un-spliced**, and 117 reads stopped being spliced
altogether. No read gained splicing.

This follows from the filter in the image's own `parameters_config.json` —
`min_novel_score=50`, `min_annotated_score=0` — and the junction table is consistent with it:
of 1807 junctions, 926 were `Novel` and 855 of those scored below 50, while all 881 annotated
junctions were retained regardless of score (425 of them scored below 50).

Practical consequences:

- Do **not** feed the scored BAM to a junction quantifier expecting it to represent your
  aligner's output. It represents DeepSAP's filtered view of it.
- Keep the input BAM. The rewrite is not reversible from the output alone.
- Coordinate sort order is preserved in the header (`SO:coordinate`), but POS changes mean
  the records are **no longer guaranteed to be in coordinate order**. Re-sort before indexing.
  (Not yet verified how far out of order they get.)

## Recommended first run

Before scoring a real batch, run one representative BAM and check whether the scores are
calibrated for your species — this is the open risk, not the plumbing:

```bash
nextflow run main.nf -profile puhti \
    --input one_sample.csv --fasta GRCh38.primary_assembly.genome.fa \
    --gtf gencode.v44.annotation.gtf --ctmp /scratch/<proj>/deepsap_ctmp \
    --outdir results_pilot
```

Then look at the annotated-junction score distribution:

```bash
awk -F'\t' 'NR>1 && $3!="Novel" {n++; if ($4<50) low++} \
            END {printf "annotated: %d, below 50: %d (%.1f%%)\n", n, low, 100*low/n}' \
    results_pilot/deepsap/*/*_junctions.tsv
```

Junctions the GTF itself annotates are the closest thing to a ground-truth positive set. If a
large fraction of them scores low on human — as happened on *P. falciparum* (48.2%) — the
model is not discriminating on your data and the novel calls should not be trusted. If that
fraction is small, the *P. falciparum* result was a species artefact and the scores are
behaving. Either way you will know from one BAM instead of finding out after a batch.
