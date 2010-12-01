#/software/bin/perl -w
#
# make_acefiles.pl 
#
# dl1
#
# Generates the .acefiles from the primary databases as a prelim for building
# autoace.
#
# Last updated by: $Author: mh6 $
# Last updated on: $Date: 2010-12-01 11:57:32 $

#################################################################################
# Variables                                                                     #
#################################################################################

use strict;
use lib $ENV{'CVS_DIR'};
use Wormbase;
use Getopt::Long;
use File::Path qw(make_path);
use Log_files;
use Storable;

##############################
# command-line options       #
##############################

my $debug;      # Debug mode, verbose output to runner only
my $test;        # If set, script will use TEST_BUILD directory under ~wormpub
my $db;
my $store;
my $species;
my ($syntax, $merge);

GetOptions (    'debug=s'    => \$debug,
        		'db:s'       => \$db,     # seems to be the primary database name, to dump subsets
        		'test'       => \$test,
        		'store:s'    => \$store,
        		'species:s'  => \$species,
        		'syntax'     => \$syntax, # checks the syntax of the config file without dumping the acefile
        		'merge'      => \$merge   # create the ace file for mrging databases at the end of the Build
) ||die($!);

my $wormbase;
if( $store ) {
    $wormbase = retrieve( $store ) or croak("cant restore wormbase from $store\n");
}
else {
    $wormbase = Wormbase->new( -debug   => $debug,
                   			   -test    => $test,
                   			   -organism => $species
    );
}

my $log = Log_files->make_build_log($wormbase);
my $elegans = $wormbase->build_accessor;

my $config = $wormbase->basedir.'/autoace_config/'.$wormbase->species;
$config .= '.merge' if $merge;
$config .='.config';

my $tace = $wormbase->tace;
my $path = $wormbase->acefiles.($merge ? '/MERGE':'/primaries');
make_path $path unless -e $path;
 
unless (-e $config) {
  $log->write_to("merge config file absent - database being skipped\n");
} else {
  open(CFG,"<$config") or $log->log_and_die("cant open $config :$!\n");
  
  my $dbpath = '';
  while(<CFG>) {
    next if /#/;
    next unless /\w/;
    my %makefile;
    foreach my $pair (split(/\t+/,$_)) {
      my($tag,$value) = ($pair =~ /(\w+)=(.*)/);
      if( $tag and $value) {
        if ($tag eq 'format') {
            $value =~ s/"//g;
            my ($classname, $classregex) = split /\s/, $value;
            push(@{$makefile{$tag}},[$classname, $classregex]);
        } elsif ($tag =~ /\ / || ($value =~ /\ / && $value !~ /\(/)) {
            $log->log_and_die("Ill formed config line with space instead of TAB around $tag=$value:\n$_\n");
        } elsif ($tag eq 'delete') {
            push(@{$makefile{$tag}},$value);
        } else {
            $makefile{$tag} = $value;
        }   
      }
      else {
        $log->log_and_die("Ill formed config line:\n$_\n");
      }
    }
    next if $syntax;
    my $query = "nosave\nquery ";
    if( $makefile{'class'} and  $makefile{'db'} and  $makefile{'file'} ) {
      if ($db) {
          next unless ($makefile{'db'} eq $db);
      }
      make_path("$path/".$makefile{'db'}) unless -e "$path/".$makefile{'db'};
      my $file = $path."/".$makefile{'db'}."/".$makefile{'file'};
      open(ACE,">$file") or $log->log_and_die("cant open file $file : $!\n");
      
      if($makefile{'class'} eq 'DNA') {
        $query .= 'find Sequence';
      }else {
        $query .= 'find '.$makefile{'class'};
      }
      if( $makefile{'query'} ) {
        $query .= ' WHERE '.$makefile{'query'};
      }
      $query .= "\n";    
      if( $makefile{'delete'} ) {    
        foreach my $del (@{$makefile{'delete'}}) {   
            $query .= "eedit -D $del\n";
        }
      }
      if($makefile{'class'} eq 'DNA') {
        $query .= "FOLLOW DNA\n";
      }
      if( $makefile{'follow'} ) {
        $query .= "show -T ".$makefile{'follow'}." -a\n"; #output parent + followed tag
        $query .= "FOLLOW ".$makefile{'follow'}."\n";
      }
      $query .= 'show -T -a ';
      if( $makefile{'tag'} ) {
        $query .= ' -t '.$makefile{'tag'};
      }
      $query .= "\n";

      # prepare the required tags
      my @required = split ',', $makefile{'required'};
      my %required;

      # run the command
      my $acedb = $dbpath.'/'.$makefile{'db'};
      $log->write_to("dumping $makefile{'class'} from $acedb\n");
      my $object_name;
      open(TACE,"echo '$query' | $tace $acedb | ") or $log->log_and_die("cant do query : $!\n");
    LINE: while(my $line = <TACE>) {
    	next if ($line =~ /acedb>/ or $line =~ /^\/\//);
    	if( $makefile{'regex'} ) {  
      		unless ($line =~ /[^\w]/ or $line =~ /$makefile{'class'}\s+\:\s+/ or $line =~ /$makefile{'follow'}\s+\:\s+/) {
        		next LINE unless ($line =~ /$makefile{'regex'}/);
      		}         
    	}

    # check the integrity of the object names and tag values
    if ($makefile{'format'} || $makefile{'required'}) {
      if ($line =~ /$makefile{'class'}\s+\:\s+(\S+)/) { # checkfor the start of a new object
        # check to see if the required tags are in the previous object
        if (defined $object_name) { # ignore if we are at the first object
          foreach my $req (@required) {
            if (! exists $required{$req}) {$log->write_to("Missing required tag '$req' in object:\n$makefile{'class'} : $object_name\nFile: $file\n\n")}
            delete $required{$req}; # reset the existence of the required tags in this object
          }
        }

        $object_name=$1; # remember the name of this object so the error can be reported nicely
      } else {
        # check for the correct regex format in selected tags
        foreach my $format (@{$makefile{'format'}}) {
          if ($line =~ /$format->[0]\s+\-O\s+\S+\s+\"(\S+)\"/) {
            my $regex = $format->[1];
            if ($1 !~ /^${regex}$/) {
                $log->write_to("Invalid object name format: $file\n$makefile{'class'} : $object_name\n$format->[0] $1\n\n")
            }
          }
        }
        
        # check for required tags in this line
        foreach my $req (@required) {
          if ($line =~ /$req\s+\-O\s+\S+/) {
            $required{$req} = 1; # note we have found this required tag
          }
        }
      }
    }

    print ACE $line;
    }
    close TACE;
    close ACE;
   } elsif ($makefile{'path'}) {
      my $sub = $makefile{'path'};
      $dbpath = $wormbase->$sub;
   }
  }
}   

$log->write_to("syntax ok\n") if $syntax; #will have died before here if not ok
$log->mail;
    
    
    
    
    
