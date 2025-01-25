/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// Function to check samples are internally consistent after being grouped
//
// Logic borrowed from nf-core rnaseq:
// https://github.com/nf-core/rnaseq/blob/b96a75361a4f1d49aa969a2b1c68e3e607de06e8/subworkflows/local/utils_nfcore_rnaseq_pipeline/main.nf#L158-L174
def checkSamplesAfterGrouping(input) {
    def (metas, input_files) = input[1..2]

    seq_type_ok = metas.collect{ it.seq_type }.unique().size == 1
    if (!seq_type_ok) {
        error(
            "Check input samplesheet -> Multiple runs of the same "
            + "sample must have the same sequence type: ${metas[0].id}"
        )
    }

    data_type_ok = metas.collect{ it.data_type }.unique().size == 1
    if (!data_type_ok) {
        error(
            "Check input samplesheet -> Multiple runs of the same "
            + "sample must have the same data type (fastq only, bam "
            + "concatenation not currently supported): ${metas[0].id}"
        )
    }

    if (metas.collect{ it.data_type }.unique() == "bam") {
        bam_count_ok = metas.collect{ it.data_type }.size == 1
        if(!bam_count_ok) {
            error(
                "Check input samplesheet -> Multiple runs of the same "
                + "bam sample is not currently supported: ${metas[0].id}"
            )
        }
    }

    // Check that multiple runs of the same sample are of the same datatype i.e. single-end / paired-end
    def endedness_ok = metas.collect{ meta -> meta.single_end }.unique().size == 1
    if (!endedness_ok) {
        error(
            "Check input samplesheet -> Multiple runs of the same "
            + "sample must be of the same datatype i.e. single-end or "
            + "paired-end: ${metas[0].id}"
        )
    }

    return [ metas[0], input_files ]
}