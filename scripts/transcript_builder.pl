#!/software/bin/perl -w
#
# transcript_builder.pl
# 
# by Anthony Rogers and Gary Williams
#
# Script to make ?Transcript objects
#
# Last updated by: $Author: gw3 $
# Last updated on: $Date: 2011-02-11 10:06:24 $
use strict;
use lib $ENV{'CVS_DIR'};
use Getopt::Long;
use Data::Dumper;
use Coords_converter;
use Wormbase;
use Modules::SequenceObj;
use Modules::Transcript;
use Modules::CDS;
use Modules::Strand_transformer;
use Modules::Overlap;
use File::Path;
use Storable;

my ($debug, $store, $help, $verbose, $really_verbose, $est, $gff,
    $database, $build, $new_coords, $test, $UTR_range, @chromosomes, 
    $gff_dir, $test_cds, $wormbase, $species);

my $gap = 15;			# $gap is the gap allowed in an EST alignment before it is considered a "real" intron
my $COVERAGE_THRESHOLD = 95.0;  # the alignment score threshold below which any cDNAs that overlap two genes will not be considered.

# to track failings of system calls
my $errors = 0;

GetOptions ( "debug:s"          => \$debug,
	     "help"             => \$help,
	     "verbose"          => \$verbose,
	     "really_verbose"   => \$really_verbose,
	     "est:s"            => \$est, # only use the specified EST sequence - for debugging
	     "gap:s"            => \$gap,
	     "gff:s"            => \$gff,
	     "database:s"       => \$database,
	     "build"            => \$build,
	     "new_coords"       => \$new_coords,
	     "test"             => \$test,
	     "utr_size:s"       => \$UTR_range,
	     "chromosome:s"     => \@chromosomes,
	     "gff_dir:s"        => \$gff_dir,
	     "cds:s"            => \$test_cds, # only use the specified CDS object - for debugging
	     "store:s"          => \$store,
	     "species:s"	=> \$species
	   ) ;

if ( $store ) {
  $wormbase = retrieve( $store ) or croak("cant restore wormbase from $store\n");
} else {
  $wormbase = Wormbase->new( -debug   => $debug,
			     -test    => $test,
			     -organism => $species
                           );
}

my $db;
if ($database eq "autoace") { 
  $db = $wormbase->autoace;
} else {
  $db = $database;
}

# call tace from Wormbase.pm
my $tace = $wormbase->tace;

# other variables and paths.
@chromosomes = split(/,/,join(',',@chromosomes));
*STDERR = *STDOUT;

# Log Info

if ($wormbase->debug) {
  # this uses a class variable in SequenceObj - not sure of Storable impact at mo' - this will still work.
  my $set_debug = SequenceObj->new();
  $set_debug->debug($debug);
}

my $log = Log_files->make_build_log($wormbase);

&check_opts;
$log->log_and_die("no database\n") unless $db;

#setup directory for transcript
my $transcript_dir = $wormbase->transcripts;
$gff_dir = $wormbase->gff_splits unless $gff_dir;

my $coords;
# write out the transcript objects
# get coords obj to return clone and coords from chromosomal coords
$coords = Coords_converter->invoke($db, undef, $wormbase);

my $ovlp;			# Overlap object

#Load in Feature_data : cDNA associations from COMMON_DATA
my %feature_data;
&load_features( \%feature_data );

my $problem_file = "$transcript_dir/transcripts.problems";
open (PROBLEMS, ">$problem_file") || $log->log_and_die("Can't open $problem_file\n");

# process chromosome at a time
@chromosomes = $wormbase->get_chromosome_names('-prefix' => 1) unless @chromosomes;
my $contigs = 1 if ($wormbase->assembly_type eq 'contig');

foreach my $chrom ( @chromosomes ) {

  # get the Overlap object
  $ovlp = Overlap->new($db, $wormbase);

  #$chrom = $wormbase->chromosome_prefix.$chrom;
  # links store start /end chrom coords
  my $link_start;
  my $link_end;
  my %genes_exons;
  my %genes_span;
  my %cDNA;
  my %cDNA_span;
  my %cDNA_index;
  my %features;
  my $transformer;
  my @cdna_objs;
  my @cds_objs;
  my $index = 0;
  my $gff_file;

  my $gff_stem = $contigs ? $gff_dir.'/' : $gff_dir."/${chrom}_";


  # parse GFF file to get CDS and exon info
  $gff_file = $gff_stem."curated.gff";
  my $GFF = $wormbase->open_GFF_file($chrom, 'curated',$log);
  $log->write_to("reading gff file $gff_file\n") if ($verbose);
  while (<$GFF>) {
    my @data = split;
    next if( $data[1] eq "history" );
    #  GENE STRUCTURE
    if ( $data[1] eq "curated" ) {
      $data[9] =~ s/\"//g;#"
      next if( defined $test_cds and ($data[9] ne $test_cds)) ;
      if ( $data[2] eq "CDS" ) {
	# GENE SPAN
	$genes_span{$data[9]} = [($data[3], $data[4], $data[6])];
      } elsif ($data[2] eq "exon" ) {
	# EXON 
	$genes_exons{$data[9]}{$data[3]} = $data[4];
      }
    }
  }
  close $GFF;
  
  # read BLAT data
  my @BLAT_methods = qw( BLAT_EST_BEST BLAT_mRNA_BEST BLAT_OST_BEST BLAT_RST_BEST);
  foreach my $method (@BLAT_methods) {
    $gff_file = $gff_stem."$method.gff";
    next unless (-e $gff_file); #not all contigs will have these mol_types
    #open( GFF,"grep \"$chrom\\W\" $gff_file |") or $log->write_to("cant open $gff_file : $!\n");
    my $GFF = $wormbase->open_GFF_file($chrom, $method, $log);
    while ( <$GFF> ) {
      next if (/#/); 		 # miss header
      next unless (/BEST/);
      my @data = split;
      $data[9] =~ s/\"//g;#"
      $data[9] =~ s/Sequence:// ;
      $cDNA{$data[9]}{$data[3]} = $data[4];
      # keep min max span of cDNA
      if ( !(defined($cDNA_span{$data[9]}[0])) or ($cDNA_span{$data[9]}[0] > $data[3]) ) {
	$cDNA_span{$data[9]}[0] = $data[3];
	$cDNA_span{$data[9]}[2] = $data[6]; #store strand of cDNA
      } 
      if ( !(defined($cDNA_span{$data[9]}[1])) or ($cDNA_span{$data[9]}[1] < $data[4]) ) {
	$cDNA_span{$data[9]}[1] = $data[4];
      }
      
      $cDNA_span{$data[9]}[5] = $data[5]; # coverage score of the alignment
    }
    close $GFF;
  }
  
  #Chromomsome info

  $gff_file = $gff_stem."Link.gff";
  #open (GFF,"grep \"$chrom\\W\" $gff_file |") or $log->log_and_die("cant open gff_file :$!\n");  
  $GFF = $wormbase->open_GFF_file($chrom, 'Link', $log);
  #create Strand_transformer for '-' strand coord reversal
  CHROM:while( <$GFF> ){
    my @data = split;
    my $chr = $wormbase->chromosome_prefix;
    if ( ($data[1] eq "Link" and $data[9] =~ /$chr/) or
    	 ($data[1] eq "Genomic_canonical" and $data[9] =~ /$chr/) ){
      $transformer = Strand_transformer->new($data[3],$data[4]);
      last CHROM;
    }
  }
  close $GFF;
  # add feature_data to cDNA
  #CHROMOSOME_I  SL1  SL1_acceptor_site   182772  182773 .  -  .  Feature "WBsf016344"
  #
  # want to add in transcription_start_site and
  # transcription_end_site, but these are not currently defined by a
  # cDNA or even a 'bundle of short reads' in the Hillier data
  #
  my @feature_types = qw(SL1 SL2 polyA_site polyA_signal_sequence);
  foreach my $Type (@feature_types){
    my $gff_file = $gff_stem."$Type.gff";
    next unless (-e $gff_file); #not all contigs will have these features
    #open(GFF, "grep \"$chrom\\W\" $gff_file |") or $log->write_to ("cant open $gff_file : $!\n");
    my $GFF = $wormbase->open_GFF_file($chrom, $Type, $log);
    while( <$GFF> ){
      my @data = split;
      if ( $data[9] and $data[9] =~ /(WBsf\d+)/) { #Feature "WBsf003597"
	my $feat_id = $1;
	my $dnas = $feature_data{$feat_id};
	if ( $dnas ) {
	  foreach my $dna ( @{$dnas} ) {
	    #	print "$dna\t$data[9]  --- $data[6] ---  ",$cDNA_span{"$dna"}[2],"\n";
	    next unless ( $cDNA_span{"$dna"}[2] and $data[6] eq $cDNA_span{"$dna"}[2] ); # ensure same strand
	    $cDNA_span{"$dna"}[3]{"$data[1]"} = [ $data[3], $data[4], $1 ]; # 182772  182773 WBsf01634
	  }
	}
      }
    }
    close $GFF;
  }


  # need to sort the cds's into ordered arrays + and - strand genes are in distinct coord space so they need to be kept apart
  my %fwd_cds;
  my %rev_cds;
  foreach ( keys %genes_span ) {
    if ( $genes_span{$_}->[2] eq "+" ) {
      $fwd_cds{$_} = $genes_span{$_}->[0];
    } else {
      $rev_cds{$_} = $genes_span{$_}->[0];
    }
  }

  close $GFF;
  
  &load_EST_data(\%cDNA_span, $chrom);  
  # &checkData(\$gff,\$%cDNA_span, \%genes_span); # this just checks that there is some BLAT and gene data in the GFF file
  &eradicateSingleBaseDiff(\%cDNA);

  #create transcript obj for each CDS
  # fwd strand cds will be in block first then rev strand
  foreach (sort { $fwd_cds{$a} <=> $fwd_cds{$b} } keys  %fwd_cds ) {
    #next if $genes_span{$_}->[2] eq "-"; #only do fwd strand for now
    my $cds = CDS->new( $_, $genes_exons{$_}, $genes_span{$_}->[2], $chrom, $transformer );
    push( @cds_objs, $cds);
    $cds->array_index("$index");
    $index++;
  }
  foreach ( sort { $rev_cds{$b} <=> $rev_cds{$a} } keys  %rev_cds ) {
    #next if $genes_span{$_}->[2] eq "-"; #only do fwd strand for now
    my $cds = CDS->new( $_, $genes_exons{$_}, $genes_span{$_}->[2], $chrom, $transformer );
    push( @cds_objs, $cds);
    $cds->array_index("$index");
    $index++;
  }


  $index = 0;
  foreach ( keys %cDNA ) {

    my $cdna = SequenceObj->new( $_, $cDNA{$_}, $cDNA_span{$_}->[2] );
    $cdna->array_index($index);
    if ( $cDNA_span{"$_"}[3] ) {
      foreach my $feat ( keys %{$cDNA_span{"$_"}[3]} ) {
	$cdna->$feat( $cDNA_span{"$_"}[3]->{"$feat"} );
      }
    }
    # add paired read info
    if ( $cDNA_span{"$_"}[4] ) {
      $cdna->paired_read( $cDNA_span{"$_"}[4] );
    }

    # add coverage score
    if ( $cDNA_span{"$_"}[5] ) {
      $cdna->coverage( $cDNA_span{"$_"}[5] );
    }

    # index info
    $cDNA_index{"$_"} = $index;
    $index++;
    $cdna->transform_strand($transformer,"transform") if ( $cdna->strand eq "-" );

    #check for and remove ESTs with internal SL's 
    if ( $cdna->SL ) {
      if ( $cdna->start < $cdna->SL->[0] ) {
	my $gap = $cdna->SL->[0] - $cdna->start;
	$log->write_to($cdna->name." has internal SL ".$cdna->SL->[2]."gap = $gap\n") if ($verbose);
	next;
      }
    }
    push(@cdna_objs,$cdna);
  }


  # these are no longer needed so free memory !
  %genes_exons = ();
  %genes_span= ();
  %cDNA = ();
  %cDNA_span = ();

  ##########################################################
  # DATA LOADED - START EXTENDING THE TRANSCRIPTS          #
  ##########################################################

  # First round
  #
  # remove any cDNA that overlaps two CDSs and which has a score of
  # less than $COVERAGE_THRESHOLD for the alignment coverage score
  #
  # +++ At present this does a very simple check to see if the EST
  # overlaps with two or more geens, but it should be improved to
  # check whether the EST exons overlap with the CDS exons because at
  # the moment genes in the introns of other genes in the same sense
  # have their weak EST rejected.

  my $round = 'First (poor quality) round:';
  my $count1 = 0;

  $log->write_to("$round\n") if ($verbose);

  foreach my $CDNA ( @cdna_objs) {
    next if ( defined $est and $CDNA->name ne "$est"); #debug line
    #sanity check features on cDNA ie SLs are at start
    next if ( &sanity_check_features( $CDNA ) == 0 );

    foreach my $cds ( @cds_objs ) {
      if ($CDNA->overlap($cds)) {
	$CDNA->probably_matching_cds($cds, 1);
      }
    }
    # now check how many genes the cDNA overlaps - we only want those that overlap one
    my @matching_genes = $CDNA->list_of_matched_genes;
    if ($#matching_genes > 0 && $CDNA->coverage < $COVERAGE_THRESHOLD) { 
      $log->write_to("$round cDNA ",$CDNA->name," overlaps two or more genes and has an alignment score of less than $COVERAGE_THRESHOLD so it will not be used in transcript-building:") if ($verbose);
      foreach my $gene (@matching_genes) {
	$log->write_to("\t" . $gene) if ($verbose);
      }
      $log->write_to("\n") if ($verbose);
      print PROBLEMS "$round cDNA ",$CDNA->name," overlaps two or more genes and has an alignment score of less than $COVERAGE_THRESHOLD so it will not be used in transcript-building: @matching_genes \n";
      $count1++;
      $CDNA->mapped(1);  # mark the cDNA as used with a dummy CDS reference
    } else {
      #print "Quality of ",$CDNA->name," looks OK\n" if ($verbose);
    }
  }

  


  # Second round.
  #
  # here we go through all of the cDNAs looking for matches of their
  # introns with the introns of the CDS structures. We store all
  # instances of a match in the cDNA structure so that we can go
  # through them all later and check first of all whenther there are
  # any cDNAs with introns matching two or more genes - these are
  # candidates for merging genes or chimeric ESTs and the cDNA is not
  # used to build the transcritps as they will almost certainly
  # produce erroneous structures. Where the cDNA matches just one
  # gene, the cDNA may match several CDSs equally well. All of the
  # CDSs that match with an equal number of consecutive introns are
  # then given the option of adding the cDNA to their transcripts.

  $round = "Second (intron) round:";
  my $count2 = 0;

  $log->write_to("$round\n") if ($verbose);

  # want to check if the cDNA has introns that match one and only one gene
  foreach my $CDNA ( @cdna_objs) {
    next if ( defined($CDNA->mapped) );
    next if ( defined $est and $CDNA->name ne "$est"); #debug line
    
    #sanity check features on cDNA ie SLs are at start
    next if ( &sanity_check_features( $CDNA ) == 0 );

    # want to see which fresh set of CDSs this matches
    $CDNA->reset_probably_matching_cds;

    foreach my $cds ( @cds_objs ) {
      if ($cds->map_introns_cDNA($CDNA) ) { 
	# note each CDS and gene that this cDNA matches, together with the number of contiguous CDS introns matched
	print "$round Have stored the no. of introns in common between ",$cds->name," and ",$CDNA->name,"\n" if ($verbose);
      }
    }


    # now that this cDNA has information on which CDS's introns it
    # matches, we can add any cDNA that matches just one gene at the
    # introns level to the transcripts.  There may be more than one
    # CDS in a gene that matches the same number of CDS introns with
    # no mismatches

    my @matching_genes = $CDNA->list_of_matched_genes;
    if ($#matching_genes == 0) { # just one matching gene
      my @best_cds = &get_best_CDS_matches($CDNA); # get those CDSs for this cDNA that have the most introns matching
      foreach my $cds (@best_cds) {
	if ( $cds->map_cDNA($CDNA) ) { # add it to the transcript structure
	  $CDNA->mapped($cds );  # mark the cDNA as used
	  print "$round Have used intron match of ",$CDNA->name," in the transcript ",$cds->name,"\n" if ($verbose);
	}
      }
    } elsif ($#matching_genes > 0) { # we want to report those ESTs that have introns that match two or more CDSs as this may indicate required gene mergers.
      $log->write_to("$round cDNA ",$CDNA->name," matches introns in two or more genes and will not be used in transcript-building:") if ($verbose);
      foreach my $gene (@matching_genes) {
	$log->write_to("\t" . $gene) if ($verbose);
      }
      $log->write_to("\n") if ($verbose);
      print PROBLEMS "$round cDNA ",$CDNA->name," matches introns in two or more genes and will not be used in transcript-building: @matching_genes \n";
      $count2++;
      $CDNA->mapped(1);  # mark the cDNA as used with a dummy CDS reference
    }
  }



  # Here we use the cDNAs that were not used in the intron round
  
  $round = "Third (extend transcripts) round:";
  my $count3 = 0;
  $log->write_to("$round\n") if ($verbose);


  foreach my $CDNA ( @cdna_objs) {
    next if ( defined $est and $CDNA->name ne "$est"); #debug line
    next if ( defined($CDNA->mapped) );
    #sanity check features on cDNA ie SLs are at start
    next if ( &sanity_check_features( $CDNA ) == 0 );


    # want to see which fresh set of CDSs this matches
    $CDNA->reset_probably_matching_cds;

    # here we are now looking for overlapped transcripts and want to
    # avoid using cDNAs that overlap two genes with no intron evidence
    # as to which one it should be added to.

    foreach my $cds ( @cds_objs ) {
      if ($CDNA->overlap($cds)) {
	$CDNA->probably_matching_cds($cds, 1);
      }
    }
    # now check how many genes the cDNA overlaps - we only want those that overlap one
    my @matching_genes = $CDNA->list_of_matched_genes; 
    if ($#matching_genes == 0) { # just one matching gene
      foreach my $cds_match (@{$CDNA->probably_matching_cds}) {
	my $cds = $cds_match->[0];
	if ( $cds->map_cDNA($CDNA) ) { # add it to the transcript structure
	  $CDNA->mapped($cds );  # mark the cDNA as used
	  print "$round Have used first round addition of ",$CDNA->name," in the transcript ",$cds->name,"\n" if ($verbose);
	}
      }
    } elsif ($#matching_genes > 0) { 
      $log->write_to("$round cDNA ",$CDNA->name," overlaps two or more genes and will not be used in transcript-building:") if ($verbose);
      foreach my $gene (@matching_genes) {
	$log->write_to("\t" . $gene) if ($verbose);
      }
      $log->write_to("\n") if ($verbose);
      print PROBLEMS "$round cDNA ",$CDNA->name," overlaps two or more genes and will not be used in transcript-building: @matching_genes \n";
      $count3++;
      $CDNA->mapped(1);  # mark the cDNA as used with a dummy CDS reference
    }
  }


#  $round = "Nth round:";
#  $log->write_to("$round\n") if ($verbose);
#
#  foreach my $CDNA ( @cdna_objs) {
#    next if ( defined $est and $CDNA->name ne "$est"); #debug line
#    next if ( defined($CDNA->mapped) );
#    #sanity check features on cDNA ie SLs are at start
#    next if ( &sanity_check_features( $CDNA ) == 0 );
#
#    foreach my $cds ( @cds_objs ) {
#      if ( $cds->map_cDNA($CDNA) ) {
#	$CDNA->mapped($cds);
#	print "$round ",$CDNA->name," overlaps ",$cds->name,"\n" if $verbose if ($verbose);
#      }
#    }
#  }

  $round = "Fourth (read pairs) round:";

  # try and attach paired reads that dont overlap
  $log->write_to("$round\n") if ($verbose);

 PAIR: foreach my $CDNA ( @cdna_objs) {
    next if ( defined $est and $CDNA->name ne "$est"); #debug line
    next if $CDNA->mapped;
    #sanity check features on cDNA ie SLs are at start
    next if ( &sanity_check_features( $CDNA ) == 0 );

    # get name of paired read
    next unless (my $mapped_pair_name = $CDNA->paired_read );

    # retrieve object from array
    next unless ($cDNA_index{"$mapped_pair_name"} and (my $pair = $cdna_objs[ $cDNA_index{"$mapped_pair_name"} ] ) );

    # get cds that paired read maps to 
    if (my $cds = $pair->mapped) {
      if ($cds != 1) { # don't want to start using the dummy 'cds = 1' flags we used earlier to mark cDNAs we don't wish to use in a transcript
	my $index = $cds->array_index;

	# find next downstream CDS - must be on same strand
	my $downstream_CDS;
      DOWN: while (! defined $downstream_CDS ) {
	  $index++;
	  if ( $downstream_CDS = $cds_objs[ $index ] ) {
	    
	    unless ( $downstream_CDS ) {
	      last;
	      $log->write_to("last gene in array\n") if ($verbose);
	    }
	    # dont count isoforms
	    my $down_name = $downstream_CDS->name;
	    my $name = $cds->name;
	    $name =~ s/[a-z]//;
	    $down_name =~ s/[a-z]//;
	    if ( $name eq $down_name ) {
	      undef $downstream_CDS;
	      next;
	    }
	    # @cds_objs is structured so that + strand genes are in a block at start, then - strand
	    last DOWN if( $downstream_CDS->strand ne $cds->strand );
	    
	    # check unmapped cdna ( $CDNA ) lies within 1kb of CDS that paired read maps to ( $cds ) and before $downstream_CDS
	    
	    #print "$round trying ",$cds->name, " downstream is ", $downstream_CDS->name," with ",$CDNA->name,"\n" if ($verbose);
	    if ( ($CDNA->start > $cds->gene_end) and ($CDNA->start - $cds->gene_end < 1000) and ($CDNA->end < $downstream_CDS->gene_start) ) {
	      #print " $round adding 3' cDNA ",$CDNA->name," to ",$cds->name,"\n" if ($verbose);
	      $cds->add_3_UTR($CDNA);
	      $CDNA->mapped($cds);
	      last;
	    }
	  } else {
	    last DOWN;
	  }
	}
      }
    }
  }

#  $round = "Fifth (extend transcripts again) round:";
#  $log->write_to("$round\n") if ($verbose);
#
#  foreach my $CDNA ( @cdna_objs) {
#    next if ( defined $est and $CDNA->name ne "$est"); #debug line
#    next if ( defined($CDNA->mapped) );
#    #sanity check features on cDNA ie SLs are at start
#    next if ( &sanity_check_features( $CDNA ) == 0 );
#    foreach my $cds ( @cds_objs ) {
#      if ( $cds->map_cDNA($CDNA) ) {
#	$CDNA->mapped($cds);
#	print "$round ",$CDNA->name," overlaps ",$cds->name,"\n" if ($verbose);
#      }
#    }
#  }


  my $out_file = "$transcript_dir/transcripts$$.ace";
  $log->write_to("writing output to $out_file\n") if ($verbose);
  open (FH,">>$out_file") or $log->log_and_die("cant open $out_file\n");
  foreach my $cds (@cds_objs ) {
    #$log->write_to("reporting : ".$cds->name."\n") if $wormbase->debug;
    $cds->report(*FH, $coords, $transformer, $wormbase->full_name);
  }

  print "$count1 cDNAs rejected in round 1 (low quality and overlaps two or more genes)\n";
  print "$count2 cDNAs rejected in round 2 (introns matched in two or more genes)\n";
  print "$count3 cDNAs rejected in round 3 (overlaps two or more genes)\n";

  last if $gff;			# if only doing a specified gff file exit after this is complete
}

close(PROBLEMS);

$log->mail();
exit(0);


######################################################################################################
#
#
#                           T  H  E        S  U  B  R  O  U  T  I  N  E  S
#
#
#######################################################################################################


sub eradicateSingleBaseDiff
  {
    my $cDNA = shift;
    $log->write_to( "removing small cDNA mismatches\n\n\n") if ($verbose);
    foreach my $cdna_hash (keys %{$cDNA} ) {
      my $last_key;
      my $check;
      foreach my $exons (sort { $$cDNA{$cdna_hash}->{$a} <=> $$cDNA{$cdna_hash}->{$b} } keys %{$$cDNA{$cdna_hash}}) {
	print "\n############### $cdna_hash #############\n" if $really_verbose;
	print "$exons -> $$cDNA{$cdna_hash}->{$exons}\n" if $really_verbose;
	my $new_last_key = $exons;
	if ( $last_key ) {
	  if ( $$cDNA{$cdna_hash}->{$last_key} >= $exons - $gap ) { #allows seq error gaps up to $gap bp
	    $$cDNA{$cdna_hash}->{$last_key} = $$cDNA{$cdna_hash}->{$exons};
	    delete $$cDNA{$cdna_hash}->{$exons};
	    $check = 1;
	    $new_last_key = $last_key;
	  }
	}
	$last_key = $new_last_key;
      }
      if ( $check ) {
	foreach my $exons (sort keys  %{$$cDNA{$cdna_hash}}) {
	  print "single base diffs removed from $cdna_hash\n" if $really_verbose;
	  print "$exons -> $$cDNA{$cdna_hash}->{$exons}\n" if $really_verbose;
	}
      }
    }
  }

sub check_opts {
  # sanity check options
  if ( $help ) {
    system("perldoc $0");
    exit(0);
  }
}

sub checkData
  {
    my $file = shift;
    my $cDNA_span = shift;
    my $genes_span = shift;
    die "There's no BLAT data in the gff file $$file\n" if scalar keys %{$cDNA_span} == 0;
    die "There are no genes in the gff file $$file\n" if scalar keys %{$genes_span} == 0;
  }



###################################################################################

sub load_EST_data
  {
    my $cDNA_span = shift;
    my $chrom = shift;
    my %est_orient;
    $wormbase->FetchData("estorientation",\%est_orient) unless (5 < scalar keys %est_orient);
    foreach my $EST ( keys %est_orient ) {
      if ( exists $$cDNA_span{$EST} && defined $$cDNA_span{$EST}->[2]) {
	my $GFF_strand = $$cDNA_span{$EST}->[2];
	my $read_dir = $est_orient{$EST};
      CASE:{
	  ($GFF_strand eq "+" and $read_dir eq "5") && do {
	    $$cDNA_span{$EST}->[2] = "+";
	    last CASE;
	  };
	  ($GFF_strand eq "+" and $read_dir eq "3") && do {
	    $$cDNA_span{$EST}->[2] = "-";
	    last CASE;
	  };
	  ($GFF_strand eq "-" and $read_dir eq "5") && do {
	    $$cDNA_span{$EST}->[2] = "-";
	    last CASE;
	  };
	  ($GFF_strand eq "-" and $read_dir eq "3") && do {
	    $$cDNA_span{$EST}->[2] = "+";
	    last CASE;
	  };
	}
      }
    }

    # load paired read info
    $log->write_to("Loading EST paired read info\n") if ($verbose);
    my $pairs = $wormbase->autoace."/EST_pairs.txt";
    
    if ( -e $pairs ) {
      open ( PAIRS, "<$pairs") or $log->log_and_die("cant open $pairs :\t$!\n");
      while ( <PAIRS> ) {
	chomp;
	s/\"//g;#"
	s/Sequence://g;
	next if( ( $_ =~ /acedb/) or ($_ =~ /\/\//) );
	my @data = split;
	$$cDNA_span{$data[0]}->[4] = $data[1];
      }
      close PAIRS;
    } else {
      my $cmd = "select cdna, pair from cdna in class cDNA_sequence where exists_tag cdna->paired_read, pair in cdna->paired_read";
      
      open (TACE, "echo '$cmd' | $tace $db |") or die "cant open tace to $db using $tace\n";
      open ( PAIRS, ">$pairs") or die "cant open $pairs :\t$!\n";
      while ( <TACE> ) { 
	chomp;
	s/\"//g;#"
	my @data = split;
	next unless ($data[0] && $data[1]);
	next if $data[0]=~/acedb/;
	$$cDNA_span{$data[0]}->[4] = $data[1];
	print PAIRS "$data[0]\t$data[1]\n" if ($verbose);
      }
      close PAIRS;
    }
  }

sub load_features 
  {
    my $features = shift;
    my %tmp;
    $wormbase->FetchData("est2feature",\%tmp);
    foreach my $seq ( keys %tmp ) {
      my @feature = @{$tmp{$seq}};
      foreach my $feat ( @feature ) {
	push(@{$$features{$feat}},$seq);
      }
    }
  }

sub sanity_check_features
  {
    my $cdna = shift;
    my $return = 1;
    if ( my $SL = $cdna->SL ) {
      $return = 0 if( $SL->[0] != $cdna->start );
      print STDERR $SL->[2]," inside ",$cdna->name,"\n" if ($verbose);
    }
    if ( my $polyA = $cdna->polyA_site ) {
      $return = 0 if( $polyA->[1] != $cdna->end );
      print STDERR $polyA->[2]," inside ",$cdna->name,"\n" if ($verbose);
    }

    return $return;
  }

# get the list of CDS objects from the $cdna->probably_matching_cds
# and return those with the highest number of matching introns
sub get_best_CDS_matches {
  my ($CDNA) = @_;
  my $probably_matching_cds = $CDNA->probably_matching_cds;
  my @cds_matches = @{$probably_matching_cds};
  @cds_matches = sort {$b->[1] <=> $a->[1]} @cds_matches; # reverse sort by number of matching introns
  my $max_introns = $cds_matches[0][1]; # get the highest number of matching introns
  my @result;
  foreach my $next_cds (@cds_matches) {
    if ($next_cds->[1] == $max_introns) {push @result, $next_cds->[0]} # store all $cds objects with an equal highest score
  }
  return @result;
}



__END__

=pod

=head2 NAME - transcript_builder.pl

=head1 USAGE

=over 4

=item transcript_builder.pl  [-options]

=back

This script "does exactly what it says on the tin". ie it builds transcript objects for each gene in the database

To do this it ;

1) Determines matching_cDNA status for each gene. Goes through gff files and examines each cDNA to see if it matches any gene that it overlaps.

2) For each gene that has matching cDNAs it then confirms that every exon of the gene that lies within the region covered by the cDNA is covered correctly.  So if a gene has an extra exon that is in the intron of a cDNA, that cDNA will NOT be linked to that gene.


=back

=head2 transcript_builder.pl arguments:

=over 4

=item * verbose and really_verbose  -  levels of terminal output
  
=item * est:s     - just do for single est 

=item * gap:s      - when building up cDNA exon structures from gff file there are often single / multiple base pair gaps in the alignment. This sets the gap size that is allowable [ defaults to 5 ]

=item * gff_dir:s  - pass in the location of chromosome_*.gff files that have been generated for the database you are generating Transcripts for.

=item * gff:s         - pass in a gff file to use

=item * database:s      - either use autoace if used in build process or give the full database path. Basically retrieves paired read info for ESTs from that database.

=head1 AUTHOR

=over 4

=item Anthony Rogers (ar2@sanger.ac.uk)

=back

=cut
