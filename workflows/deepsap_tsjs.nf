include { STAGE_CTMP        } from '../modules/local/stage_ctmp/main'
include { PREPARE_REFERENCE } from '../modules/local/prepare_reference/main'
include { DEEPSAP_TSJS      } from '../modules/local/deepsap_tsjs/main'

workflow DEEPSAP_TSJS_WF {

    main:
    ch_versions = channel.empty()

    // ---- Reference inputs: one FASTA/GTF pair shared by every sample. checkIfExists here
    // gives a clear Nextflow-level error for a typo'd path rather than a cryptic apptainer
    // bind-mount failure inside the container. .first() turns each into a value channel so
    // it can be reused across every DEEPSAP_TSJS invocation without being consumed. ----
    ch_fasta = channel.fromPath(params.fasta, checkIfExists: true).first()
    ch_gtf   = channel.fromPath(params.gtf,   checkIfExists: true).first()

    // ---- The FASTA index, resolved once for the whole batch (never per sample -- see
    // modules/local/prepare_reference for the cost that avoids on a human/mouse reference).
    // Three sources, in order of preference:
    //   1. --fai, when the user knows where the index is;
    //   2. an existing <fasta>.fai sibling, which is how shared reference stores normally
    //      ship (checked on the HOST at parse time -- this costs nothing and skips the job
    //      entirely for the common case);
    //   3. PREPARE_REFERENCE, which builds it in one task.
    // Note the asymmetry with the checks above: `file(...).exists()` here is a probe whose
    // false branch is a valid, handled state, whereas a missing --fasta is a user error. ----
    if (params.fai) {
        ch_fai = channel.fromPath(params.fai, checkIfExists: true).first()
    }
    else if (file("${params.fasta}.fai").exists()) {
        ch_fai = channel.fromPath("${params.fasta}.fai", checkIfExists: true).first()
    }
    else {
        PREPARE_REFERENCE(ch_fasta)
        ch_versions = ch_versions.mix(PREPARE_REFERENCE.out.versions)
        // No .first() here: ch_fasta is already a value channel, so PREPARE_REFERENCE's
        // outputs are value channels too and reusable across every sample as-is. Adding
        // .first() would be a no-op that Nextflow warns about at runtime.
        ch_fai = PREPARE_REFERENCE.out.fai
    }

    // ---- Samples: a 'sample,bam' samplesheet CSV, or a bare glob of BAM/SAM files.
    // Parsed manually via splitCsv rather than nf-schema's samplesheetToList -- see README
    // "What I could not verify" for why: this pipeline has not been executed, so a
    // dependency on that plugin function's exact schema-annotation behaviour across
    // versions was avoided in favour of an explicit, auditable check here. ----
    if (params.input.toLowerCase().endsWith('.csv')) {
        ch_input = channel
            .fromPath(params.input, checkIfExists: true)
            .splitCsv(header: true)
            .map { row ->
                if (!row.sample || !row.bam) {
                    error "Samplesheet row missing required 'sample' or 'bam' column: ${row}"
                }
                def bam = file(row.bam)
                if (!bam.exists()) {
                    error "BAM listed in samplesheet does not exist: ${row.bam}"
                }
                if (!(bam.name.endsWith('.bam') || bam.name.endsWith('.sam'))) {
                    error "DeepSAP's -s/--sam expects a .bam or .sam file; got: ${bam.name}"
                }
                tuple([id: row.sample], bam)
            }
    } else {
        ch_input = channel
            .fromPath(params.input, checkIfExists: true)
            .map { bam -> tuple([id: bam.baseName], bam) }
    }

    // ---- Stage (or verify) the host /tmp tree DeepSAP's entrypoint needs; see the module
    // for the full rationale. Runs once. Every DEEPSAP_TSJS task is gated on its
    // completion via .combine() so no scoring task can start before params.ctmp holds a
    // byte-verified checkpoint tree -- without this gate, a first-ever run could race the
    // staging task against the scoring tasks and have some of them bind an incomplete
    // copy. ----
    STAGE_CTMP()
    ch_versions = ch_versions.mix(STAGE_CTMP.out.versions)

    ch_gated_input = ch_input
        .combine(STAGE_CTMP.out.versions)
        .map { meta, bam, _ctmp_versions -> tuple(meta, bam) }

    DEEPSAP_TSJS(ch_gated_input, ch_fasta, ch_fai, ch_gtf)
    ch_versions = ch_versions.mix(DEEPSAP_TSJS.out.versions)

    emit:
    scored_bam         = DEEPSAP_TSJS.out.scored_bam
    junctions          = DEEPSAP_TSJS.out.junctions
    prediction_batches = DEEPSAP_TSJS.out.prediction_batches
    versions           = ch_versions
}
