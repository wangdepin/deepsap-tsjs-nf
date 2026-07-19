//
// Build the FASTA index ONCE for the whole batch.
//
// Why this process exists at all: DeepSAP cuts +/-150bp windows around each junction, so it
// needs random access into the FASTA, and every standard route to that (samtools faidx,
// pysam.FastaFile, pyfaidx) creates <fasta>.fai on first open if it is missing. A shared
// reference store is usually read-only, so the earlier version of this pipeline sidestepped
// that by `cp -L`-ing the FASTA and GTF into every task directory. On the 23 MB P. falciparum
// genome that cost nothing. On the references this pipeline is actually aimed at -- GRCh38
// (~3.1 GB) or GRCm39 with a GENCODE GTF (~1.4 GB) -- it is ~4.5 GB of Lustre traffic and a
// redundant index build PER SAMPLE, which for a 20-BAM batch is ~90 GB copied to produce
// byte-identical results 20 times. (This project has already hit a Lustre quota twice.)
//
// Building the index once here removes the reason for the copy entirely: with the .fai
// present, nothing needs to write next to the FASTA, so the scoring tasks can stage both
// files as plain symlinks.
//
process PREPARE_REFERENCE {
    tag "${fasta.name}"
    label 'process_low'

    container params.deepsap_sif

    // samtools writes the index to "<the path it was given>.fai" -- it does NOT resolve the
    // symlink first. Staging as reference.fasta therefore produces reference.fasta.fai here
    // in the (writable) task directory, leaving the shared reference store untouched, and
    // fixes the name that DEEPSAP_TSJS expects to find beside its own staged FASTA.
    input:
    path(fasta, stageAs: 'reference.fasta')

    output:
    path 'reference.fasta.fai', emit: fai
    path 'versions.yml'       , emit: versions

    // Flush-left throughout, matching the sibling modules: a heredoc terminator has to sit at
    // column 0 to match, and this project has already been bitten once by an indented one
    // that broke silently (a `-stub-run` never exercises a script: block, only stub:).
    script:
    """
set -euo pipefail

# Content check, not a filename check. This pipeline's parent project lost time to an
# extension-based format guess that did not error -- it silently returned a fabricated
# record count -- so the format is determined by reading the first two bytes.
magic=\$(head -c2 reference.fasta | od -An -tx1 | tr -d ' \\n')
if [ "\$magic" = "1f8b" ]; then
echo "[prepare_reference] FATAL: --fasta is gzip/bgzip-compressed (magic 1f8b)." >&2
echo "[prepare_reference] Only a plain, uncompressed FASTA has been verified against this" >&2
echo "[prepare_reference] DeepSAP container. Decompress it once and point --fasta at the" >&2
echo "[prepare_reference] result. Failing here is deliberate: a bgzip'd FASTA also needs a" >&2
echo "[prepare_reference] .gzi that this pipeline does not stage, and the resulting failure" >&2
echo "[prepare_reference] further downstream would be much harder to read than this line." >&2
exit 1
fi

samtools faidx reference.fasta

cat <<END_VERSIONS > versions.yml
"${task.process}":
    samtools: \$(samtools --version | head -1 | sed 's/^samtools //')
END_VERSIONS
"""

    stub:
    """
touch reference.fasta.fai

cat <<END_VERSIONS > versions.yml
"${task.process}":
    samtools: "stub"
END_VERSIONS
"""
}
