#!/usr/local/bin/perl5.6.1 -w

# krb 020829

# converts yeastX.pep file with yeast peptide entries into ace file
# Puts SGDID as Accssion in Database field.

my $dir = glob("~wormpipe/BlastDB");
my $acefile = "$dir/yeast.ace";

my $source_file = shift;
my $pepfile = shift;
use strict;

# this bit creates a DBM database of ORF => description
use DB_File;

my $DB_dir = "/tmp";
# DBM files 
my $ace_info_dbm = "$DB_dir/ace_info.dbm";
my %ACE_INFO;

if( -e $ace_info_dbm ) {  #make sure starting with new dbase
  `rm -f $ace_info_dbm` || die "cant remove $ace_info_dbm: $!\n";
}
my %YEAST_DESC;
dbmopen  (%YEAST_DESC ,"$ace_info_dbm", 0777) or die "cant open $ace_info_dbm :$!\n";

# get the latest info
`wget -O $DB_dir/yeast ftp://genome-ftp.stanford.edu/yeast/data_download/gene_registry/registry.genenames.tab`;
open (YEAST , "<$DB_dir/yeast");
my $linecount;
while (<YEAST>) {
  $linecount++;
  chomp;
  my @info = split(/\t/,$_);
  my $desc;
  if("$info[2]" eq "" ) {
    #check $info[3]
    if("$info[3]" ne "" ) {
      $desc = $info[3];
    }
  }
  else {
    $desc = $info[2];
  }
  next unless $desc;
  if( (defined $info[5]) and (defined $desc) ){
    $YEAST_DESC{$info[5]} = "$desc";
  }
}

# now extract info from main FASTA file and write ace file
open (SOURCE,"<$source_file");
open (PEP,">$pepfile");
open (ACE,">$acefile");

while (<SOURCE>) {
  if( />/ ) { 
    if (/ORFP:(\S+)\s+(\S+)\s+SGDID:(\w+)/) {
      my $ID = $1;
      print ACE "\nProtein : \"SGD:$ID\"\n";
      print ACE "Peptide \"SGD:$ID\"\n";
      print ACE "Species \"Saccharomyces cerevisiae\"\n";
      print ACE "Gene_name  \"$2\"\n";
      print ACE "Database \"SGD\" \"SGD_systematic_name\" \"$ID\"\n";
      print ACE "Database \"SGD\" \"SGDID\" \"$3\"\n";
      print ACE "Description \"$YEAST_DESC{$ID}\"\n" if $YEAST_DESC{"$ID"};

      print ACE "\nPeptide : \"SGD:$ID\"\n"; 	
      
      print PEP "\>$ID\n";
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

print "\n\nabout to copy (scp) $acefile to /wormsrv2/wormbase/ensembl_dumps/\n";
system ("scp -r $acefile wormpub\@wormsrv2:/wormsrv2/wormbase/ensembl_dumps/") and warn "copy $acefile failed\n";

print "\n$source_file is now converted to $pepfile...now removing $source_file\n";
system ("rm -f $source_file") and warn "removing $source_file failed\n";
__END__

