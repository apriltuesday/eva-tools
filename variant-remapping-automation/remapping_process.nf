#!/usr/bin/env nextflow

def helpMessage() {
    log.info"""
    Remap submitted variant from one assembly version to another.

    Inputs:
            --taxonomy_id                   taxonomy id of submitted variants that needs to be remapped.
            --source_assembly_accession     assembly accession of the submitted variants are currently mapped to.
            --target_assembly_accession     assembly accession the submitted variants will be remapped to.
            --species_name                  scientific name to be used for the species.
            --genome_assembly_dir           path to the directory where the genome should be downloaded.
            --template_properties           path to the template properties file.
            --output_dir                    path to the directory where the output file should be copied.
            --remapping_config              path to the remapping configuration file
    """
}

params.source_assembly_accession = null
params.target_assembly_accession = null
params.species_name = null
// help
params.help = null

// Show help message
if (params.help) exit 0, helpMessage()

// Test input files
if (!params.taxonomy_id || !params.source_assembly_accession || !params.target_assembly_accession || !params.species_name || !params.genome_assembly_dir ) {
    if (!params.taxonomy_id) log.warn('Provide the taxonomy id of the source submitted variants using --taxonomy_id')
    if (!params.source_assembly_accession) log.warn('Provide the source assembly using --source_assembly_accession')
    if (!params.target_assembly_accession) log.warn('Provide the target assembly using --target_assembly_accession')
    if (!params.species_name) log.warn('Provide a species name using --species_name')
    if (!params.genome_assembly_dir) log.warn('Provide a path to where the assembly should be downloaded using --genome_assembly_dir')
    exit 1, helpMessage()
}


species_name = params.species_name.toLowerCase().replace(" ", "_")


process retrieve_source_genome {

    output:
    path "${params.source_assembly_accession}.fa" into source_fasta
    path "${params.source_assembly_accession}_assembly_report.txt" into source_report

    """
    $params.executable.genome_downloader --assembly-accession ${params.source_assembly_accession} --species ${species_name} --output-directory ${params.genome_assembly_dir}
    ln -s ${params.genome_assembly_dir}/${species_name}/${params.source_assembly_accession}/${params.source_assembly_accession}.fa
    ln -s ${params.genome_assembly_dir}/${species_name}/${params.source_assembly_accession}/${params.source_assembly_accession}_assembly_report.txt
    """
}


process retrieve_target_genome {

    output:
    path "${params.target_assembly_accession}.fa" into target_fasta
    path "${params.target_assembly_accession}_assembly_report.txt" into target_report

    """
    $params.executable.genome_downloader --assembly-accession ${params.target_assembly_accession} --species ${species_name} --output-directory ${params.genome_assembly_dir}
    ln -s ${params.genome_assembly_dir}/${species_name}/${params.target_assembly_accession}/${params.target_assembly_accession}.fa
    ln -s ${params.genome_assembly_dir}/${species_name}/${params.target_assembly_accession}/${params.target_assembly_accession}_assembly_report.txt
    """
}

process update_source_genome {

    input:
    path source_fasta from source_fasta
    path source_report from source_report
    env REMAPPINGCONFIG from params.remapping_config

    output:
    path  "${source_fasta.getBaseName()}_custom.fa" into updated_source_fasta
    path  "${source_report.getBaseName()}_custom.txt" into updated_source_report

    """
    source $params.executable.python_activate
    $baseDir/get_custom_assembly.py --assembly-accession ${params.source_assembly_accession} --fasta-file ${source_fasta} --report-file ${source_report}
    """
}

process update_target_genome {

    input:
    path target_fasta from target_fasta
    path target_report from target_report
    env REMAPPINGCONFIG from params.remapping_config

    output:
    path "${target_fasta.getBaseName()}_custom.fa" into updated_target_fasta
    path "${target_report.getBaseName()}_custom.txt" into updated_target_report

    """
    source $params.executable.python_activate
    $baseDir/get_custom_assembly.py --assembly-accession ${params.target_assembly_accession} --fasta-file ${target_fasta} --report-file ${target_report}
    """
}



/*
 * Extract the submitted variants to remap from the accesioning warehouse and store them in a VCF file.
 */
process extract_vcf_from_mongo {
    memory '8GB'

    input:
    path source_fasta from updated_source_fasta
    path source_report from updated_source_report

    output:
    path "${params.source_assembly_accession}_extraction.properties" into extraction_props
    // Store both vcfs (eva and dbsnp) into one channel
    path '*.vcf' into source_vcfs
    path "${params.source_assembly_accession}_vcf_extractor.log" into log_filename

    publishDir "$params.output_dir/properties", overwrite: true, mode: "copy", pattern: "*.properties"
    publishDir "$params.output_dir/logs", overwrite: true, mode: "copy", pattern: "*.log*"

    """
    cp ${params.template_properties} ${params.source_assembly_accession}_extraction.properties
    echo "parameters.projects=" >> ${params.source_assembly_accession}_extraction.properties
    echo "spring.batch.job.names=EXPORT_SUBMITTED_VARIANTS_JOB" >> ${params.source_assembly_accession}_extraction.properties
    echo "parameters.fasta=${source_fasta}" >> ${params.source_assembly_accession}_extraction.properties
    echo "parameters.taxonomy=${params.taxonomy_id}" >> ${params.source_assembly_accession}_extraction.properties
    echo "parameters.assemblyReportUrl=file:${source_report}" >> ${params.source_assembly_accession}_extraction.properties
    echo "parameters.assemblyAccession=${params.source_assembly_accession}" >> ${params.source_assembly_accession}_extraction.properties
    echo "parameters.outputFolder=." >> ${params.source_assembly_accession}_extraction.properties

    java -jar $params.jar.vcf_extractor --spring.config.name=${params.source_assembly_accession}_extraction > ${params.source_assembly_accession}_vcf_extractor.log
    """
}


/*
 * variant remmapping pipeline
 */
process remap_variants {

    memory '8GB'

    input:
    path source_fasta from updated_source_fasta
    path target_fasta from updated_target_fasta
    path source_vcf from source_vcfs.flatten()

    output:
    path "${basename_source_vcf}_remapped.vcf" into remapped_vcfs
    path "${basename_source_vcf}_remapped_unmapped.vcf" into unmapped_vcfs
    path "${basename_source_vcf}_remapped_counts.yml" into remapped_ymls

    publishDir "$params.output_dir/eva", overwrite: true, mode: "copy", pattern: "*_eva_remapped*"
    publishDir "$params.output_dir/dbsnp", overwrite: true, mode: "copy", pattern: "*_dbsnp_remapped*"

    script:
    basename_source_vcf = source_vcf.getBaseName()
    """
    # Setup the PATH so that the variant remapping pipeline can access its dependencies
    mkdir bin
    for P in $params.executable.bcftools $params.executable.samtools $params.executable.bedtools $params.executable.minimap2 $params.executable.bgzip $params.executable.tabix
      do ln -s \$P bin/
    done
    PATH=`pwd`/bin:\$PATH
    source $params.executable.python_activate
    # Nextflow needs the full path to the input parameters hence the pwd
    $params.executable.nextflow run $params.nextflow.remapping -resume \
      --oldgenome `pwd`/${source_fasta} \
      --newgenome `pwd`/${target_fasta} \
      --vcffile `pwd`/${source_vcf} \
      --outfile `pwd`/${basename_source_vcf}_remapped.vcf
    """
}

/*
 * Ingest the remapped submitted variants from a VCF file into the accessioning warehouse.
 */
process ingest_vcf_into_mongo {
    memory '8GB'

    input:
    path remapped_vcf from remapped_vcfs.flatten()
    path target_report from updated_target_report

    output:
    path "${remapped_vcf}_ingestion.properties" into ingestion_props
    path "${remapped_vcf}_ingestion.log" into ingestion_log_filename

    publishDir "$params.output_dir/properties", overwrite: true, mode: "copy", pattern: "*.properties"
    publishDir "$params.output_dir/logs", overwrite: true, mode: "copy", pattern: "*.log*"

    script:
    """
    cp ${params.template_properties} ${remapped_vcf}_ingestion.properties
    echo "spring.batch.job.names=INGEST_REMAPPED_VARIANTS_FROM_VCF_JOB" >> ${remapped_vcf}_ingestion.properties
    echo "parameters.vcf=${remapped_vcf}" >> ${remapped_vcf}_ingestion.properties
    echo "parameters.assemblyAccession=${params.target_assembly_accession}" >> ${remapped_vcf}_ingestion.properties
    echo "parameters.remappedFrom=${params.source_assembly_accession}" >> ${remapped_vcf}_ingestion.properties
    echo "parameters.remappingVersion=1.0" >> ${remapped_vcf}_ingestion.properties
    echo "parameters.chunkSize=100" >> ${remapped_vcf}_ingestion.properties
    # Check the file name to know which database to load the variants into
    if [[ $remapped_vcf == *_eva_remapped.vcf ]]
    then
        echo "parameters.loadTo=EVA" >> ${remapped_vcf}_ingestion.properties
    else
        echo "parameters.loadTo=DBSNP" >> ${remapped_vcf}_ingestion.properties
    fi
    echo "parameters.assemblyReportUrl=file:${target_report}" >> ${remapped_vcf}_ingestion.properties

    java -jar $params.jar.vcf_ingestion --spring.config.name=${remapped_vcf}_ingestion > ${remapped_vcf}_ingestion.log
    """
}
