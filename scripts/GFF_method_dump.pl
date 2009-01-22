#!/usr/local/bin/perl5.8.0 -w
#
# GFF_method_dump.pl
#
# by Anthony Rogers
#
# Selectively dump GFF for certain acedb methods
#
# dumps the method through sace / tace and concatenates them.
#
# Last edited by: $Author: ar2 $
# Last edited on: $Date: 2009-01-22 14:31:48 $


use lib $ENV{CVS_DIR};
use Wormbase;
use Getopt::Long;
use strict;
use Storable;
use File::stat;

my ($help, $debug, $test, $quicktest, $database, $species, @methods, @chromosomes, $dump_dir, @clones, $list,$host );
my @sequences;
my $store;
GetOptions (
	    "help"          => \$help,
	    "debug=s"       => \$debug,
	    "test"          => \$test,
	    "store:s"       => \$store,
	    "species:s"     => \$species,
	    "quicktest"     => \$quicktest,
	    "database:s"    => \$database,
	    "dump_dir:s"    => \$dump_dir,
	    'host:s'        => \$host,

	    # ive added method and methods for convenience
	    "method:s"      => \@methods,
	    "methods:s"     => \@methods,
	    "chromosomes:s" => \@chromosomes,
	    "clone:s"       => \@clones,
	    "clones:s"      => \@clones,
	    "list:s"        => \$list
	   );


my $wormbase;
if( $store ) {
  $wormbase = retrieve( $store ) or croak("cant restore wormbase from $store\n");
}
else {
  $wormbase = Wormbase->new( -debug   => $debug,
			     -test    => $test,
			     -organism=> $species
			   );
}
$species = $wormbase->species; #incase defaulting to elegans
my $log = Log_files->make_build_log($wormbase);

@methods     = split(/,/,join(',',@methods));
@chromosomes = split(/,/,join(',',@chromosomes));
@sequences = split(/,/,join(',',@clones)) if @clones;

my $giface = $wormbase->giface;
my $via_server; #set if dumping to single file via server cmds
my $port = 23100;

$database = $wormbase->autoace unless $database;
$dump_dir = "/tmp/GFF_CLASS" unless $dump_dir;
&check_options;
`mkdir -p $dump_dir/tmp` unless -e "$dump_dir/tmp";

#make sure dump_dir is writable
system("touch $dump_dir/tmp_file") and $log->log_and_die ("cant write to $dump_dir\n");


# open database connection once
if ($wormbase->assembly_type eq 'contig'){
    $via_server = 1;
    unless ($host) {
	print STDERR "you need to start a server first and tell me the host\neg /software/worm/bin/acedb/sgifaceserver /nfs/disk100/wormpub/BUILD/remanei 23100 600:6000000:1000:600000000>/dev/null)>&/dev/null\n";
	$log->log_and_die("no host passed for contig assembly");
    }
}

unless($via_server) {
	open (WRITEDB,"| $giface $database") or $log->log_and_die ("failed to open giface connection to $database\n");
}

$log->write_to("dumping methods:".join(",",@methods)."\n");
$log->write_to("dumping sequences:".join(",",@sequences)."\n");

# ensure that we do not append to an already existing GFF file and that the flock is deleted
if ($via_server) {
  unlink "$dump_dir/$species.gff";
  unlink "$dump_dir/$species.gff.flock";
}

my $count=0; # debug hack
foreach my $sequence ( @sequences ) {
  if ( @methods ) {
    foreach my $method ( @methods ) {
      if($via_server) {
    	my $file = "$dump_dir/tmp/${sequence}_${method}.$$";
	my $cmd = "gif seqget $sequence +method $method; seqfeatures -file $file";
	open (WRITEDB,"echo '$cmd' | /software/worm/bin/acedb/saceclient $host -port $port -userid wormpub -pass blablub |") or $log->log_and_die("$!\n");
	while (my $line = <WRITEDB>) {
	  if ($line =~ 'ERROR') {
	    $log->error;
	    $log->write_to("ERROR detected while GFF dumping $sequence:\n\t$line\n\n");
	    print "ERROR detected while GFF dumping $sequence:\n\t$line\n\n";
	  }
	}
	close WRITEDB;
			
	#while(stat($file)->mtime + 5  > (time)){
	#	sleep 1;
	#}
		
	
	my $sleeptime=0;
	while (-e "$dump_dir/${method}.gff.flock" && $sleeptime++<11){sleep 15}
	
	$wormbase->run_command("touch $dump_dir/${method}.gff.flock", 'no_log');
	#sleep 1;
	$wormbase->run_command("cat $file >> $dump_dir/${method}.gff",'no_log');
	$wormbase->run_command("rm $dump_dir/${method}.gff.flock", 'no_log');
	unlink $file;
      } else {
    	my $file = "$dump_dir/${sequence}_${method}.gff";
	my $command = "gif seqget $sequence +method $method; seqactions -hide_header; seqfeatures -version 2 -file $file\n";
	print WRITEDB $command;
      }
    }
  } else {
    if($via_server) {
      print "In here\n";
      my $file = "$dump_dir/tmp/gff_dump$$"; 
      my $cmd = "gif seqget $sequence; seqfeatures -file $file";
      open (WRITEDB,"echo '$cmd' | /software/worm/bin/acedb/saceclient $host -port $port -userid wormpub -pass blablub |") or $log->log_and_die("$!\n");
      while (my $line = <WRITEDB>) {
	if ($line =~ 'ERROR') {
	  $log->error;
	  $log->write_to("ERROR detected while GFF dumping $sequence:\n\t$line\n\n");
	  print "ERROR detected while GFF dumping $sequence:\n\t$line\n\n";
	}
      }
      close WRITEDB;
		
      #while(stat($file)->mtime + 5  > (time)){
      #	sleep 1;
      #}
      
      my $sleeptime=0;
      while (-e "$dump_dir/${species}.gff.flock" && $sleeptime++<11){sleep 15}
      $wormbase->run_command("touch $dump_dir/$species.gff.flock");
      #sleep 1;
      $wormbase->run_command("cat $file >> $dump_dir/$species.gff");
      $wormbase->run_command("rm $dump_dir/$species.gff.flock");
      #unlink $file;
    } else {
      my $command = "gif seqget $sequence; seqactions -hide_header; seqfeatures -version 2 -file $dump_dir/$sequence.gff\n";
      print "$command";
      print WRITEDB $command;
    }
  }
  $count++;
}

unless($via_server) {
  close (WRITEDB) or $log->log_and_die ("failed to close giface connection to $database\n");
}

$log->write_to("dumped $count sequences\n");

##################
# Check the files
##################
if($wormbase->species eq 'elegans'){
foreach my $sequence ( @sequences ) {
 if ( @methods ) {
   foreach my $method ( @methods ) {

     my $method_name = $method;
     if ($method eq 'SNP') {$method_name = 'Allele'} # The SNP method has its GFF Source named allele

     $wormbase->check_file("$dump_dir/${sequence}_${method}.gff", $log,
			   lines => ['^##', 
				     "^${sequence}\\s+(Link|GenePair_STS|Genomic_canonical|${method_name})\\s+\\S+\\s+\\d+\\s+\\d+\\s+\\S+\\s+[-+\\.]\\s+\\S+\\s+\\S+",
				     "^${sequence}\\s+assembly_tag\\s+\\S+\\s+\\d+\\s+\\d+\\s+\\S+\\s+[-+\\.]",
				     "^${sequence}\\s+\\.\\s+\\S+\\s+\\d+\\s+\\d+\\s+\\S+\\s+[-+\\.]\\s+\\S+"],
			   );
   }
 } else { 
   # we assume that these are the full chromosome dumps (before processing and munging)
   my %sizes = (
		'CHROMOSOME_I'       => 150000000,
		'CHROMOSOME_II'      => 150000000,
		'CHROMOSOME_III'     => 150000000,
		'CHROMOSOME_IV'      => 180000000,
		'CHROMOSOME_V'       => 190000000,
		'CHROMOSOME_X'       => 120000000,
		'CHROMOSOME_MtDNA'   =>   1500000,
		);
   $wormbase->check_file("$dump_dir/$sequence.gff", $log,
			 minsize => $sizes{$sequence},
			 lines => ['^##', 
				   "^${sequence}\\s+\\S+\\s+\\S+\\s+\\d+\\s+\\d+\\s+\\S+\\s+[-+\\.]\\s+\\S+"],
			 gff => 1,
			 );   
 }
}
}


# remove write test
system("rm -f $dump_dir/dump");

$log->mail();
exit(0);



#############################################################################################

sub check_options {


  unless($list or @clones ) {

    # -chromosomes
     
    my @chrom =  $wormbase->get_chromosome_names(-mito => 1, -prefix => 1);

    my %chroms = map {$_ => 1} $wormbase->get_chromosome_names(-mito => 1, -prefix => 1);
  
    unless (@chromosomes ) {
      @sequences= @chrom;
      print "Dumping for all chromosomes\n";
    } 
    else {
      foreach (@chromosomes) {
    	if ( $chroms{$_} ) {
	      push( @sequences,$_);
	    }
	    else {
	      $log->log_and_die ("$_ is not a valid chromosome\n");
	    }
      }
    }
  }
  
  &process_list if $list;

  # -database
  if ( $database ){
    if( -e "$database" ) {
      if( -e "$database/wspec/models.wrm" ) {
	     print "$database OK\nDumping @methods for chromosomes @chromosomes\n";
	     return;
      }
    }
  }
  else {
	    $log->log_and_die ("You must enter a valid database\n");
	  }
  $log->log_and_die ("$database is not a valid acedb database\n");	
}

sub process_list
  {
    open(LIST,"<$list") or $log->log_and_die ("bad list $list\n");
    while(<LIST>) {
      chomp;
      push(@sequences,$_);
    }
  }

=pod 

=head1 NAME - GFF_method_dump.pl

=head2 USAGE

=over 4

This script will GFF dump specified methods from a database

It is use by dump_gff_batch.pl so if you change it make sure it is still compatible !

=back

=item MANDATORY ARGS:

=over 4

-methods     Methods to dump eg curated,history (Comma separated list)

=back

=item OPTIONAL ARGS:

=over 4

-database    Database to dump from ( default /wormsrv2/autoace )

-chromosomes Chromosomes to dump as comma separated list eg I,II,X ( defaults to all )

=back

=item OUTPUT:

=over 4

A separate file is written for each method for each chromosome and is named 

CHROMOSOME_($chrom)_($method).gff

=back

=item EXAMPLES:

=over 4

GFF_method_dump.pl -database wormsrv2/autoace -chromosomes II,V -method curated,TRANSCRIPT

will GFF dump separate curated and TRANSCRIPT files for both chromosomes II and V ie

  CHROMOSOME_II_curated.gff
  CHROMOSOME_II_TRANSCRIPT.gff
  CHROMOSOME_V_curated.gff
  CHROMOSOME_V_TRANSCRIPT.gff

=back

=item REQUIREMENTS:

=over 4

Access to ~acedb for giface binary

=back

=item WARNING:

=over 4

At time of writing the version of acedb (4.9y) adds extra data to the GFF output. Eg if you ask for method curated you also get a load of ALLELES that have no method, so the GFF files pr
oduced should be treated with caution and may need post-processing.

=back

=cut
