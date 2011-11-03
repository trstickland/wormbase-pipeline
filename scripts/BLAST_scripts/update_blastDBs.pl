#!/usr/local/ensembl/bin/perl -w
#
# Last edited by: $Author: mh6 $
# Last edited on: $Date: 2011-11-03 11:19:30 $

use lib $ENV{'CVS_DIR'};

use strict;
use Wormbase;
use Getopt::Long;
use File::Copy;
use File::Path;
use Log_files;
use Storable;
use Bio::SeqIO;
use Net::FTP;
use Time::localtime;

my ($test, $debug);
my ($fly, $yeast, $human, $uniprot, $interpro, $cleanup, $all);
my $store;
my ($species, $qspecies, $nematode);

GetOptions (
	    'debug:s'     => \$debug,
	    'test'        => \$test,
	    'store:s'     => \$store,
	    'species:s'   => \$species,
	    'fly'	  => \$fly,
	    'yeast' 	  => \$yeast,
	    'human'	  => \$human,
	    'uniprot'	  => \$uniprot,
	    'interpro'    => \$interpro,
	    'cleanup'     => \$cleanup,
	    'all'         => \$all
	    );

my $wormbase;
if( $store ) {
    $wormbase = retrieve( $store ) or croak("cant restore wormbase from $store\n");
}
else {
    $wormbase = Wormbase->new( -debug   => $debug,
			       -test     => $test,
			       -organism => $species
			       );
}

$species = $wormbase->species;   #for load
my $log = Log_files->make_build_log($wormbase);
my $blastdir    = '/lustre/scratch101/ensembl/wormpipe/BlastDB';
my $acedir      = '/lustre/scratch101/ensembl/wormpipe/ace_files';

$human=$fly=$yeast=$uniprot=$interpro=$cleanup=1 if $all;

if( $human ) { &process_human; } 
if ($interpro) { $wormbase->run_script("BLAST_scripts/make_interpro.pl",$log); }

if($uniprot) {
  #get current ver.
  my $cver = determine_last_vers('slimswissprot');
  
  #find latest ver
  open (WG,"wget -O - -q http://www.expasy.org/sprot |") or $log->log_and_die("cant get sprot page\n");
  my $lver;
  while(<WG>) { #to make processing easier we use the uniprot release no.rather than separate SwissProt and Trembl
    if (/UniProt\s+Knowledgebase\s+Release\s+(\d+)_(\d+)/){
      my $newver = sprintf("%d%d", $1, $2);
      if($newver != $cver){
        &process_uniprot($newver);
        last;
      }
      else { $log->write_to("\tdont need to update($newver)\n"); }
    }
  }
  close WG;
}


if ($yeast) {
    $log->write_to("Updating yeast\n");
    my $target = '/tmp/download.yeast.gz';
    my $source='http://downloads.yeastgenome.org/sequence/S288C_reference/orf_protein/orf_trans.fasta.gz';

    $wormbase->run_command("wget -O $target $source",$log);
    
    $wormbase->run_command("gunzip -f $target",$log);
    $target =~ s/\.gz//; #no longer gzipped
    
    my $ver = &determine_last_vers('yeast');
    #check if number of proteins has changed
    $log->write_to("\tcomparing\n");
    my $old_file = "$blastdir/yeast$ver.pep";
    my $old_cnt = qx{grep -c '>' $old_file};
    my $new_cnt = qx{grep -c '>' $target};

    $log->log_and_die("cant work out protein counts\n") unless( $old_cnt =~ /^\d+$/ and $new_cnt =~ /^\d+$/);
    
    if( $old_cnt != $new_cnt){
    	#update the file
	$log->write_to("\tupdating yeast . . .\n");
	&process_yeast($target);
    }
    else {
    	$log->write_to("yeast is up to date\n");
    }
    $log->write_to("\tremoving download\n");
    $wormbase->run_command("rm -f $target", $log);
}	

if ($fly) {
    $log->write_to("Updating fly . . \n");
    # find the release version
    my $page_download = '/tmp/page_download';
    my $fly_version;
    $log->write_to("\tdownloading flybase listing\n");
    $wormbase->run_command("wget -O $page_download ftp://flybase.net/genomes/Drosophila_melanogaster/current/fasta/", $log);
    open (PAGE, "<$page_download") || $log->log_and_die("Can't open $page_download\n");
    while (my $line = <PAGE>) {
      if ($line =~ /dmel-all-translation-r(\d+)\.(\d+)\.fasta.gz/) {
	$fly_version = "$1.$2";
	last;
      }
    }
    close(PAGE);
    $wormbase->run_command("rm -f $page_download", $log);

    #get the file
    my $fly_download = '/tmp/flybase.gz';
    $log->write_to("\tdownloading flybase file\n");
    $wormbase->run_command("wget -O $fly_download ftp://flybase.net/genomes/Drosophila_melanogaster/current/fasta/dmel-all-translation-r${fly_version}.fasta.gz", $log);
    $wormbase->run_command("gunzip -f $fly_download", $log);
    $fly_download = '/tmp/flybase';
    
    #check if number of proteins has changed
    $log->write_to("\tcomparing\n");
    my $ver = &determine_last_vers('gadfly'); 
    my $old_file = "$blastdir/gadfly$ver.pep";
    my $old_cnt = qx{grep -c '>' $old_file};
    my $new_cnt = qx{grep -c '>' $fly_download};

    if( $old_cnt != $new_cnt){
    	#update the file
	$log->write_to("\tupdating flybase . . .\n");
	$ver++;
	my $source_file = "$blastdir/gadfly${ver}.pep";
	move("$fly_download", "$source_file") or $log->log_and_die("can't move $fly_download: $!\n");


	my $record_count = 0;	
	my $problem_count =0;
	my ($gadID, $FBname, $FBgn);
	my $count;
	my %genes;
	my $seqs = Bio::SeqIO->new('-file'=>$source_file, '-format'=>'fasta') or $log->log_and_die("cant open SeqIO from $fly_download:$!\n");
      SEQ:while (my $seq = $seqs->next_seq){
	  $count++;
	  $record_count++;
	  
	  my %fields = $seq->primary_seq->desc =~ /(\w+)=(\S+)/g;

	  $FBname = $fields{'name'} if $fields{'name'} ;
	  ($FBgn) = $fields{'parent'} =~ /(FBgn\d+)/;
	  foreach ( split(/,/,$fields{'dbxref'}) ) {
	      my($key, $value) = split(/:/);
	      if( $key eq 'FlyBase_Annotation_IDs') {
		  ($gadID) = $value =~ /(\w+)-/;
	      }
	  }
	  
	  # some old style names still exist eg pp-CT*****.  In these cases
	  # we need to use the 1st field of the "from_gene" fields.

	  if( $gadID ){
	      if($genes{$gadID}) {
		  next SEQ if(length($genes{$gadID}->{'pep'}) > $seq->length);
	      }
	      $genes{$gadID}->{'fbname'} = $FBname if $FBname;
	      $genes{$gadID}->{'fbgn'} = $FBgn if ($FBgn);
	      $genes{$gadID}->{'pep'} = $seq->seq;
	  }
	  else {
	      # report problems?
	      $log->write_to("PROBLEM : $_\n");
	  }
      }
	
	my $acefile  = "$acedir/flybase.ace";
	my $pepfile  = "$blastdir/gadfly${ver}.pep.tmp"; # output initally goes to tmp file
	open (ACE,">$acefile") or die "cant open $acefile\n"; 
	open (PEP,">$pepfile") or die "cant open $pepfile $!\n";
	
	foreach my $gadID (keys %genes){
	    #print ace file
	    my $FBname = $genes{$gadID}->{'fbname'};
	    my $FBgn   = $genes{$gadID}->{'fbgn'};
	    print ACE "\n\nProtein : \"FLYBASE:$gadID\"\n";
	    print ACE "Peptide \"FLYBASE:$gadID\"\n";
	    print ACE "Species \"Drosophila melanogaster\"\n";
	    print ACE "Gene_name \"$FBname\"\n" if $FBname;
	    print ACE "Database \"FlyBase\" FlyBase_gn \"$FBgn\"\n" if ($FBgn);
	    print ACE "Database \"FlyBase\" FlyBase_ID \"$gadID\"\n" if $gadID;
	    print ACE "Description \"Flybase gene name is $FBname\"\n" if $FBname;

	    print ACE "\nPeptide : \"FLYBASE:$gadID\"\n";
	    print ACE $genes{$gadID}->{'pep'}."\n";

	    print PEP "\n>$gadID\n".$wormbase->format_sequence($genes{$gadID}->{'pep'})."\n";
	}
	
	#write database file
	close ACE;
	close PEP;
	
	#Now overwrite source file with newly formatted file
	
	system("mv $pepfile $source_file") && die "Couldn't write peptide file $source_file\n";
	my $redundant = scalar keys %genes;
	$log->write_to("\t$record_count ($redundant) proteins\nflybase updated\n\n");
    }
    else {
	$log->write_to("\nflybase already up to date\n");
    }
    
    $wormbase->run_command("rm -f $fly_download", $log);
  }


#
# And finally, clean up all the old database files
#
# If you have updated any of the blast databases ie not Interpro, which
# are elsewhere, in the steps above you must ensure that you remove the
# old versions from /lustre/scratch101/ensembl/wormpipe/BlastDB/. E.g. if
# gadfly3.2 is a new database, then you should end up with gadfly3.2.pep
# and remove gadfly3.1.pep.
#
# This will ensure that only the latest databases get copied across
# the ensembl compute farm. Also remove the old blast database index
# files for any old database (*.ahd, *.atb, *bsq, *.xpt, *.xps, *.xpd,
# *.psq, *.pin, *.phr).
#
if ($cleanup) {

  $log->write_to("  Removing old blast databases . . .\n");
  
  my $blast_dir = "/lustre/scratch101/ensembl/wormpipe/BlastDB/";

  # root name regular expressions of the databases to check
  my @roots = (
	       'brepep\d+.pep',
	       'brigpep\d+.pep',
               'gadfly\d+.pep',
               'ipi_human_\d+_\d+.pep',
               'jappep\d+.pep',
               'ppapep\d+.pep',
	       'remapep\d+.pep',
	       'slimswissprot\d+.pep',
	       'slimtrembl\d+.pep',
	       'wormpep\d+_slim.pep',
	       'wormpep\d+.pep',
	       'yeast\d+.pep',
	      );

  # get the list of files in the BLAST directory
  opendir FH, $blast_dir;
  my @list = readdir(FH);
  closedir FH;

  foreach my $regex (@roots) {
    my @files = grep /$regex/, @list;
    if (scalar @files > 1) {
      # sort by creation time
      my @sort = sort {-M "$blast_dir/$a" <=> -M "$blast_dir/$b"} @files;
      my $youngest = shift @sort; # get the youngest file's release number
      my ($youngest_release) = ($youngest =~ /^[a-zA-Z_]+(\d+)/);
      #print "DONT DELETE release $youngest_release\n";
      #print "dont delete $youngest\n";
      foreach my $file (@sort) {
	if ($file =~ /^[a-zA-Z_]+${youngest_release}/) {
	  #print "dont delete $file\n";
	  next;
	}
	$log->write_to("    Deleting $file*\n");
	$wormbase->run_command("rm -f $blast_dir/${file}*", $log);
	#print "rm -f $blast_dir/${file}*\n";
      }
    }
  }
}



$log->mail;
exit(0);


##########################################################################################


sub process_human {
    use File::Listing qw(parse_dir);
    use POSIX qw(strftime);

    # determine last update done
    my @files  = glob($blastdir."/ipi_human*");
    my $file = shift(@files);
    my ($m,$d) = $file =~ /ipi_human_(\d+)_(\d+)/;


    my $login = "anonymous";
    my $passw = 'wormbase@sanger.ac.uk';
    my $ftp = Net::FTP->new("ftp.ebi.ac.uk");
    $ftp->login("anonymous",'wormbase@sanger.ac.uk');
    $ftp->cwd('pub/databases/IPI/current');
    my $filename = 'ipi.HUMAN.fasta.gz';
    my $ls = $ftp->dir("$filename");
    my @a = parse_dir($ls);
    my $remote_date = strftime "%m_%d",gmtime($a[0]->[3]);

    if($remote_date ne "${m}_${d}") {
	#download the file
	$log->write_to("\tupdating human to $remote_date\n");
	my $target = "/tmp/ipi_human_${remote_date}.gz";
	$ftp->binary(); 
	$ftp->get($filename,$target) or $log->log_and_die("failed getting $filename: ".$ftp->message."\n");
	$ftp->quit;

	$wormbase->run_command("gunzip $target",$log);
	$target =~ s/\.gz//; #no longer gzipped
	$wormbase->run_script("BLAST_scripts/parse_IPI_human.pl -file $target", $log);
	$wormbase->run_command("rm $target", $log);
	$log->write_to("\tIPI updated\n");
    }
    else {
	$log->write_to("\tIPI_human is up to date $remote_date\n");
    }
}


sub process_uniprot {

    #swissprot
    my $ver = shift;
    my $swalldir = '/lustre/scratch101/ensembl/wormpipe/swall_data';
    
    my $login = "anonymous";
    my $passw = 'wormbase@sanger.ac.uk';
    my $ftp = Net::FTP->new("ftp.ebi.ac.uk");
    $ftp->login("anonymous",'wormbase@sanger.ac.uk');
    $ftp->cwd('pub/databases/uniprot/knowledgebase');

    my $target = $swalldir."/uniprot_sprot.dat.gz";
    my $filename = 'uniprot_sprot.dat.gz';
    $ftp->binary(); 
    $ftp->get($filename,$target) or $log->log_and_die("failed getting $filename: ".$ftp->message."\n");

    $wormbase->run_command("gunzip -f $target",$log);
    $target =~ s/\.gz//; #no longer gzipped

    $wormbase->run_script("BLAST_scripts/swiss_trembl2dbm.pl -s -file $target", $log);
    $wormbase->run_command("rm -f $target", $log);

    $wormbase->run_script("BLAST_scripts/swiss_trembl2slim.pl -s $ver",$log);
    $wormbase->run_script("BLAST_scripts/fasta2gsi.pl -f $swalldir/slimswissprot",$log);
    copy ("$swalldir/slimswissprot", "$blastdir/slimswissprot${ver}.pep");

#trembl

    $target = $swalldir."/uniprot_trembl.dat.gz";
    $filename = 'uniprot_trembl.dat.gz';
    $ftp->get($filename,$target) or $log->log_and_die("failed getting $filename: ".$ftp->message."\n");
    $ftp->quit;

    $wormbase->run_command("gunzip -f $target",$log);
    $target =~ s/\.gz//; #no longer gzipped
    $wormbase->run_script("BLAST_scripts/swiss_trembl2dbm.pl -t -file $target", $log);
    $wormbase->run_command("rm -f $target", $log);

    $wormbase->run_script("BLAST_scripts/swiss_trembl2slim.pl -t $ver",$log);

    
    $wormbase->run_script("BLAST_scripts/blast_kill_list.pl -infile $swalldir/slimtrembl -outfile $blastdir/slimtrembl${ver}.pep -killfile $swalldir/kill_list.txt",$log);
    copy("$blastdir/slimtrembl${ver}.pep","$swalldir/slimtrembl_f");
    $wormbase->run_script("BLAST_scripts/fasta2gsi.pl -f $swalldir/slimtrembl_f",$log);
}


sub process_yeast {
  my ($target) = @_;
  my $ver = &determine_last_vers('yeast');
  $ver++;
  my $source_file = "$blastdir/yeast${ver}.pep";
  my $acefile     = "$acedir/yeast.ace";
  # output initally goes to tmp file
  my $pepfile  = "$blastdir/yeast${ver}.pep.tmp"; 


# extract info from main FASTA file and write ace file
    open (SOURCE,"<$target") || $log->log_and_die("Couldn't open $target\n");
    open (PEP,">$pepfile") || $log->log_and_die("Couldn't open $pepfile\n");
    open (ACE,">$acefile") || $log->log_and_die("Couldn't open $acefile\n");

    while (<SOURCE>) {
	if( /\>/ ) { 
	    if (/\>(\S+)\s+(\S+)\s+SGDID:(\w+).+\"(.+)/) {
		my $ID = $1;
		my $GENE = $2;
		my $SGDID = $3;
		my $DESC = $4; 
		$DESC =~ s/\"$//;
		$DESC =~ s/"/'/g; # "

		print ACE "\nProtein : \"SGD:$ID\"\n";
		print ACE "Peptide \"SGD:$ID\"\n";
		print ACE "Species \"Saccharomyces cerevisiae\"\n";
		print ACE "Gene_name  \"$GENE\"\n";
		print ACE "Database \"SGD\" \"SGD_systematic_name\" \"$ID\"\n";
		print ACE "Database \"SGD\" \"SGDID\" \"$SGDID\"\n";
		print ACE "Description \"$DESC\"\n" if ($DESC);

		print ACE "\nPeptide : \"SGD:$ID\"\n"; 	
		
		print PEP ">$ID\n";
	    }
	    else {
		print $_;
	    }
	}
	else { 
	    print PEP $_;
	    print ACE $_;
	}
    }

    close(SOURCE);
    close(PEP);
    close(ACE);

# Now overwrite source file with newly formatted file
    system("mv $pepfile $source_file") && $log->log_and_die("Couldn't write peptide file $source_file\n");


}


sub determine_last_vers {
    my $db = shift;
    my @files  = glob($blastdir."/$db*");
    my $file = shift(@files);
    my ($ver) = $file =~ /$db(\d+)\.pep/;
    return $ver ? $ver : '666';
}
    
