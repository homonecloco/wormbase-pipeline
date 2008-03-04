#!/usr/local/bin/perl5.8.0 -w 
#
# initiate_build.pl
#
# Last edited by: $Author: mh6 $
# Last edited on: $Date: 2008-03-04 16:49:24 $

use strict;
use lib $ENV{'CVS_DIR'};
use Wormbase;
use Getopt::Long;
use Coords_converter;
use File::Copy;
use File::Spec;
use Storable;

my ($test,$debug,$database, $version);
my ($store, $wormbase, $user);
GetOptions (
	    'test'       => \$test,
	    'debug:s'    => \$debug,
	    'database:s' => \$database,
	    'version:s'  => \$version,
	    'store:s'    => \$store,
	    'user:s'     => \$user,
	   );

if( $store ) {
  $wormbase = retrieve( $store ) or croak("cant restore wormbase from $store\n");
}
else {
  $wormbase = Wormbase->new( -debug   => $debug,
			     -test    => $test,
			   );
}

# strip off the WS if given
if ($version =~ /^WS(\d+)/) {
  $version = $1;
}
# check it looks OK
if ($version !~ /^\d\d\d$/) {
  die "The version should be given as three digits\n";
}

$wormbase->establish_paths;
#copy the genefinder files 
$wormbase->run_command("cp -r ".$wormbase->build_data."/wgf ".$wormbase->autoace."/wgf");

# set the new version number
$wormbase->version($version);

# establish log file.
my $log = Log_files->make_build_log($wormbase);

$log->log_and_die( "version to build not specified\n") unless $wormbase->version;

#################################################################################
# initiate autoace build                                                        #
#################################################################################

## update CVS wspec, wquery and autoace_config from CVS
$wormbase->run_command("cd ".$wormbase->autoace.'; cvs -d :pserver:cvsuser@cvsro.sanger.ac.uk:/cvsroot/ensembl checkout -d wspec wormbase/wspec', $log);
$wormbase->run_command("cd ".$wormbase->autoace.'; cvs -d :pserver:cvsuser@cvsro.sanger.ac.uk:/cvsroot/ensembl checkout -d wquery wormbase/wquery', $log);
$wormbase->run_command("cd ".$wormbase->basedir.'; cvs -d :pserver:cvsuser@cvsro.sanger.ac.uk:/cvsroot/ensembl checkout -d autoace_config wormbase/autoace_config', $log);

## make new build_in_process flag ( not done yet in rebuild )

## update database.wrm using cvs
my $cvs_file = $wormbase->autoace."/wspec/database.wrm";
$wormbase->run_command("sed 's/WS0/WS${version}/' < $cvs_file > ${cvs_file}.new", $log);  #  the version in CVS is WS94
my $status = move(${cvs_file}.".new", "$cvs_file") or $log->write_to("ERROR: renaming file: $!\n");
$log->write_to("ERROR: Couldn't move file: $!\n") if ($status == 0);

# add lines to the logfile
my $msg = "Updated WormBase version number to WS".$wormbase->version."\n";
$msg .= "You are ready to build another WormBase release\n";
$msg .= "Please tell camace and geneace curators to update their database to use the new models!!!\n\n";

$log->write_to($msg);
$log->mail;
exit(0);

__END__
