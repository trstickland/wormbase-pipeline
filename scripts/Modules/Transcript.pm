package Transcript;

use lib $ENV{'CVS_DIR'} ;
use Carp;
use strict;
use Modules::SequenceObj;

our @ISA = qw( SequenceObj );

sub new
  {
    my $class = shift;
    my $name = shift;
    my $CDS = shift;
    my $transformer = $CDS->transformer;
    my $self = SequenceObj->new($name, $CDS->exon_data, $CDS->strand);
    $self->{'feature'}->{ "SL" } = $CDS->feature('SL') if ($CDS->feature('SL')); # add CDS SL feature to any new transcript

    bless ( $self, $class );

    $self->transformer($transformer) if $transformer;
    $self->cds( $CDS ) if $CDS;
    return $self;
  }

sub cds
  {
    my $self = shift;
    my $cds = shift;

    $self->{'cds'} = $cds if $cds;
    return $self->{'cds'};
 }

sub map_cDNA
  {
    my $self = shift;
    my $cdna = shift;

    # check for overlap
    if( $self->start > $cdna->end ) {
      return 0;
    }
    elsif( $cdna->start > $self->end ) {
      return 0;
    }
    else {
      if (not $self->check_features($cdna)) {
        return 0;
      }
      
      #check exon matching
      my $match = $self->check_exon_match( $cdna );
      if( $match == 1 ) {
	$match = $cdna->check_exon_match( $self );
	unless ($match == 0) { 
	  $self->add_matching_cDNA( $cdna );
	  $match = 1;
	}
      }
      return $match;
    }
  }


# check if two transcripts ($self and $other) have duplicate structure
sub duplicate {
  my $self = shift;
  my $other = shift;
  
  if (!defined $self) {return}
  
  # check for exact match
  if( $self->start != $other->start ) {
    return 0;
  } elsif( $self->end != $other->end ) {
    return 0;
  } elsif (scalar @{$self->sorted_exons} != scalar @{$other->sorted_exons}) {
    return 0;
  }
  
  foreach my $exon_idx (0 .. $#{$self->sorted_exons}) {
    if ($self->{sorted_exons}->[$exon_idx]->[0] != $other->{sorted_exons}->[$exon_idx]->[0]) {
      return 0;
    }
    if ($self->{sorted_exons}->[$exon_idx]->[1] != $other->{sorted_exons}->[$exon_idx]->[1]) {
      return 0;
    }
  }
  return 1;
}

# check if two transcripts ($self and $other) have near-duplicate structures
# i.e. introns exactly match and the 5'/3' ends are near each other
# the distance between the different 5' and 3' ends that should be considered suitable for 
# being a true near-duplicate are given by the arguments $fiveprimedelta and $threeprimedelta
sub near_duplicate {
  my ($self, $other, $fiveprimedelta, $threeprimedelta) = @_;

  if (!defined $self) {return}
  
  # check for near match of start and end
  if( abs($self->start - $other->start) > $fiveprimedelta ) {
    return 0;
  }
  if( abs($self->end - $other->end) > $threeprimedelta ) {
    return 0;
  }
  if (scalar @{$self->sorted_exons} != scalar @{$other->sorted_exons}) {
    return 0;
  }

  # check for exact matches of introns
  foreach my $intron_idx (0 .. $#{$self->sorted_introns}) {
    if ($self->{sorted_introns}->[$intron_idx]->[0] != $other->{sorted_introns}->[$intron_idx]->[0]) {
      return 0;
    }
    if ($self->{sorted_introns}->[$intron_idx]->[1] != $other->{sorted_introns}->[$intron_idx]->[1]) {
      return 0;
    }
  }

  # we want two transcripts, each with SL or polyA site features that are different, to be distinguished as being different, not a near duplicate
  if ($self->SL && $other->SL) {
    if ($self->SL->[1] != $other->SL->[1]) {return 0}
  }

  if ($self->polyA_site && $other->polyA_site) {
    if ($self->polyA_site->[1] != $other->polyA_site->[1]) {return 0}
  }

  return 1;

}



# check whether any of the cDNA introns match the introns in this CDS
# store the number of consecutive introns in $cDNA with the name of the CDS
sub map_introns_cDNA {
  my $self = shift;
  my $cdna = shift;
  
  # check for overlap
  if( $self->start > $cdna->end ) {
    #printf "REJECTING CDS starts beyond cDNA %s %s\n", $self->name, $cdna->name;
    return 0;
  }
  elsif( $cdna->start > $self->end ) {
    #printf "REJECTING cDNA starts beyond CDS %s %s\n", $self->name, $cdna->name;
    return 0;
  }
  else {
    #this must overlap - check Splice Leader
    #if (not $self->check_features($cdna)) {
      #printf "REJECTING - failed feature check %s %s\n", $self->name, $cdna->name;
    #  return 0;
    #}

    # count the number of contiguous introns which match
    my $matching_introns = $self->check_intron_match( $cdna );

    # want to check later on if this cDNA matches any other CDSs
    # better, so don't make a hard match assignment yet, just store
    # the results
    return $matching_introns;
  }
}
  
sub add_3_UTR
  {
    my $self = shift;
    my $cdna = shift;

    return if( $self->polyA_site or $self->polyA_signal) ;

    # set match code for interpretation in add_matching_cDNA
    foreach my $exon ( @{$cdna->sorted_exons} ) {
      $exon->[2] = 12;
    }
    $self->add_matching_cDNA($cdna)
  }

# this adjusts the exons boundaries (and makes a new exon if required) based on the match_codes made by SequenceObj::check_exon_match
# it keeps a note of which cDNAs gave supporting evidence for which exons, so we can later prune transcripts with weak evidence
sub add_matching_cDNA
  {
    my $self = shift;
    my $cdna = shift;
    push( @{$self->{'matching_cdna'}},$cdna);

    my $name = $cdna->name;

###### modify current transcript structure to incorporate new cdna #####

#   match_codes
#  1 = Exact Match
# *2 = last SeqObj exon                   ( so may extend past exon end )
#  3 = last cDNA exon                     ( so may stop within exon )
# *4 = 1st exons end in same place
# *5 = cDNA exon covers 1st gene exon
#  6 = 1st exon of cDNA starts in exon of SeqObj
#  7 = Match cDNA contained in exon
# *8 = cDNA final exon overlaps first exon of gene and end therein
# *9 = final cDNA exon starts in final gene exon and continues past end
# *10 = 5'UTR exon
# *11 = 3'UTR exon
#  12 = downstream of existing transcript
#  13 = single exon gene extends both ends.
#  14 = spliced 3' UTR exon past current model

########################################################################

    
    foreach my $exon ( @{$cdna->sorted_exons} ) {
      my $match_code = $exon->[2];
      if  ($match_code == 1 or $match_code == 3 or $match_code == 6 or $match_code == 7) {
	$self->{'evidence'}{"$exon->[0]"}{$name} = 1; # add cDNA name as evidence for this exon
	next;
      }

      # extend 3'
      if( $match_code == 2 or $match_code == 9 ) {
	# cdna overlaps last exon so extend - need to take in to account it may still be spliced past the CDS end.
        if ($self->polyA_site and $exon->[1] > $self->polyA_site->[0]) {
          # do not extend - this looks like a badly clipped cDNA

	  $self->{'evidence'}{"$exon->[0]"}{$name} = 1; # add cDNA name as evidence for this exon
        } else {
          my $last_exon_start = $self->last_exon->[0];
          $self->{'exons'}->{"$last_exon_start"} = $exon->[1];

	  $self->{'evidence'}{"$exon->[0]"}{$name} = 1; # add cDNA name as evidence for this exon
        }
      }
      # extend 5'
      elsif( $match_code == 4  or $match_code == 5 or $match_code == 8 ) {
	# 1st exons overlap so extend 5'
	my $curr_start = $self->start;

	$self->{'evidence'}{"$curr_start"}{$name} = 1; # add cDNA name as evidence for this exon
	next if( $curr_start < $exon->[0] );

	my $exon_end = $self->sorted_exons->[0]->[1];

        if ($self->SL and $exon->[0] < $self->SL->[1]) {
          # do not extend - this looks like a badly clipped cDNA
        } else {
	  # move the cDNA evidence names from the old exon start to the new one
	  my @names = keys %{$self->{'evidence'}{"$curr_start"}};
	  foreach my $name (@names) {
	    $self->{'evidence'}{"$exon->[0]"}{$name} = 1; # add cDNA name as evidence for this exon
	  }
	  delete $self->{'evidence'}{"$curr_start"};

          delete $self->exon_data->{$curr_start};
          $self->{'exons'}->{"$exon->[0]"} = $exon_end;
        }
      }
      elsif( $match_code == 10  or $match_code == 11 ) {
	# add exon to UTR
	$self->{'exons'}->{"$exon->[0]"} = $exon->[1];

	$self->{'evidence'}{"$exon->[0]"}{$name} = 1; # add cDNA name as evidence for this exon
      }
      # extending 3'UTR with non-overlapping cDNAs
      elsif( $match_code == 12) {
	$self->{'evidence'}{"$exon->[0]"}{$name} = 1; # add cDNA name as evidence for this exon

	if ( $cdna->start == $exon->[0]) { 
	  #extend existing
	  my $last_exon_start = $self->last_exon->[0];
	  $self->{'exons'}->{"$last_exon_start"} = $exon->[1];
	}
	else {
	  #add new exon
	  $self->{'exons'}->{"$exon->[0]"} = $exon->[1];
	}
      }
      elsif( $match_code == 14 ) {
	$self->{'evidence'}{"$exon->[0]"}{$name} = 1; # add cDNA name as evidence for this exon

	$self->exon_data->{"$exon->[0]"} = $exon->[1];
      }
      # single exon gene extend both ends
      elsif( $match_code == 13 ) {	

	# 5' extension
	my $curr_start = $self->start;
	my $exon_end = $self->sorted_exons->[0]->[1];

        if ($self->SL and $exon->[0] < $self->SL->[1] or
            $self->polyA_site and $exon->[1] > $self->polyA_site->[0]) {
          # do not extend - probably a badly cDNA
        } else {
	  $self->{'evidence'}{"$exon->[0]"}{$name} = 1; # add cDNA name as evidence for this exon
	  # move the cDNA evidence names from the old exon start to the new one
	  my @names = keys %{$self->{'evidence'}{"$curr_start"}};
	  foreach my $name (@names) {
	    $self->{'evidence'}{"$exon->[0]"}{$name} = 1; # add cDNA name as evidence for this exon
	  }
	  delete $self->{'evidence'}{"$curr_start"};

          delete $self->{'exons'}->{$curr_start};
          $self->{'exons'}->{"$exon->[0]"} = $exon->[1];
	
          #	# 3' extension
          #	my $last_exon_start = $self->last_exon->[0];
          #	$self->{'exons'}->{"$last_exon_start"} = $exon->[1];
        }
      }	
    }
    # reset start end etc . . 
    $self->sort_exons;

    # update gene start and end
    $self->cds->gene_start( $self->start );
    $self->cds->gene_end  ( $self->end );

# want to only add SL site if we do not already have an SL site set (e.g. by the curator asserting the Isoform starts at a Feature)
    if( !defined $self->SL) {
      if (my $SL = $cdna->SL){
	$self->SL( $SL );
      }
    }
    if ( my $polyA_site = $cdna->polyA_site ) {
      $self->polyA_site( $polyA_site )  ;
    }
    if (my $polyA_signal = $cdna->polyA_signal ) {
      $self->polyA_signal( $polyA_signal ) ;
    }
  }

sub report
  {
    my $self = shift;
    my $fh = shift;
    my $coords = shift;
    my $species = shift;
    my $gene_name = shift;
    my $is_primary = shift;

    if (exists $self->{'ignore'}) {return}

    my $real_start = $self->start;
    my $real_end = $self->end;

    if( $self->strand eq "-" ) {
      $real_start = $self->transformer->revert_to_neg( $self->start );
      $real_end = $self->transformer->revert_to_neg( $self->end );
    }

    # evil way to treat non-elegans species chromosome names
    my $chr=$self->chromosome;
    #$chr="${\$coords->{chromosome_prefix}}$chr" if $coords->{species} ne 'elegans';

    my @clone_coords = $coords->LocateSpan($chr, $real_start,$real_end );

    # output S_Parent for transcript
    print $fh "\nSequence : $clone_coords[0]\n";
    print $fh "Transcript \"",$self->name,"\" $clone_coords[1] $clone_coords[2]\n";

    # . . and the transcript object
    print $fh "\nTranscript : \"", $self->name,"\"\n";
    our $start = $self->start - 1;
    our $end = $self->end + 1;
    my $exon_1 = 1;
    foreach my $exon ( @{$self->sorted_exons} ) {    
      my $exon_start = $exon->[0] - $start;
      my $exon_end = $exon->[1] - $start;
      print $fh "Source_exons\t$exon_start\t$exon_end\n";
    }

    # . . and Matching_cDNA
    foreach (@{$self->{'matching_cdna'}}) {
      print $fh "Matching_cDNA \"",$_->name,"\" Inferred_Automatically \"transcript_builder.pl\"\n";

      foreach my $f ( $_->features ) {
	print $fh "Associated_feature $f\n";
      }
    }
    print $fh "Gene \"$gene_name\"\n" if defined $gene_name;
    print $fh "Species \"$species\"\n";
    #
    # emit the mRNA tag if the transcript has been denoted as primary. This will make it appear as an 
    # mRNA feature in the EMBL dumps
    #
    print $fh "mRNA\n" if $is_primary;
    print $fh "Method Coding_transcript\n";  

    foreach (@{$self->{'matching_cdna'}}) {
      print $fh "\nSequence : \"",$_->name,"\"\n";
      print $fh "Matching_transcript ",$self->name," Inferred_Automatically \"transcript_builder.pl\"\n";
    }
  }


=head2 delete

    Title   :   delete
    Usage   :   $transcript->delete
    Function:   deletes the object
    Returns :   
    Args    :   none

=cut

sub delete {
   my $self = shift;
   foreach my $matching_cdna (@{$self->{'matching_cdna'}}) {
     $matching_cdna->delete;
   }
   undef (%$self);
}

1;
