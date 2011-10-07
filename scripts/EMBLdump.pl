#!/usr/local/bin/perl5.8.0 -w
#
# EMBLdump.pl :  makes modified EMBL dumps from camace.
# 
#  Last updated on: $Date: 2011-10-07 16:14:46 $
#  Last updated by: $Author: klh $

use strict;
use Getopt::Long;
use File::Copy;
use Storable;
use Text::Wrap;

$Text::Wrap::columns = 60;
$Text::Wrap::unexpand = 0;

use lib $ENV{'CVS_DIR'};
use Wormbase;

my %species_info = (
  genome_project_id => {
    elegans  => 13758,
    briggsae => 10731,
  },

  taxon_id => {
    elegans  => 6239,
    briggsae => 473542,
  },

  strain => {
    elegans => 'Bristol N2',
    briggsae => 'AF16',
  }
);    

#
# Yuk. The below is a selenoprotein, the only one
# currently in elegans or briggsae. Since we do not store
# in the database the information required to populate the
# the transl_exep qualifier, we need to hard-code it here. 
# Like I said: yuk.
#

my %additional_qualifiers = (

  "C06G3.7" => { 
    transl_excep => ["(pos:4060..4062,aa:Sec)"],
  },
);



my ($test,
    $debug,
    $store,
    $species,
    $full_species_name,
    $raw_dump_file,
    $mod_dump_file,
    $wormbase,
    $single,
    $database,
    $use_builddb_for_ref,
    $quicktest,
    $exclude_sequence,
    );

GetOptions (
  "test"            => \$test,
  "debug=s"         => \$debug,     # Only emails specified recipient and turns on extra printing.
  "store:s"         => \$store,
  "single=s@"       => \$single,
  "species:s"       => \$species,
  "database:s"      => \$database,
  "buildref"        => \$use_builddb_for_ref,
  "rawdumpfile:s"   => \$raw_dump_file,
  "moddumpfile:s"   => \$mod_dump_file,
  "quicktest"       => \$quicktest,
  "excludeseq"      => \$exclude_sequence,
    );


if( $store ) {
  $wormbase = retrieve( $store ) or croak("cant restore wormbase from $store\n");
}
else {
  $wormbase = Wormbase->new( -debug    => $debug,
                             -test     => $test,
                             -organism => $species,
                             -autoace  => $database,
      );
}

# establish log file.
my $log = Log_files->make_build_log($wormbase);

$species = $wormbase->species;
$full_species_name = $wormbase->full_name;

$exclude_sequence = 1 if $species eq 'briggsae';

###############################
# misc. variables             #
###############################

my $basedir = $wormbase->wormpub;
my $giface = $wormbase->giface;
my $tace = $wormbase->tace;
my $dbdir = ($database) ? $database : $wormbase->autoace;
my $refdb = ($use_builddb_for_ref) ? $dbdir : $wormbase->database('current');


#########################
# Get COMMONDATA hashes #
#########################
my %clone2type      = $wormbase->FetchData('clone2type');
my %cds2cgc         = $wormbase->FetchData('cds2cgc');
my %rnagenes        = $wormbase->FetchData('rna2cgc');
my %clone2dbid      = $wormbase->FetchData('clone2dbid');
my %pseudo2cgc      = $wormbase->FetchData('pseudo2cgc');


#
# Some information is not yet available in autoace (too early in the build)
# Therefore pull it across from previous build. 
#
my ($cds2status_h, $cds2proteinid_h,  $cds2dbremark_h) = &fetch_database_info($refdb);


#############################################
# Use giface to dump EMBL files from camace #
#############################################

my $delete_raw_dump_file = 0;

if (not defined $raw_dump_file) {
  $log->write_to("You are embl dumping from $dbdir\n\n");
  
  $raw_dump_file = "$basedir/tmp/EMBLdump.$$";
  $delete_raw_dump_file = 1;

  my $command;
  if ($single) {
    $command  = "nosave\n"; # Don't really want to do this
    $command .= "query find CDS where Method = \"Genefinder\"\nkill\ny\n";# remove Genefinder predictions
    $command .= "query find CDS where Method = \"twinscan\"\nkill\ny\n";# remove twinscan predictions
    $command .= "query find CDS where Method = \"jigsaw\"\nkill\ny\n";# remove jigsaw predictions
    $command .= "query find Sequence $single\ngif EMBL $raw_dump_file\n";# find sequence and dump
    $command .= "quit\nn\n";# say you don't want to save and exit
  } else {
    $command  = "nosave\n"; # Don't really want to do this
    $command .= "query find CDS where Method = \"Genefinder\"\nkill\ny\n";# remove Genefinder predictions
    $command .= "query find CDS where Method = \"twinscan\"\nkill\ny\n";# remove twinscan predictions
    $command .= "query find CDS where Method = \"jigsaw\"\nkill\ny\n";# remove jigsaw predictions
    $command .= "query find Sequence Genomic_canonical AND Finished AND DNA\ngif EMBL $raw_dump_file\n";# find sequence and dump
    $command .= "quit\nn\n";# say you don't want to save and exit
  }
  
  $log->write_to("$command\n");
  open (READ, "echo '$command' | $giface $dbdir |") or die ("Could not open $giface $dbdir\n");
  while (<READ>) {
    next if ($_ =~ /\/\//);
    next if ($_ =~ /acedb/);
  }
  close (READ);
} else {
  $log->write_to("You are processing the pre-dumped file $raw_dump_file\n");
}



######################################################################
# cycle through the EMBL dump file, replacing info where appropriate #
######################################################################
$mod_dump_file = "./EMBL_dump.embl" if not defined $mod_dump_file;

open(my $out_fh, ">$mod_dump_file") or $log->log_and_die("Could not open $mod_dump_file for writing\n");
open(my $raw_fh, $raw_dump_file) or $log->log_and_die("Could not open $raw_dump_file for reading\n");

my ($clone, $seqlen, $idline_suffix, @accs, @features, $written_header);

while (<$raw_fh>) {

  # Store the necessary default ID line elements ready for use in the new style EMBL ID lines.
  if(/^ID\s+CE(\S+)\s+\S+\s+\S+\s+\S+\s+(\d+)\s+\S+/){
    ($clone, $seqlen) = ($1, $2);
    $idline_suffix = "SV XXX; linear; genomic DNA; STD; INV; $seqlen BP."; 

    @accs = ();
    @features = ();
    $written_header = 0;

    next;
  }

  if( /^AC\s+(\S+);/ ) {
    push @accs, $1;
    next;
  }

  if (/^DE/) {
    # should now have parsed everything necessary to write first block of entry
    #
    # ID
    #
    print $out_fh "ID   $accs[0]; $idline_suffix\n";
    print $out_fh "XX\n";

    #
    # AC
    #
    print $out_fh "AC   $accs[0];";
    for(my $i=1; $i < @accs; $i++) {
      print $out_fh " $accs[$i];";
    }
    print $out_fh "\nXX\n";

    #
    # AC *
    #
    if ($clone2dbid{$clone}) {
      print $out_fh "AC * $clone2dbid{$clone}\n";
      print $out_fh "XX\n";
    }
    
    #
    # PR
    #
    print $out_fh "PR   Project:$species_info{genome_project_id}->{$species};\n";
    print $out_fh "XX\n";

    #
    # DE
    #
    my $de_line;

    if ($species eq 'elegans') {
      if (!defined($clone2type{$clone})){
        $de_line =  "$full_species_name clone $clone";
        $log->write_to("WARNING: no clone type for $_");
      } elsif (lc($clone2type{$clone}) eq "other") {
        $de_line = "$full_species_name clone $clone";
      } elsif (lc($clone2type{$clone}) eq "yac") {
        $de_line = "$full_species_name YAC $clone";
      } else {
        $de_line = "$full_species_name $clone2type{$clone} $clone";
      }
    } elsif ($species eq 'briggsae') {
      $de_line = "$full_species_name AF16 supercontig $clone from assembly CB4";
    }

    print $out_fh "DE   $de_line\n";
    $written_header = 1;
    next;
  }

  #
  # References
  #
  if (/^RN\s+\[1\]/) {
    my ($primary_RA, $primary_RL); 

    while(<$raw_fh>) {
      last if /^XX/;
      if (/^RA/) {
        $primary_RA = $_;
        next;
      }
      if (/^RL/) {
        $primary_RL = $_;
      }
    }

    my @refs = @{&get_references()};
    for(my $i=0; $i < @refs; $i++) {
      printf $out_fh "RN   [%d]\n", $i+1;
      print $out_fh "RP   1-$seqlen\n";
      map { print $out_fh "$_\n" } @{$refs[$i]};
      print $out_fh "XX\n";
    }

    printf $out_fh "RN   [%d]\n", scalar(@refs) + 1;
    printf $out_fh "RP   1-%d\n", $seqlen;
    print $out_fh "RG   WormBase Consortium\n";
    print $out_fh $primary_RA;
    print $out_fh "RT   ;\n";
    print $out_fh $primary_RL;
    print $out_fh "RL   Nematode Sequencing Project: Sanger Institute, Hinxton, Cambridge\n";
    print $out_fh "RL   CB10 1SA, UK and The Genome Institute at Washington University,\n"; 
    print $out_fh "RL   St. Louis, MO 63110, USA. E-mail: help\@wormbase.org\n";
    print $out_fh "XX\n";
    next;
  }

  #
  # Comments
  #
  if (/^CC   For a graphical/) {
    while(<$raw_fh>) {
      last if /^XX/;
      
      print $out_fh "CC   For a graphical representation of this sequence and its analysis\n";
      print $out_fh "CC   see:- http://www.wormbase.org/perl/ace/elegans/seq/sequence?\n";
      print $out_fh "CC   name=$clone;class=Sequence\n";
      print $out_fh "XX\n";
    }
    next;
  }

  #
  # Feature table
  #
  if (/^FT   (\S+)\s+(.+)/) {
    my ($ftype, $content) = ($1, $2);

    push @features, {
      ftype     => $ftype,
      location  => [$content],
      quals     => [],
    };
    next;
  } elsif (/^FT\s+(.+)/) {
    my $content = $1;
    if ($content =~ /^\/\w+=/) {
      push @{$features[-1]->{quals}}, [$content];
    } else {
      if (not @{$features[-1]->{quals}}) {
        push @{$features[-1]->{location}}, $content;
      } else {        
        push @{$features[-1]->{quals}->[-1]}, $content;
      }
    }
    next;
  }

  if (/^SQ/) {
    &process_feature_table(@features);
    if (not $exclude_sequence) {
      print $out_fh $_;
    }
    next;
  }

  if ($written_header and 
      (not $exclude_sequence or /^\S/)) {
    print $out_fh $_;
  }
}

close($raw_fh);
close($out_fh);

unlink $raw_dump_file if $delete_raw_dump_file;

$log->write_to("\nOutfile is $mod_dump_file\n");
$log->mail();
exit(0); 

###################################################
#                 SUBROUTINES                     #
###################################################


############################
sub process_feature_table {
  my @feats = @_;

  foreach my $feat (@feats) {
    if (&check_for_bad_location($feat->{location})) {
      $log->write_to("Discarding non-local feature:\n");
      $log->write_to(sprintf("FT   %-16s%s\n", $feat->{ftype}, $feat->{location}->[0]));
      for(my $i=1; $i < @{$feat->{location}}; $i++) {
        $log->write_to(sprintf("FT   %16s%s\n", " ", $feat->{location}->[$i]));
      }
      foreach my $qual (@{$feat->{quals}}) {
        foreach my $ln (@$qual) {
          $log->write_to(sprintf("FT   %16s%s\n", " ", $ln));
        }
      }
      next;
    }

    if ($feat->{ftype} eq 'source') {
      printf $out_fh "FT   %-16s%s\n", $feat->{ftype}, $feat->{location}->[0];
      printf $out_fh "FT   %16s/db_xref=\"taxon:%d\"\n", " ", $species_info{taxon_id}->{$species};
      printf $out_fh "FT   %16s/strain=\"%s\"\n", " ", $species_info{strain}->{$species};
      printf $out_fh "FT   %16s/mol_type=\"genomic DNA\"\n", " ";
      foreach my $tag (@{$feat->{quals}}) {
        foreach my $ln (@$tag) {
          printf $out_fh "FT   %16s%s\n", " ", $ln;
        }
      }
      next;
    } elsif ($feat->{ftype} =~ /RNA$/) {
      #
      # 1st FT line should be one of 3
      # FT    ncRNA
      # FT    rRNA
      # FT    tRNA
      # Supported bio types for ncRNA
      #  /ncRNA_class="miRNA"
      #  /ncRNA_class="siRNA"
      #  /ncRNA_class="scRNA"              
      #  /ncRNA_class="other"
      #  /ncRNA_class="snoRNA"
      #  /ncRNA_class="snRNA"
      # Nothing else counts

      my $mod_dir = $feat->{ftype};
      my $rna_class;

      if ($mod_dir eq 'snoRNA' or 
          $mod_dir eq 'miRNA' or
          $mod_dir eq 'siRNA' or 
          $mod_dir eq 'scRNA' or
          $mod_dir eq 'snRNA') {
        $rna_class = $mod_dir;
        $mod_dir = 'ncRNA';
      } elsif ($mod_dir eq 'misc_RNA' or
               $mod_dir eq 'ncRNA') {
        $rna_class = 'other';
        $mod_dir = 'ncRNA';
      } elsif ($mod_dir eq 'tRNA' or 
               $mod_dir eq 'rRNA') {
        # no class, do nothing
      } else {
        # for all other RNA types, pass them through as
        # ncRNA/other, but record the type in a note
        push @{$feat->{quals}}, ["/note=\"$mod_dir\""];
        $mod_dir = "ncRNA";
        $rna_class = "other";
      }

      if (defined $rna_class) {
        push @{$feat->{quals}}, ["/ncRNA_class=\"$rna_class\""];
        $feat->{class} = $rna_class;
      }
      $feat->{ftype} = $mod_dir;
    } elsif ($feat->{ftype} =~ /Pseudogene/) {
      my $new_dv = "CDS";

      # hack: all Pseudogenes with .t\d+ suffices are
      # tRNA pseudogenes.
      foreach my $tg (@{$feat->{quals}}) {
        if ($tg->[0] =~ /\/gene=\"\S+\.t\d+\"/) {
          $new_dv = "tRNA";
        } 
      }

      $feat->{ftype} = $new_dv;
      push @{$feat->{quals}}, ["/pseudo"];
    }

    printf $out_fh "FT   %-16s%s\n", $feat->{ftype}, $feat->{location}->[0];
    for(my $i=1; $i < @{$feat->{location}}; $i++) {
      printf $out_fh "FT   %16s%s\n", " ", $feat->{location}->[$i];
    }

    #
    # Now do qualifiers. Pass through the list picking out information
    # we are interested in, and filter out the ones we don't want. 
    # The rest we keep as-are
    #
    
    my (%revised_quals,
        $wb_isoform_name,
        $gene_qual, 
        $locus_tag_qual, 
        $standard_name_qual, 
        $product_qual, 
        $db_remark, 
        $brief_ident);

    foreach my $qual (@{$feat->{quals}}) {
      if ($qual->[0] =~ /^\/standard_name=\"(\S+)\"/) {
        $wb_isoform_name = $1;
        $standard_name_qual = $qual;

        if ($cds2dbremark_h->{$wb_isoform_name}) {
          my $rem = sprintf("%s", $cds2dbremark_h->{$wb_isoform_name});
          $rem =~ s/\s+/ /g;

          my $rem_line = "/note=\"$rem\"";
          my @wl = split(/\n/, wrap('','',$rem_line));
          
          $db_remark = \@wl;
        }        
      } elsif ($qual->[0] =~ /\/note=\"similar to (.+\S)\s*$/) {
        my $bi = "\"$1";
        for(my $i=1; $i < @$qual; $i++) {
          $qual->[$i] =~ /^\s*(.+\S)\s*$/ and $bi .= " $1";
        }
        $bi =~ s/^\"//;
        $bi =~ s/\"$//;

        my @wl = split(/\n/, wrap('','',"/note=\"$bi\""));

        $brief_ident = \@wl;
        $feat->{brief_identification} = $bi;

      } elsif ($qual->[0] =~ /\/note=\"(.+)\-RNA\"/) {
        $feat->{rna_identification} = $1;
      } elsif ($qual->[0] =~ /\/note=\"preliminary prediction\"/ or
               $qual->[0] =~ /\/note=\"cDNA EST/ or 
               $qual->[0] =~ /\/product=/ or
               $qual->[0] =~ /\/gene=/) {
        next;
      } elsif ($qual->[0] =~ /\/([^=]+)=?/) {
        push @{$revised_quals{$1}}, $qual;
      }
    }
    
    
    #
    # /product
    #
    if ($feat->{ftype} eq 'CDS') {
      $product_qual = "/product=\"Protein ";
      if ($wb_isoform_name =~ /^(\S+)([a-z])$/) {
        $product_qual .= "$1, isoform $2\"";
      } else {
        $product_qual .= "$wb_isoform_name\"";
      }
    } elsif ($feat->{ftype} =~ /RNA/) {
      if ($feat->{ftype} eq 'tRNA' and 
          exists $feat->{brief_identification}) {
        $product_qual = "/product=\"$feat->{brief_identification}\"";
      } elsif ($feat->{ftype} eq 'rRNA' and 
               exists $feat->{rna_identification}) {
        $product_qual = "/product=\"$feat->{rna_identification}\"";
      } else {
        if ($rnagenes{$wb_isoform_name}) {
          $product_qual = "/product=\"RNA transcript $rnagenes{$wb_isoform_name}\"";
        } else {
          $product_qual = "/product=\"RNA transcript $wb_isoform_name\"";
        }
      }
    }
    $product_qual = [$product_qual];

    #
    # /protein_id and prediction_status note
    #
    if ($feat->{ftype} eq 'CDS') {
      if (exists $cds2proteinid_h->{$wb_isoform_name} and
          exists $cds2proteinid_h->{$wb_isoform_name}->{$clone}) {
        my $pid = $cds2proteinid_h->{$wb_isoform_name}->{$clone};
        push @{$revised_quals{protein_id}}, ["/protein_id=\"$pid\""];
      }
      
      my $status_note;
      if (defined $cds2status_h->{$wb_isoform_name}) {
        if ($cds2status_h->{$wb_isoform_name} eq 'Confirmed') {
          $status_note = "/note=\"Confirmed by transcript evidence\"";
        } elsif ($cds2status_h->{$wb_isoform_name} eq 'Partially_confirmed') {
          $status_note = "/note=\"Partially confirmed by transcript evidence\"";
        } else {
          $status_note = "/note=\"Predicted\"";
        }
      }
      if (defined $status_note) {
        push @{$revised_quals{note}}, [$status_note];
      }
    }

    #
    # /gene
    #
    if ($cds2cgc{$wb_isoform_name}) {
      $gene_qual = ["/gene=\"$cds2cgc{$wb_isoform_name}\""];
    } elsif ($rnagenes{$wb_isoform_name}) {
      $gene_qual = ["/gene=\"$rnagenes{$wb_isoform_name}\""];
    } elsif ($pseudo2cgc{$wb_isoform_name}) {
      $gene_qual = ["/gene=\"$pseudo2cgc{$wb_isoform_name}\""];
    } else {
      if ($wb_isoform_name =~ /^(\S+\.\d+)[a-z]?/) {
        $gene_qual = ["/gene=\"$1\""];
      } else {
        $gene_qual = ["/gene=\"$wb_isoform_name\""];
      }
    }
      
    #
    # locus_tag
    #
    my $lt = $wb_isoform_name;
    if ($lt =~ /^(\S+\.\d+)[a-z]?/) {
      $lt = $1;
    }
    $locus_tag_qual = [sprintf("/locus_tag=\"%s\"", $lt)];
        
    #
    # Other qualifiers
    #
    
    if ($additional_qualifiers{$wb_isoform_name}) {
      foreach my $qk (keys %{$additional_qualifiers{$wb_isoform_name}}) {
        foreach my $qual (@{$additional_qualifiers{$wb_isoform_name}->{$qk}}) {
          my $qual_string = "/$qk=$qual";
          my @wqs = split(/\n/, wrap('','',$qual_string));
          push @{$revised_quals{$qk}}, \@wqs;
        }
      }
    }

    if ($feat->{ftype} eq 'CDS') {
      if (defined $brief_ident) {
        push @{$revised_quals{note}}, $brief_ident;
      } elsif (defined $db_remark) {
        push @{$revised_quals{note}}, $db_remark;
      }
    } elsif ($feat->{ftype} eq 'ncRNA' and $feat->{class} eq 'other') {
      # only attempt to add notes to ncRNAs defined with "other" class
      if (exists $feat->{rna_identification}) {
        push @{$revised_quals{note}}, ["/note=\"$feat->{rna_identification}\""];
      } elsif (exists $feat->{brief_identification} and 
               $feat->{brief_identification} ne 'ncRNA' and
               $feat->{brief_identification} !~ /non-coding RNA gene$/) {
        push @{$revised_quals{note}}, $brief_ident;
      } elsif (defined $db_remark) {
        push @{$revised_quals{note}}, $db_remark;
      }
    }


    #
    # Finally, print them all out in a consistent sensible order
    #
    
    foreach my $qual ($gene_qual, $locus_tag_qual, $standard_name_qual, $product_qual) {
      foreach my $line (@$qual) {
        printf $out_fh "FT   %16s%s\n", " ", $line;
      }
    }
    foreach my $k (sort keys %revised_quals) {
      next if $k eq 'note';
      foreach my $qual (@{$revised_quals{$k}}) {
        foreach my $line (@$qual) {
          printf $out_fh "FT   %16s%s\n", " ", $line;
        }
      }
    }
    if (exists ($revised_quals{note})) {
      foreach my $qual (@{$revised_quals{note}}) {
        foreach my $line (@$qual) {
          printf $out_fh "FT   %16s%s\n", " ", $line;
        }
      }
    }
  }
  print $out_fh "XX\n";
}

##########################
sub check_for_bad_location {
  my ($loc_a) = @_;

  my $loc_string = "";
  foreach my $loc (@{$loc_a}) {
    chomp($loc);
    $loc_string .= $loc;
  }

  while(1) {
    if ($loc_string =~ /^[^\(]*(complement|join)\(.+\)[^\)]*$/) {
      $loc_string =~ s/^([^\(]*)(complement|join)\((.+)\)([^\)]*)$/$1$3/;
    } else {
      last;
    }
  }
  
  my @comps = split(/,/, $loc_string);
  my @local_components = grep { $_ =~ /^\d+\.\.\d+$/ } @comps;

  if (not @local_components) {
    return 1;
  } else {
    return 0;
  }
}

##########################
sub get_references {

  my %primary_references = (
    elegans =>  [
      [ 
        "RX   PUBMED; 9851916.",
        "RA   Caenorhabditis elegans Sequencing Consortium;",
        "RT   \"Genome sequence of the nematode C. elegans: a platform for investigating",
        "RT   biology\";",
        "RL   Science 282(5396):2012-2018(1998).",
      ],
    ],
    
    briggsae => [
      [
       "RX   PUBMED; 14624247.",
       "RA   Stein L.D., Bao Z., Blasiar D., Blumenthal T., Brent M.R., Chen N.,",
       "RA   Chinwalla A., Clarke L., Clee C., Coghlan A., Coulson A., D'Eustachio P.,",
       "RA   Fitch D.H., Fulton L.A., Fulton R.E., Griffiths-Jones S., Harris T.W.,",
       "RA   Hillier L.W., Kamath R., Kuwabara P.E., Mardis E.R., Marra M.A.,",
       "RA   Miner T.L., Minx P., Mullikin J.C., Plumb R.W., Rogers J., Schein J.E.,",
       "RA   Sohrmann M., Spieth J., Stajich J.E., Wei C., Willey D., Wilson R.K.,",
       "RA   Durbin R., Waterston R.H.;",
       "RT   \"The genome sequence of Caenorhabditis briggsae: a platform for comparative",
       "RT   genomics\";",
       "RL   PLoS Biol. 1(2):E45-E45(2003).",
      ],
      [ 
        "RX   PUBMED; 21779179.",
        "RA   Ross J.A., Koboldt D.C., Staisch J.E., Chamberlin H.M., Gupta B.P.,",
        "RA   Miller R.D., Baird S.E., Haag E.S.;",
        "RT   \"Caenorhabditis briggsae recombinant inbred line genotypes reveal",
        "RT   inter-strain incompatibility and the evolution of recombination\";",
        "RL   PLoS Gen. 7(7):E1002174-E1002174(2011).",
      ],
    ],
  
      );

  return $primary_references{$species};
}

#######################
sub fetch_database_info {
  my ($ref_db) = @_;

  my (%cds2status, %cds2dbremark, %cds2proteinid);

  if ($quicktest) {
    return (\%cds2status, \%cds2proteinid, \%cds2dbremark);
  }

  $log->write_to("You are using $refdb to get protein_ids, CDS status and DB_Remarks\n\n");
  my (@qfiles);

  #
  # CDS -> status
  #

  my $query = &get_status_query();
  push @qfiles, $query;
  my $command = "Table-maker -p $query\nquit\n";
  
  open (TACE, "echo '$command' | $tace $ref_db |");
  while (<TACE>) {
    chomp;
    s/\"//g;
    next unless (/^([A-Z,0-9,.]+?\w)\s+(\w+)/) ;
    my ($cds, $status) = ($1, $2);
    $cds2status{$cds} = $status;
  }
  close TACE;

  #
  # CDS -> protein_ID
  #
  $query = &get_protein_id_query();
  push @qfiles, $query;
  $command = "Table-maker -p $query\nquit\n";
  open(TACE, "echo '$command' | $tace $ref_db |");
  while(<TACE>) {
    chomp;
    s/\"//g;
    if (/^(\S+)\s+(\S+)\s+(\S+)\s+(\d+)$/) {
      my ($cds, $clone, $protein_id, $version) = ($1, $2, $3, $4);
      $cds2proteinid{$cds}->{$clone} = "${protein_id}.${version}";
    }   
  }
  close(TACE);

  #
  # CDS/RNA -> DB_Remark
  #
  foreach my $class ("CDS", "RNA") {
    $query = &get_db_remark_query($class);
    push @qfiles, $query;
    $command = "Table-maker -p $query\nquit\n";
    open(TACE, "echo '$command' | $tace $ref_db |");
    while(<TACE>) {
      chomp;
      if (/^\"(\S+)\"\s+\"(.+)\"$/) {
        my ($obj, $dbremark) = ($1, $2);
        $dbremark =~ s/\\//g;
        
        $cds2dbremark{$obj} = $dbremark;
      }
    }
  }

  unlink @qfiles;

  return (\%cds2status, \%cds2proteinid, \%cds2dbremark);

}


########################
sub get_db_remark_query {
  my ($class) = @_;

  my $tmdef = "/tmp/dbremark_tmquery.$class.$$.def";
  open my $qfh, ">$tmdef" or 
      $log->log_and_die("Could not open $tmdef for writing\n");

  my $condition = "";
  if ($single) {
    $condition = "Condition Sequence = \"$single\""
  }

  my $db_remark_tablemaker_query = <<"EOF";
Sortcolumn 1

Colonne 1 
Width 12 
Optional 
Visible 
Class 
Class ${species}_${class}
From 1 
$condition

Colonne 2 
Width 12 
Mandatory 
Visible 
Class 
Class Text 
From 1 
Tag DB_remark 

EOF

  print $qfh $db_remark_tablemaker_query;
  close($qfh);

  return $tmdef;
}

##########################
sub get_protein_id_query {

  my $tmdef = "/tmp/pid_tmquery.$$.def";
  open my $qfh, ">$tmdef" or 
      $log->log_and_die("Could not open $tmdef for writing\n");  

  my $condition = "";
  if ($single) {
    $condition = "Condition Sequence = \"$single\""
  }

  my $protein_id_tablemaker_template = <<"EOF";

Sortcolumn 1

Colonne 1 
Width 12 
Optional 
Visible 
Class 
Class ${species}_CDS
From 1 
$condition
 
Colonne 2 
Width 12 
Mandatory 
Visible 
Class 
Class Sequence 
From 1 
Tag Protein_id 
 
Colonne 3 
Width 12 
Optional 
Visible 
Text 
Right_of 2 
Tag  HERE  
 
Colonne 4 
Width 12 
Optional 
Visible 
Integer 
Right_of 3 
Tag  HERE  
 
EOF

  print $qfh $protein_id_tablemaker_template;
  return $tmdef;

}

##########################
sub get_status_query {

  my $tmdef = "/tmp/status_tmquery.$$.def";
  open my $qfh, ">$tmdef" or 
      $log->log_and_die("Could not open $tmdef for writing\n");  


  my $condition = "Condition Live AND Species = \"$full_species_name\"";
  if ($single) {
    $condition .= " AND Sequence = \"$single\""
  }

  my $status_query = <<"EOF";

Sortcolumn 1

Colonne 1 
Width 30 
Optional 
Hidden 
Class 
Class Gene 
From 1 
$condition
 
Colonne 2 
Width 30 
Optional 
Visible 
Class 
Class CDS 
From 1 
Tag Corresponding_CDS 
 
Colonne 3 
Width 30 
Optional 
Visible 
Next_Tag 
From 2 
Tag Prediction_status 

EOF

  print $qfh $status_query;
  return $tmdef;
}
 


__END__
