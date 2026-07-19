#!/usr/bin/env nextflow
//
// deepsap-tsjs-nf -- score an EXISTING BAM with DeepSAP's TSJS transformer only.
// No GSNAP alignment: this pipeline calls DeepSAP in -s/--sam mode exclusively.
//
// See README.md for the operational contract this pipeline implements, and
// private_projects/deepsap-cluster-feasibility for the measured evidence it is drawn from.
//
nextflow.enable.dsl = 2

include { validateParameters; paramsHelp } from 'plugin/nf-schema'
include { DEEPSAP_TSJS_WF } from './workflows/deepsap_tsjs'

workflow {
    // Fail fast and loud rather than silently continuing with a partial run. (Set here,
    // inside the entry workflow, rather than as a `workflow.onError` config handler --
    // the latter is deprecated in current Nextflow releases.)
    workflow.onError = {
        log.error "Pipeline failed: ${workflow.errorMessage}"
    }

    if (params.help) {
        log.info paramsHelp(
            'nextflow run main.nf -profile <standard|puhti>[,test] ' +
            '--input samplesheet.csv --fasta ref.fa --gtf ref.gtf --outdir results ' +
            '--deepsap_sif /path/to/deepsap.sif --ctmp /path/to/ctmp_dir'
        )
        exit 0
    }

    validateParameters()

    // Warn BEFORE ~19 GB starts moving. Nextflow pulls a docker:// image on the HEAD NODE
    // before submitting any task, and NXF_APPTAINER_CACHEDIR only decides where the finished
    // .img lands -- `apptainer pull` still writes every intermediate layer blob to
    // APPTAINER_CACHEDIR, which defaults to $HOME/.apptainer/cache. On a cluster with a home
    // quota that combination dies partway through with "disk quota exceeded" naming a path
    // the user never configured. Observed on Puhti with NXF_APPTAINER_CACHEDIR set correctly.
    if (params.deepsap_sif?.toString()?.startsWith('docker://') && !System.getenv('APPTAINER_CACHEDIR')
            && !System.getenv('SINGULARITY_CACHEDIR')) {
        log.warn """
        |A docker:// image will be pulled (~19.3 GB of layers) and APPTAINER_CACHEDIR is unset,
        |so apptainer will cache layer blobs under \$HOME/.apptainer/cache. If \$HOME is
        |quota-limited the pull fails partway through with "disk quota exceeded". Set BOTH:
        |    export APPTAINER_CACHEDIR=/scratch/<proj>/apptainer_cache
        |    export NXF_APPTAINER_CACHEDIR=/scratch/<proj>/sifcache
        |Or pass --deepsap_sif /path/to/local.sif to skip the pull entirely.
        """.stripMargin()
    }

    DEEPSAP_TSJS_WF()
}
