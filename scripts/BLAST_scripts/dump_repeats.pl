#!/usr/local/ensembl/bin/perl -w

use DBI;
use strict;
use lib -e "/wormsrv2/scripts" ? "/wormsrv2/scripts" : $ENV{'CVS_DIR'};
use Getopt::Long;
use Wormbase;

#######################################
# command-line options                #
#######################################
my ($test, $debug, $help);

GetOptions ("debug"   => \$debug,
	    "test"    => \$test,
	    "help"    => \$help,
           );


my $dump_dir = "/wormsrv2/wormbase/ensembl_dumps";
$dump_dir = glob("~wormpub/TEST_BUILD/") if $test;
my $acedb_database;
my $output = "$dump_dir/repeats.ace";
die &help if $help;

$output .= "_test" if $test;

open (OUT,">$output") or die "cant open $output\n";


# retrieve hash of acc2clone
my %acc2clone;
&FetchData("acc2clone",\%acc2clone);



my %clonesize;
&FetchData("clonesize", \%clonesize);

# mysql database parameters
my $dbhost = "ecs1f";
my $dbuser = "wormro";
my $dbname = "worm_dna";
my $dbpass = "";

my $wormrepeats_DB = DBI -> connect("DBI:mysql:$dbname:$dbhost", $dbuser, $dbpass, {RaiseError => 1})
      || die "cannot connect to db, $DBI::errstr";


#retrieves descriptive information about the repeats from the database
my %repeat_info;
&GetRepeatInfo;


# build hash of internal_id to clone via EMBL accession
my $sth_f = $wormrepeats_DB->prepare ( q{SELECT
					 clone_id , name
					 FROM clone
	  	  	     } );

my %int_id2clone;

$sth_f->execute;
my $ref_results = $sth_f->fetchall_arrayref;

foreach my $pair (@$ref_results) {
  my $int_id = $$pair[0];
  my $acc = $$pair[1];
  my $clone = $acc2clone{$acc};

  if ($clone) {
    $int_id2clone{$int_id} = $clone;
  }
  else {
    print "no clone found for acc $acc : internal_id $int_id\n";
  }
}

# now retrieve the data from wormrepeats database
$sth_f = $wormrepeats_DB->prepare ( q{SELECT
				      contig_id, contig_start, contig_end,
				      score, contig_strand,
				      repeat_start,repeat_end,repeat_consensus_id
				      FROM repeat_feature
				      WHERE analysis_id = 10
				      AND score > 225
				      ORDER BY contig_id
				     }
				  );

$sth_f->execute;
$ref_results = $sth_f->fetchall_arrayref;
my ($contig, $seq_start, $seq_end, $score, $strand, $hstart, $hend, $hid);
my $current_clone = "";
my $clone;
foreach my $repeat (@$ref_results) {
  ($contig, $seq_start, $seq_end, $score, $strand, $hstart, $hend, $hid) = @$repeat;
  
  if($int_id2clone{$contig}) {
     $clone = $int_id2clone{$contig};
    if( "$clone" ne "$current_clone" ) {
      $current_clone = $clone;
      print OUT "\nSequence : \"$clone\"\n";
      print OUT "Homol_data $clone:RepeatMasker 1 $clonesize{$clone}\n\n";
      print OUT "Homol_data : $clone:RepeatMasker\n";      
    }
    print OUT "Motif_homol ",$repeat_info{$hid}->{'name'} ," RepeatMasker $score $seq_start $seq_end";
    if( $strand == 1 ){
      print OUT " $hstart $hend\n";
    }
    else {
      print OUT " $hend $hstart\n";
    }
  }
  else {
    undef $clone;
  }
}

close OUT;

exit(0);  

sub GetRepeatInfo
  {
    my $info = $wormrepeats_DB->prepare ( q{ SELECT * from repeat_consensus} );
    $info->execute;

    my $info_data = $info->fetchall_arrayref;
    foreach my $repeat ( @$info_data ) {
      $repeat_info{$$repeat[0]}->{'name'} = $$repeat[1];
      $repeat_info{$$repeat[0]}->{'class'} = $$repeat[2];
    } 
  }


sub help
  {
    print "===============================================\n$0\n
Extract RepeatMasker data from worm_dna on ecs1f\n\n
Writes ace file $output\n
\t\t-test appends _test to output filename.

Must be able to access Wormbase.pm\
Takes about 2 mins to dump whole genome\n\n
================================================\n\n";
  }

