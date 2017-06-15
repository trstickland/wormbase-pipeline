#!/bin/bash 
set -e
DIR=`dirname $0`

#this wrapper creates one or several core dbs from a YAML config file then performs some basic healthchecks on them

#Creating core database with worm_lite.pl
out_file="${1}.wormlite.out" 

printf "Launching worm_lite.pl \n"
printf "The output of this script will be written in $out_file \n\n"

if perl -w $WORM_CODE/scripts/ENSEMBL/scripts/worm_lite.pl -yfile $1 -allspecies -setup -load_genes -load_dna &> $out_file; then
    printf "worm_lite.pl exited successfully.\n\n"
else
    printf "worm_lite has errored. Please check the output file\n"
    printf "Exiting now.\n\n"
    exit 1
fi

#performing basic healthchecks
git=`grep -o 'cvsdir: .*' $1 | awk '{print $2}'`

species_list=`grep '^[a-z0-9]*_[a-z0-9]*_[a-z0-9]*:' $1`
fasta_list=`grep 'fasta: .*' $1 | awk '{print $2}'`
gff3_list=`grep 'gff3: .*' $1 | awk '{print $2}'`
coredb_list=`grep ' dbname: .*' $1 | awk '{print $2}' | tail -n+3`

END=`printf "%s\n" $species_list | wc -l`

for i in $(seq 1 $END);
do
species=`sed -n ${i}p <<< "$species_list" | sed s'/.$//'`
fasta=`sed -n ${i}p <<< "$fasta_list"`
gff3=`sed -n ${i}p <<< "$gff3_list"`
coredb=`sed -n ${i}p <<< "$coredb_list"`

health_out="/nfs/panda/ensemblgenomes/wormbase/parasite/core-creation/$coredb.healthcheck.out"
printf "Submitting healthcheck job for $species \n"
printf "The output of this job will be written in $health_out \n\n"

$DIR/healthcheck.sh -d $coredb -g $fasta -a $gff3 -e $git > $health_out

done

printf "All healthchecks done!\n"

