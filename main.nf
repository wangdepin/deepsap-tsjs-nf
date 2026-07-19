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

    DEEPSAP_TSJS_WF()
}
