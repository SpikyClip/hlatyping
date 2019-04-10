#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/hlatyping
========================================================================================
 nf-core/hlatyping Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/hlatyping

 #### Authors
 Sven Fillinger sven1103 <sven.fillinger@qbic.uni-tuebingen.de> - https://github.com/sven1103>
 Christopher Mohr christopher-mohr <christopher.mohr@uni-tuebingen.de>
 Alexander Peltzer <alexander.peltzer@qbic.uni-tuebingen.de> - https://github.com/apeltzer
----------------------------------------------------------------------------------------
*/
def readParamsFromJsonSettings() {
    List paramsWithUsage
    try {
        paramsWithUsage = tryReadParamsFromJsonSettings()
    } catch (Exception e) {
        println "Could not read parameters settings from Json. $e"
        paramsWithUsage = Collections.emptyMap()
    }
    return paramsWithUsage
}

def tryReadParamsFromJsonSettings() throws Exception{
    def paramsContent = new File(config.params_description.path).text
    def paramsWithUsage = new groovy.json.JsonSlurper().parseText(paramsContent)
    return paramsWithUsage.get('parameters')
}

def formatParameterHelpData(param) {
	result = [ name: param.name, value: '', usage: param.usage ]
	// value descibes the expected input for the param
	result.value = (param.type == boolean.toString()) ? '' : param.choices ?: param.type ?: ''
	return result
}

String prettyFormatParamGroupWithPaddingAndIndent (List paramGroup,
                                                   String groupName,
                                                   Integer padding=2,
                                                   Integer indent=4) {
	    def maxParamNameLength = paramGroup.collect { it.name.size() }.max()
        def paramChoices = paramGroup.findAll{ it.choices }.collect { it.choices }
        def maxChoiceStringLength = paramChoices.collect { it.toString().size()}.max()
        def maxTypeLength = paramGroup.collect { (it.type as String).size() }.max()

        print maxChoiceStringLength

	    def paramsFormattedList = paramGroup.sort { it.name }.collect {
				Map param ->
					paramHelpData = formatParameterHelpData(param)
					sprintf("%${indent}s%-${maxParamNameLength + padding}s%-${maxChoiceStringLength + padding}s %s\n", "", "--${paramHelpData.name}","${paramHelpData.value}", "${paramHelpData.usage}")
			}
		return String.format("%s:\n%s", groupName.toUpperCase(), paramsFormattedList.join()).stripIndent()
}

// choose the indent depending on the spacing in this file
// in this example there are 4 spaces for every intendation so we choose 4
String prettyFormatParamsWithPaddingAndIndent(List paramsWithUsage, Integer padding=2, Integer indent=4) {

		def groupedParamsWithUsage = paramsWithUsage.groupBy { it.group }
		def formattedParamsGroups = groupedParamsWithUsage.collect {
			prettyFormatParamGroupWithPaddingAndIndent ( it.value, it.key, padding, indent)
		}
		return formattedParamsGroups.join('\n')
}

def helpMessage(paramsWithUsage) {
		def helpMessage = String.format(
		"""\
    =========================================
     nf-core/hlatyping v${workflow.manifest.version}
    =========================================
    Usage:

    The typical command for running the pipeline is as follows:
    nextflow run nf-core/hlatyping --reads '*_R{1,2}.fastq.gz' -profile docker

    Options:

    %s
    """.stripIndent(), prettyFormatParamsWithPaddingAndIndent(paramsWithUsage, 2, 4))
    log.info helpMessage
}

/*
 * SET UP CONFIGURATION VARIABLES
 */
def paramsWithUsage = readParamsFromJsonSettings()

// Show help emssage
if (params.help){
    helpMessage(paramsWithUsage)
    exit 0
}

// Check if genome exists in the config file
if (params.genomes && params.genome && !params.genomes.containsKey(params.genome)) {
    exit 1, "The provided genome '${params.genome}' is not available in the iGenomes file. Currently the available genomes are ${params.genomes.keySet().join(", ")}"
}

// TODO nf-core: Add any reference files that are needed
// Configurable reference genomes
fasta = params.genome ? params.genomes[ params.genome ].fasta ?: false : false
if ( params.fasta ){
    fasta = file(params.fasta)
    if( !fasta.exists() ) exit 1, "Fasta file not found: ${params.fasta}"
}


// Validate inputs
params.reads ?: params.readPaths ?: { log.error "No read data privided. Make sure you have used the '--reads' option."; exit 1 }()
(params.seqtype == 'rna' || params.seqtype == 'dna') ?: { log.error "No or incorrect sequence type provided, you need to add '--seqtype 'dna'' or '--seqtype 'rna''."; exit 1 }()
if( params.bam ) params.index ?: { log.error "For BAM option, you need to provide a path to the HLA reference index (yara; --index) "; exit 1 }()
params.outdir = params.outdir ?: { log.warn "No output directory provided. Will put the results into './results'"; return "./results" }()

// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if( !(workflow.runName ==~ /[a-z]+_[a-z]+/) ){
  custom_runName = workflow.runName
}

if( workflow.profile == 'awsbatch') {
  // AWSBatch sanity checking
  if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
  // Check outdir paths to be S3 buckets if running on AWSBatch
  // related: https://github.com/nextflow-io/nextflow/issues/813
  if (!params.outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
  // Prevent trace files to be stored on S3 since S3 does not support rolling files.
  if (workflow.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}

// Stage config files
ch_multiqc_config = Channel.fromPath(params.multiqc_config)
ch_output_docs = Channel.fromPath("$baseDir/docs/output.md")

/*
 * Create a channel for input read files
 */
if( params.readPaths ){
    if( params.singleEnd || params.bam) {
        Channel
            .from( params.readPaths )
            .map { row -> [ row[0], [ file( row[1][0] ) ] ] }
            .ifEmpty { exit 1, "params.readPaths or params.bams was empty - no input files supplied!" }
            .set { input_data }
    } else {
        Channel
            .from( params.readPaths )
            .map { row -> [ row[0], [ file( row[1][0] ), file( row[1][1] ) ] ] }
            .ifEmpty { exit 1, "params.readPaths or params.bams was empty - no input files supplied!" }
            .set { input_data }
        }
} else if (!params.bam){
    Channel
    .fromFilePairs( params.reads, size: params.singleEnd ? 1 : 2 )
    .ifEmpty { exit 1, "Cannot find any reads matching: ${params.reads}\nNB: Path needs" +
    "to be enclosed in quotes!\nNB: Path requires at least one * wildcard!\nIf this is single-end data, please specify --singleEnd on the command line." }
    .set { input_data }
} else {
    Channel
    .fromPath( params.reads )
    .map { row -> [ file(row).baseName, [ file( row ) ] ] }
    .ifEmpty { exit 1, "Cannot find any bam file matching: ${params.reads}\nNB: Path needs" +
    "to be enclosed in quotes!\n" }
    .dump() //For debugging purposes
    .set { input_data }
}

if( params.bam ) log.info "BAM file format detected. Initiate remapping to HLA alleles with yara mapper."

log.info nfcoreHeader()
def summary = [:]

if(workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']     = custom_runName ?: workflow.runName
summary['File Type']    = params.bam ? 'BAM' : 'Other (fastq, fastq.gz, ...)'
summary['Seq Type']   = params.seqtype
summary['Index Location'] = params.base_index + params.seqtype
summary['IP solver']    = params.solver
summary['Enumerations'] = params.enumerations
summary['Beta'] = params.beta
summary['Prefix'] = params.prefix
summary['Max Memory']   = params.max_memory
summary['Max CPUs']     = params.max_cpus
summary['Max Time']     = params.max_time
summary['Output dir']   = params.outdir
summary['Working dir']  = workflow.workDir
summary['Reads']            = params.reads
summary['Fasta Ref']        = params.fasta
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if(workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Script dir']       = workflow.projectDir
summary['User']             = workflow.userName
if(workflow.profile == 'awsbatch'){
   summary['AWS Region']    = params.awsregion
   summary['AWS Queue']     = params.awsqueue
}
summary['Config Profile'] = workflow.profile
if(params.config_profile_description) summary['Config Description'] = params.config_profile_description
if(params.config_profile_contact)     summary['Config Contact']     = params.config_profile_contact
if(params.config_profile_url)         summary['Config URL']         = params.config_profile_url
if(params.email) {
  summary['E-mail Address']  = params.email
  summary['MultiQC maxsize'] = params.maxMultiqcEmailFileSize
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "\033[2m----------------------------------------------------\033[0m"

// Check the hostnames against configured profiles
checkHostname()

def create_workflow_summary(summary) {

    def yaml_file = workDir.resolve('workflow_summary_mqc.yaml')
    yaml_file.text  = """
    id: 'nf-core-hlatyping-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/hlatyping Workflow Summary'
    section_href: 'https://github.com/nf-core/hlatyping'
    plot_type: 'html'
    data: |
        <dl clas s =\"dl-horizontal\">
${summary.collect { k,v -> "            <dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }.join("\n")}
        </d l>
    """.stripIndent()
    return yaml_file
}

if( params.bam ) log.info "BAM file format detected. Initiate remapping to HLA alleles with yara mapper."

/*
 * Preparation - Unpack files if packed.
 *
 * OptiType cannot handle *.gz archives as input files,
 * So we have to unpack first, if this is the case.
 */
if ( !params.bam  ) { // FASTQ files processing
    process unzip {

            input:
            set val(pattern), file(reads) from input_data

            output:
            set val(pattern), "unzipped_{1,2}.fastq" into raw_reads

            script:
            if(params.singleEnd == true)
            """
            zcat ${reads[0]} > unzipped_1.fastq
            """
            else
            """
            zcat ${reads[0]} > unzipped_1.fastq
            zcat ${reads[1]} > unzipped_2.fastq
            """
    }
} else { // BAM files processing

    /*
     * Preparation - Remapping of reads against HLA reference and filtering these
     *
     * In case the user provides BAM files, a remapping step
     * is then done against the HLA reference sequence.
     */
    process remap_to_hla {

        input:
        set val(pattern), file(bams) from input_data

        output:
        set val(pattern), "mapped_{1,2}.bam" into fished_reads

        script:
        full_index = params.base_index + params.seqtype
        if (params.singleEnd)
        """
        samtools bam2fq $bams > output_1.fastq
        yara_mapper -e 3 -t ${task.cpus} -f bam $full_index output_1.fastq > output_1.bam
        samtools view -@ ${task.cpus} -h -F 4 -b1 output_1.bam > mapped_1.bam
        """
        else
        """
        samtools view -@ ${task.cpus} -h -f 0x40 $bams > output_1.bam
        samtools view -@ ${task.cpus} -h -f 0x80 $bams > output_2.bam
        samtools bam2fq output_1.bam > output_1.fastq
        samtools bam2fq output_2.bam > output_2.fastq
        yara_mapper -e 3 -t ${task.cpus} -f bam $full_index output_1.fastq output_2.fastq > output.bam
        samtools view -@ ${task.cpus} -h -F 4 -f 0x40 -b1 output.bam > mapped_1.bam
        samtools view -@ ${task.cpus} -h -F 4 -f 0x80 -b1 output.bam > mapped_2.bam
        """

    }

}


/*
 * STEP 1 - Create config.ini for Optitype
 *
 * Optitype requires a config.ini file with information like
 * which solver to use for the optimization step. Also, the number
 * of threads is specified there for different steps.
 * As we do not want to touch the original source code of Optitype,
 * we simply take information from Nextflow about the available resources
 * and create a small config.ini as first stepm which is then passed to Optitype.
 */
process make_ot_config {

    publishDir "${params.outdir}/config", mode: 'copy'

    output:
    file 'config.ini' into config

    script:
    """
    configbuilder --max-cpus ${params.max_cpus} --solver ${params.solver} > config.ini
    """
}



/*
 * Preparation Step - Pre-mapping against HLA
 *
 * In order to avoid the internal usage of RazerS from within OptiType when
 * the input files are of type `fastq`, we perform a pre-mapping step
 * here with the `yara` mapper, and map against the HLA reference only.
 *
 */
if (!params.bam)
process pre_map_hla {

    input:
    set val(pattern), file(reads) from raw_reads

    output:
    set val(pattern), "mapped_{1,2}.bam" into fished_reads

    script:
    full_index = params.base_index + params.seqtype
    if (params.singleEnd)
    """
    yara_mapper -e 3 -t ${task.cpus} -f bam $full_index $reads > output_1.bam
    samtools view -@ ${task.cpus} -h -F 4 -b1 output_1.bam > mapped_1.bam
    """
    else
    """
    yara_mapper -e 3 -t ${task.cpus} -f bam $full_index $reads > output.bam
    samtools view -@ ${task.cpus} -h -F 4 -f 0x40 -b1 output.bam > mapped_1.bam
    samtools view -@ ${task.cpus} -h -F 4 -f 0x80 -b1 output.bam > mapped_2.bam
    """

}

/*
 * STEP 2 - Run Optitype
 *
 * This is the major process, that formulates the IP and calls the selected
 * IP solver.
 *
 * Ouput formats: <still to enter>
 */
process run_optitype {

    publishDir "${params.outdir}/optitype/", mode: 'copy'

    input:
    file 'config.ini' from config
    set val(pattern), file(reads) from fished_reads

    output:
    file "${pattern}"

    script:
    """
    OptiTypePipeline.py -i ${reads} -e ${params.enumerations} -b ${params.beta} \\
        -p "${pattern}" -c config.ini --${params.seqtype} --outdir ${pattern}
    """
}

/*
 *
 * Output Description HTML
 */
process output_documentation {

    publishDir "${params.outdir}/pipeline_info", mode: 'copy'

    input:
    file output_docs from ch_output_docs

    output:
    file "results_description.html"

    script:
    """
    markdown_to_html.r $output_docs results_description.html
    """
}


/*
 * Parse software version numbers
 */
process get_software_versions {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy',
    saveAs: { filename ->
                if (filename.indexOf(".csv") > 0) filename
                else null
            }

    output:
    file 'software_versions_mqc.yaml' into software_versions_yaml
    file "software_versions.csv"

    script:
    """
    echo $workflow.manifest.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    multiqc --version &> v_multiqc.txt 2>&1 || true
    samtools --version &> v_samtools.txt 2>&1 || true
    yara_mapper --help  &> v_yara.txt 2>&1 || true
    cat \$(which OptiTypePipeline.py) &> v_optitype.txt 2>&1 || true
    scrape_software_versions.py &> software_versions_mqc.yaml
    """

}

process multiqc {
    publishDir "${params.outdir}/MultiQC", mode: 'copy'

    input:
    file multiqc_config from ch_multiqc_config.collect().ifEmpty([])
    file ('software_versions/*') from software_versions_yaml.collect().ifEmpty([])

    file workflow_summary from create_workflow_summary(summary)

    output:
    file "*multiqc_report.html" into ch_multiqc_report
    file "*_data"

    script:
    rtitle = custom_runName ? "--title \"$custom_runName\"" : ''
    rfilename = custom_runName ? "--filename " + custom_runName.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report" : ''
    """
    multiqc -f $rtitle $rfilename --config $multiqc_config .
    """

}

/*
* Completion e-mail notification
*/
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/hlatyping] Successful: $workflow.runName"
    if(!workflow.success){
      subject = "[nf-core/hlatyping] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if(workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if(workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if(workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    if(workflow.container) email_fields['summary']['Docker image'] = workflow.container
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // TODO nf-core: If not using MultiQC, strip out this code (including params.maxMultiqcEmailFileSize)
    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList){
                log.warn "[nf-core/hlatyping] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[nf-core/hlatyping] Could not attach MultiQC report to summary email"
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: params.email, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: mqc_report, mqcMaxSize: params.maxMultiqcEmailFileSize.toBytes() ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (params.email) {
        try {
          if( params.plaintext_email ){ throw GroovyException('Send plaintext e-mail, not HTML') }
          // Try to send HTML e-mail using sendmail
          [ 'sendmail', '-t' ].execute() << sendmail_html
          log.info "[nf-core/hlatyping] Sent summary e-mail to $params.email (sendmail)"
        } catch (all) {
          // Catch failures and try with plaintext
          [ 'mail', '-s', subject, params.email ].execute() << email_txt
          log.info "[nf-core/hlatyping] Sent summary e-mail to $params.email (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File( "${params.outdir}/pipeline_info/" )
    if( !output_d.exists() ) {
      output_d.mkdirs()
    }
    def output_hf = new File( output_d, "pipeline_report.html" )
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File( output_d, "pipeline_report.txt" )
    output_tf.withWriter { w -> w << email_txt }

    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";

    if (workflow.stats.ignoredCountFmt > 0 && workflow.success) {
      log.info "${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}"
      log.info "${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCountFmt} ${c_reset}"
      log.info "${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCountFmt} ${c_reset}"
    }

    if(workflow.success){
        log.info "${c_purple}[nf-core/hlatyping]${c_green} Pipeline completed successfully${c_reset}"
    } else {
        checkHostname()
        log.info "${c_purple}[nf-core/hlatyping]${c_red} Pipeline completed with errors${c_reset}"
    }

}


def nfcoreHeader(){
    // Log colors ANSI codes
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";

    return """    ${c_dim}----------------------------------------------------${c_reset}
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nf-core/hlatyping v${workflow.manifest.version}${c_reset}
    ${c_dim}----------------------------------------------------${c_reset}
    """.stripIndent()
}

def checkHostname(){
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if(params.hostnames){
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if(hostname.contains(hname) && !workflow.profile.contains(prof)){
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}
