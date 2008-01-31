#!/nfs/disk100/wormpub/bin/perl
#
# wormBLAST.pl
# 
# written by Anthony Rogers
#
# Last edited by: $Author: mh6 $
# Last edited on: $Date: 2008-01-31 11:23:54 $


use DBI;
use strict;
my $wormpipe_dir = '/lustre/work1/ensembl/wormpipe';
use lib $ENV{'CVS_DIR'};
use lib $ENV{'CVS_DIR'}."/BLAST_scripts";
use Wormbase;
use Getopt::Long;
use File::Path;
use File::Copy;
use Storable;

#######################################
# command-line options                #
#######################################

my $chromosomes;
my ($wormpep, $brigpep,$remapep);
my $update_databases;
my $update_mySQL;
my $setup_mySQL;
my $run_pipeline;
my $run_brig;
my $dont_SQL;
my $dump_data;
my $distribute;
my $test_pipeline;
my $WPver;   #  Wormpep version is passed as command line option
my $blastx;
my $blastp;
my $prep_dump;
my $cleanup;
my $errors = 0; # for tracking global error - needs to be initialised to 0
my $debug;
my $test;
my $WS_version;
my $store;

GetOptions("chromosomes" => \$chromosomes,
	   "wormpep"     => \$wormpep,
	   "brigpep"     => \$brigpep,
	   'remapep'     => \$remapep,
	   "databases"   => \$update_databases,
	   "updatemysql" => \$update_mySQL,
	   "setup"       => \$setup_mySQL,
	   "run"         => \$run_pipeline,
	   "run_brig"    => \$run_brig,
	   "nosql"       => \$dont_SQL,
	   "prep_dump"   => \$prep_dump,
	   "dump"        => \$dump_data,
	   "distribute"  => \$distribute,
	   "testpipe"    => \$test_pipeline,
	   "version=s"   => \$WS_version,
	   "blastp"      => \$blastp,
	   "blastx"      => \$blastx,
	   "cleanup"     => \$cleanup,
	   "debug=s"     => \$debug,
	   "test"        => \$test,
	   "store:s"     => \$store
	  );

my $wormbase;
my $farm=$update_mySQL?0:1;

if ( $store ) {
  $wormbase = retrieve( $store ) or croak("Can't restore wormbase from $store\n");
} else {
  $wormbase = Wormbase->new( 'debug'   => $debug,
                             'test'    => $test,
			     'farm'    => $farm,
			     'version' => $WS_version,
			     );
}

my $log;
if (! $cleanup) {
  # establish log file. Can't do this if the BUILD/autoace directory has been moved to DATABASES
  $log = Log_files->make_build_log($wormbase);
}

# you can do either or both blast anaylses
if( $run_pipeline ) {
  $blastx = 1; $blastp =1;
}

$WS_version = $wormbase->get_wormbase_version;
my $WS_old = $WS_version - 1;
my $scripts_dir = $ENV{'CVS_DIR'};
#process Ids

#|         18 | gadfly3.pep         |
#|         19 | ensembl7.29a.2.pep  |
#|         20 | yeast2.pep          |
#|         23 | wormpep87.pep       |
#|         24 | slimswissprot40.pep |
#|         25 | slimtrembl21.pep    |

my %worm_dna_processIDs = ( 
			wormpep       => 2,
			brigpep       => 3,
			ipi_human     => 4,
			yeast         => 5,
			gadfly        => 6,
			slimswissprot => 7,
			slimtrembl    => 8,
			remapep       => 15,
		       );


# ??? should remanei => 15 be added to this list ???
my %wormprotprocessIds = ( 
			  wormpep       => 2,
			  brigpep       => 3,
			  ipi_human     => 4,
			  yeast         => 5,
			  gadfly        => 6,
			  slimswissprot => 7,
			  slimtrembl    => 8,
			  remapep       => 15,
			 );

#get new chromosomes
$wormbase->run_command("perl ~/wormbase/scripts/BLAST_scripts/copy_files_to_acari.pl -chrom", $log) if ($chromosomes);


#get new wormpep
$wormbase->run_command("perl ~/wormbase/scripts/BLAST_scripts/copy_files_to_acari.pl -wormpep", $log) if ($wormpep);
$wormbase->run_command("perl ~/wormbase/scripts/BLAST_scripts/copy_files_to_acari.pl -brigpep", $log) if ($brigpep);
$wormbase->run_command("perl ~/wormbase/scripts/BLAST_scripts/copy_files_to_acari.pl -remapep", $log) if ($remapep);


my %currentDBs;   #ALSO used in setup_mySQL 
my @updated_DBs;  #used by get_updated_database_list sub - when run this array is filled with databases that have been updated since the prev build
#load in databases used in previous build
my $last_build_DBs = "$wormpipe_dir/BlastDB/databases_used_WS$WS_old";
my $database_to_use = "$wormpipe_dir/BlastDB/databases_used_WS$WS_version";

unless ($cleanup) {
open (OLD_DB,"<$last_build_DBs") or die "cant find $last_build_DBs";
while (<OLD_DB>) {
  chomp;
  if( /(gadfly|yeast|slimswissprot|slimtrembl|wormpep|ipi_human|brigpep|remapep)/ ) {
    $currentDBs{$1} = $_;
  }
}
close OLD_DB;
		 }

#check for updated Databases
if ( $update_databases ){
  print "Updating databases \n";
  open (DIR,"ls -l $wormpipe_dir/BlastDB/*.pep |") or die "readir\n";
  while (<DIR>) { 
    #  print;
    chomp;
    if( /\/(gadfly|yeast|slimswissprot|slimtrembl|wormpep|ipi_human|brigpep|remapep)/ ) {
      my $whole_file = "$1"."$'";  #match + stuff after match.
      if( $1 eq "wormpep" ) {
	print "updating wormpep to version $WS_version anyway - make sure the data is there !\n";
	$whole_file = "wormpep".$WS_version.".pep";
	$currentDBs{$1} = "$whole_file";
	$wormbase->run_command("/usr/local/ensembl/bin/xdformat -p $wormpipe_dir/BlastDB/$whole_file", $log);
	next;
      }
      if( "$whole_file" ne "$currentDBs{$1}" ) {
	#make blastable database
	print "\tmaking blastable database for $1\n";
	$wormbase->run_command("/usr/local/ensembl/bin/xdformat -p $wormpipe_dir/BlastDB/$whole_file", $log);
	push( @updated_DBs,$1 );
	#change hash entry ready to rewrite external_dbs
	$currentDBs{$1} = "$whole_file";
      }
      else {
	print "\t$1 database unchanged $whole_file\n";
      }
    }
  }
  close DIR;
  
  open (NEW_DB,">$database_to_use") or die "cant write updated $database_to_use";
  foreach (keys %currentDBs){
    print NEW_DB "$currentDBs{$_}\n";
  }
  close NEW_DB;
}



#@updated_DBs = qw(ensembl gadfly yeast slimswissprot slimtrembl);
if( $distribute) {
    my $blastdbdir="/data/blastdb/Worms";
    &get_updated_database_list;
    
    # delete updated databases from /data/blastdb/Worms
    foreach (@updated_DBs){
      $log->write_to("deleting blastdbdir/$_*\n");
      (unlink glob "$blastdbdir/$_*") or $log->write_to("WARNING: cannot delete $blastdbdir/$_*\n");
    }
    $log->write_to("deleting $blastdbdir/CHROMOSOME_*.dna\n");
    (unlink glob "$blastdbdir/CHROMOSOME_*.dna") or $log->write_to("WARNING: cannot delete $blastdbdir/CHROMOSOME_*.dna\n");
  
    # copy blastdbs
    foreach (@updated_DBs){
      foreach my $file_name( glob "$wormpipe_dir/BlastDB/$currentDBs{$_}*") {
	      $log->write_to("copying $file_name to $blastdbdir/\n");
	      copy("$file_name","$blastdbdir/") or $log->write_to("ERROR: cannot copy $file_name\n") ;
      }
    }

    # copy chromosomes    
    foreach my $chr ($wormbase->get_chromosome_names('-prefix' => 1,)){
	    my $file_name="$wormpipe_dir/BlastDB/$chr.dna";
	      $log->write_to("copying $file_name to $blastdbdir/");
	      copy($file_name,"$blastdbdir/") or $log->write_to("cannot copy $file_name\n") ;
    }
}



# mysql database parameters
my $dbhost = "ia64b";
my $dbuser = "wormadmin";
my $dbname = "worm_dna";
my $dbpass = "worms";

my @results;
my $query = "";
my $worm_dna;     #worm_dna Db handle
my $worm_pep;   #wormprot Db handle

# update mySQL database
if( $update_mySQL )
  {
    print "Updating mysql databases with new clone and protein info\n";
    $log->write_to("Updating mysql databases\n-=-=-=-=-=-=-=-=-=-=-\n");
    #make worm_dna connection
    $worm_dna = DBI -> connect("DBI:mysql:$dbname:$dbhost", $dbuser, $dbpass, {RaiseError => 1})
      || die "cannot connect to db, $DBI::errstr";
    
    #internal_id number of the last clone in the worm_dna
    #in case this routine is being run twice the clone id is stored and checked
    my $last_clone;
    my $update;
    open (NEW_DB,"<$database_to_use") or die "cant read updated $database_to_use during update_mySQL";
    
    #this bits logic seems wrong - but it works so I'll fix it later - ar2
    while(<NEW_DB>){
      if( /last_clone\s(\w+)/ ){
	$last_clone = $1;
	last;
      }
      else {
	$query = "select * from clone order by clone_id desc limit 1";
	@results = &single_line_query( $query, $worm_dna );
	$last_clone = $results[0];
	$update = 1;
      }
    }
    close NEW_DB;
    
    if( $update ){   # first time writing for this build
      open (NEW_DB,">>$database_to_use") or die "cant read updated $database_to_use during update_mySQL - last_clone";
      print NEW_DB "last_clone $last_clone\n";
    }
    print "last_clone = $last_clone\n";
    
    #Make a concatenation of all six agp files from the last release to ~/Elegans  e.g.
    print "\tconcatenating agp files\n";
    $log->write_to("concatenating agp files\n");
    # this is a bit iffy as ->autoace is somewhere else :-(
    $wormbase->run_command("cat ". $wormbase->autoace."/CHROMOSOMES/*.agp > $wormpipe_dir/Elegans/WS$WS_version.agp", $log);
    
    #load information about any new clones
    print "\tloading information about any new clones in to $dbname\n";
    $wormbase->run_script("BLAST_scripts/agp2ensembl.pl -dbname worm_dna -dbhost ia64b -dbuser wormadmin -dbpass worms -agp $wormpipe_dir/Elegans/WS$WS_version.agp -write -v -strict -fasta ".$wormbase->autoace."/allcmid", $log);
    
    #check that the number of clones in the clone table equals the number of contigs and dna objects
    my ($clone_count, $contig_count, $dna_count);
    $query = "select count(*) from clone";
    @results = &single_line_query( $query, $worm_dna );
    $clone_count = $results[0];
    
    $query = "select count(*) from contig";
    @results = &single_line_query( $query, $worm_dna );
    $contig_count = $results[0];
    
    $query = "select count(*) from dna";
    @results = &single_line_query( $query, $worm_dna );
    $dna_count = $results[0];

    print "checking clone contig and dna counts . . .";
    if( ($clone_count != $contig_count) or ($contig_count != $dna_count ) ){
	$log->log_and_die("\nthe number of clones, contigs and DNAs is inconsistant\nclones = $clone_count\ncontigs = $contig_count\ndna = $dna_count\n");
    }
    else {
      print "OK\n";
    }

    $query = "select * from clone order by clone_id desc limit 1";
    @results = &single_line_query( $query, $worm_dna );
    my $new_last_clone = $results[0];
    print "\tnew_last_clone = $new_last_clone\n";

    $worm_dna->disconnect;

    # shouldn't be needed anymore but Im leaving it for extra safety - ar2
    print "\tchecking for duplicate clones\n";
    $wormbase->run_script("BLAST_scripts/find_duplicate_clones.pl", $log);

    #add new peptides to MySQL database
    print "\n\nAdding new peptides to $dbname\n";
    $log->write_to("adding new proteins to $dbname\n");
    #make protein database connection
    $dbname = "worm_pep";
    $worm_pep = DBI -> connect("DBI:mysql:$dbname:$dbhost", $dbuser, $dbpass, {RaiseError => 1})
      || die "cannot connect to db, $DBI::errstr";

    $query = "select * from protein order by proteinId desc limit 1";
    @results = &single_line_query( $query, $worm_pep );
    my $old_topCE = $results[0];
    if (-e $wormbase->wormpep."/new_entries.WS$WS_version"){
      $wormbase->run_script("BLAST_scripts/worm_pipeline.pl -fasta ".$wormbase->wormpep."/new_entries.WS$WS_version");
    }
    else {
      $log->log_and_die("new_entries.WS$WS_version does not exist! \nThis should have been made in autoace_minder -buildpep\n");
    }
    
	 $wormbase->run_script("BLAST_scripts/worm_pipeline.pl -fasta $wormpipe_dir/BlastDB/brigpep${WS_version}.pep -brig");    

    #check for updated ids
    @results = &single_line_query( $query, $worm_pep );
    my $new_topCE = $results[0];
    if( "$old_topCE" eq "$new_topCE" ) {
      $log->write_to("\tNO new peptides were added to the $dbname mysql database\n");
    }
    else {
      $log->write_to("\tnew highest proteinId is $new_topCE (old was $old_topCE )\n");
    }

    $worm_pep->disconnect;
  }


# username and password needed to talk/write to MySQL database
$dbuser = "wormadmin";
$dbpass = "worms";


#####################################################################################################
#
# Subroutine to prepare the tables for analysis, i.e. delete previous analyses that have been run
# for databases that will be updated
#
#####################################################################################################

if($setup_mySQL){  
  print "Setting up mysql ready for Blast run\n";
  #make wormprot connection
  $dbname = "worm_pep";
  my $worm_pep =  DBI -> connect("DBI:mysql:$dbname:$dbhost", $dbuser, $dbpass, {RaiseError => 1})
      || die "cannot connect to db, $DBI::errstr";
  
  #make worm_brigprot connection
  $dbname = "worm_brigpep";
  my $worm_brigpep =  DBI -> connect("DBI:mysql:$dbname:$dbhost", $dbuser, $dbpass, {RaiseError => 1})
      || die "cannot connect to db, $DBI::errstr";
  
  #make worm_dna connection
  $dbname = "worm_dna";
  $worm_dna = DBI -> connect("DBI:mysql:$dbname:$dbhost", $dbuser, $dbpass, {RaiseError => 1})
      || die "cannot connect to db, $DBI::errstr";
  
  &get_updated_database_list;
  
  # if the user passes WPversion greater than that in the current file update it anyway
  # (this means you can update the database before wormpep is made - ie during autoace_minder -build
  $currentDBs{$1} =~ /wormpep(\d+)/;
  if( $1 and ( $1<$WS_version ) ) {
    push (@updated_DBs,"wormpep$WS_version\.pep");
  }
  
  # update mysql with which databases need to be run against
  foreach my $database (@updated_DBs){
    my $analysis = $worm_dna_processIDs{$database};
    my $db_file = $currentDBs{$database};
    print "________________________________________________________________________________\n";
    
      
    ####################
    # DNA analysis
    ####################
    
    print "Starting worm_dna updates . . . \n";
    $query = "update analysis set db = \"$db_file\" where analysis_id = $analysis";
    print $query,"\n";
    &update_database( $query, $worm_dna );
    
    $query = "update analysis set db_file = \"/data/blastdb/Worms/$db_file\" where analysis_id = $analysis";
    print $query,"\n";
    &update_database( $query, $worm_dna );
      
    # LOCKing the tables should considerably increase the DELETE speed
    my $lock_statement = "LOCK TABLES input_id_analysis WRITE, dna_align_feature WRITE;";
    print "Locking DNA tables: $lock_statement\n";
    &update_database("$lock_statement", $worm_dna);
      
    #delete entries so they get rerun
    $query = "delete from input_id_analysis where analysis_id = $analysis";
    print $query,"\n";
    &update_database( $query, $worm_dna );
    
    $query = "delete from dna_align_feature where analysis_id = $analysis";
    print $query,"\n";
    &update_database( $query, $worm_dna );
    
    #release WRITE LOCKS
    print "Unlocking DNA tables\n\n";
    &update_database("UNLOCK TABLES;", $worm_dna);
    
    
    ####################
    # Protein analysis
    ####################
    
    print "Starting worm_pep and worm_brigpep updates . . . \n";
    $analysis = $wormprotprocessIds{$database};
    $query = "update analysis set db = \"$db_file\" where analysis_id = $analysis";
    print $query,"\n";	
    &update_database( $query, $worm_pep );
    &update_database( $query, $worm_brigpep );
    
    $query = "update analysis set db_file = \"/data/blastdb/Worms/$db_file\" where analysis_id = $analysis";
    print $query,"\n";
    &update_database( $query, $worm_pep );
    &update_database( $query, $worm_brigpep );
    
    # lock protein tables 
    $lock_statement = "LOCK TABLES input_id_analysis WRITE, protein_feature WRITE;";
    print "Locking protein tables: $lock_statement\n";
    &update_database("$lock_statement", $worm_pep);
    &update_database("$lock_statement", $worm_brigpep);
    
    #delete entries so they get rerun
    $query = "delete from input_id_analysis where analysis_id = $analysis";
    print $query,"\n";
    &update_database( $query, $worm_pep );
    &update_database( $query, $worm_brigpep );
    
    $query = "delete from protein_feature where analysis_id = $analysis";
    print $query,"\n";
    &update_database( $query, $worm_pep );
    &update_database( $query, $worm_brigpep );
    
    # release WRITE locks
    &update_database("UNLOCK TABLES;", $worm_brigpep);
    &update_database("UNLOCK TABLES;", $worm_pep);
  }

  #####################################################################################################
  #
  # check whether the InterPro databases have been updated in the last 3 weeks - if so we need
  # to delete previous analyses that have been run.
  #
  #####################################################################################################

  my $interpro_dir = "/data/blastdb/Ensembl/interpro_scan/";
  my $interpro_date;
  my $last_build_date = -M $last_build_DBs;
  if (-e $interpro_dir ) {
    $interpro_date = -M $interpro_dir;
  } else {
    print "Can't find the InterPro database directory: $interpro_dir\n";
    $interpro_date = 1000;	# assume it has not changed, so make it 1000 days since last update
  }

  # see if the InterPro databases' directory has had stuff put in it since the last build
  if ($interpro_date < $last_build_date) {
    print "Starting worm_pep and worm_brigpep InterPro updates . . . \n";

    # The analysis numbers for the InterPro databases are:
    # 11 Pfam
    # 16 Prints
    # 17 Profile
    # 18 pirsf
    # 19 TIGR
    # 20 Smart
    # 21 Prosite
    foreach my $analysis (11, 16 ..21) {

      # lock protein tables 
      my $lock_statement = "LOCK TABLES input_id_analysis WRITE, protein_feature WRITE;";
      print "Locking protein tables: $lock_statement\n";
      &update_database("$lock_statement", $worm_pep);
      &update_database("$lock_statement", $worm_brigpep);
      
      #delete entries so they get rerun
      $query = "delete from input_id_analysis where analysis_id = $analysis";
      print $query,"\n";
      &update_database( $query, $worm_pep );
      &update_database( $query, $worm_brigpep );
      
      $query = "delete from protein_feature where analysis_id = $analysis";
      print $query,"\n";
      &update_database( $query, $worm_pep );
      &update_database( $query, $worm_brigpep );
      
      # release WRITE locks
      &update_database("UNLOCK TABLES;", $worm_brigpep);
      &update_database("UNLOCK TABLES;", $worm_pep);
    }
  }


  $worm_dna->disconnect;
  $worm_pep->disconnect;
  $worm_brigpep->disconnect;

  print "\nFinished setting up MySQL databases\n\n";
}

#####################################################################################################


my $bdir = "/nfs/farm/Worms/Ensembl/ensembl-pipeline/modules/Bio/EnsEMBL/Pipeline";

if( $blastx ) {
   &run_RuleManager('worm_dna','dna');
}

if( $blastp ){
  &run_RuleManager('worm_pep','pep');
  &run_RuleManager('worm_brigpep','pep');
}



if( $prep_dump ) {
  # prepare helper files
  my $autoace = $wormbase->autoace;
  my $wormpep = $wormbase->wormpep;
  if( -e $wormbase->gff_splits."/CHROMOSOME_X_curated.gff") {
    $wormbase->run_command("cat ".$wormbase->gff_splits."/CHROMOSOME_*_curated.gff | $scripts_dir/BLAST_scripts/gff2cds.pl > $wormpipe_dir/Elegans/cds$WS_version.gff", $log);
    $wormbase->run_command("cat ".$wormbase->gff_splits."/CHROMOSOME_*_Genomic_canonical.gff   | $scripts_dir/BLAST_scripts/gff2cos.pl > $wormpipe_dir/Elegans/cos$WS_version.gff",$log);
    
    system("touch $wormpipe_dir/DUMP_PREP_RUN");
  }
    else {
      print " cant find GFF files at ".$wormbase->gff_splits."\n ";
      exit(1);
    }
  }

if( $dump_data )
  {
    $log->log_and_die("The -dump option is not in use\n\n");
    unless ( -e "$wormpipe_dir/DUMP_PREP_RUN" ) {
      print "Please run wormBLAST.pl -prep_dump version $WS_version    before dumping\n\n";
      exit(0);
    }

    # need this to dump new databases in full
    &get_updated_database_list;
    my $anal_list = join(',',@updated_DBs);

   #blastp dumped external of this script;
    # dump blastx
    print "Dumping blastx for analysis $anal_list\n";
    $wormbase->run_script("dump_blastx_new.pl -version $WS_version -analysis $anal_list", $log);

    # dump motifs for elegans and brig
    print "Dumping motifs\n";
    $wormbase->run_script("BLAST_scripts/dump_motif.pl" ,$log );
    $wormbase->run_script("BLAST_scripts/dump_motif.pl -database worm_brigpep" ,$log );
    $wormbase->run_script("BLAST_scripts/dump_interpro_motif.pl" ,$log );
    $wormbase->run_script("BLAST_scripts/dump_interpro_motif.pl -database worm_brigpep" ,$log );

    # Dump extra info for SWALL proteins that have matches. Info retrieved from the dbm databases on /lustre/work1/ensembl/wormpipe/
    print "Creating acefile of SWALL proteins with homologies\n";
    $wormbase->run_script("BLAST_scripts/write.swiss_trembl.pl -swiss -trembl" ,$log );

    print "Creating acefile of matched IPI proteins\n";
    $wormbase->run_script("BLAST_scripts/write_ipi_info.pl" ,$log );
  }


if( $cleanup ) {
  print "clearing up files generated in this build\n";
# files to move to ~wormpub/last-build/
#   /lustre/work1/ensembl/wormpipe/dumps/
#    ipi_hits_list
#    trembllist.txt
#    swisslist.txt
#    best_blastp_hits
#    best_blastp_hits_brigprot

#  ~wormpipe/Elegans
#    WS99.agp
#    cds99.gff
#    cos99.gff
#    ids.txt

# to delete
#   /lustre/work1/ensembl/wormpipe/dumps/
#      *.ace
#      *.log
  my $clear_dump = "$wormpipe_dir/dumps";
  print "Removing . . . \n";
  print "\t$clear_dump/*.ace\n";  system("rm -f $clear_dump/*.ace") && warn "cant remove ace files from $clear_dump";
  print "\t$clear_dump/*.log\n";  system("rm -f $clear_dump/*.log") && warn "cant remove log files from $clear_dump";

  print "Removing files currently in $wormpipe_dir/last_build/n";
  system(" rm -f $wormpipe_dir/last_build/*.gff");
  system(" rm -f $wormpipe_dir/last_build/*.agp");

  print "\nmoving the following to ~wormpipe/last_build . . \n";
  print "\t$clear_dump/*.txt\n"; system("mv -f $clear_dump/*.txt $wormpipe_dir/last_build/") && warn "cant move $clear_dump/*.txt\n";
  print "\t$clear_dump/ipi*\n"; system("mv -f $clear_dump/ipi* $wormpipe_dir/last_build/") && warn "cant move $clear_dump/ipi*\n";
  print "\t$clear_dump/best_blastp\n"; system("mv -f $clear_dump/best_blastp* $wormpipe_dir/last_build/") && warn "cant move $clear_dump/best_blast*\n";
  print "\t$wormpipe_dir/Elegans/*\n"; system("mv -f $wormpipe_dir/Elegans/* $wormpipe_dir/last_build/") && warn "cant move $wormpipe_dir/Elegans/*\n";

  print "\nRemoving the $wormpipe_dir/DUMP_PREP_RUN lock file\n"; system("rm -f $wormpipe_dir/DUMP_PREP_RUN") && warn "cant remove $wormpipe_dir/DUMP_PREP_RUN\n";

  print "\nRemoving farm output and error files from /lustre/scratch1/ensembl/wormpipe/*\n"; 

  my $scratch_dir = "/lustre/scratch1/ensembl/wormpipe";
  my @directories = qw( 0 1 2 3 4 5 6 7 8 9 );

  foreach my $directory ( @directories ) {
    rmtree("$scratch_dir/$directory", 1, 1); # this will remove the directory as well
    mkdir("$scratch_dir/$directory");        # so remake it 
    system("chgrp worm $scratch_dir/$directory");  # and make it writable by 'worm'
  }
  print "\n\nCLEAN UP COMPLETED\n\n";
  exit(0);
}


&wait_for_pipeline_to_finish if $test_pipeline; # debug stuff
$log->mail;


exit(0);



###############################################################################################
#
#
#                          T  H  E     S  U  B  R  O  U  T  I  N  E  S
#
#
#
################################################################################################


sub wait_for_pipeline_to_finish
  {
    my $finished = 0;
    while( $finished == 0 ) {
      my $jobsleft = `cjobs`;
      chomp $jobsleft;
      if( $jobsleft == 0 ){
	$finished = 1;
	print "pipeline finished\n" ;
      }
      else {
	print "$jobsleft jobsleft (Im going to sleep for that long! )\n";
	
	sleep $jobsleft;
      }
    }
    print "Pipeline finished - waiting 60 secs to make sure everything is through\n";
    sleep 60;
    print "DONE\n\n";
    return;
  }



sub update_database
  {
    if( $dont_SQL ){
      return;
    }
    else{
      my $query = shift;
      my $db = shift;
      my $sth = $db->prepare( "$query" );
      $sth->execute();
      return;
    }
  }

sub single_line_query
  {
    if( $dont_SQL ){
      my @bogus = qw(3 3 3 3 3 3);
      return @bogus;
    }
    else{
      my $query = shift;
      my $db = shift;
      my $sth = $db->prepare( "$query" );
      $sth->execute();
      my @results = $sth->fetchrow_array();
      $sth->finish();
      return @results;
    }
  }


sub get_updated_database_list
  {
    @updated_DBs = ();
    #process new databases
    open (OLD_DB,"<$last_build_DBs") or die "cant find $last_build_DBs";
    my %prevDBs;
   # my %currentDBs;
    
    #get database file info from databases_used_WS(xx-1) (should have been updated by script if databases changed
    while (<OLD_DB>) {
      chomp;
      if( /(ensembl|gadfly|yeast|slimswissprot|slimtrembl|wormpep|ipi_human|brigpep)/ ) {
	$prevDBs{$1} = $_;
      }
    }  
    open (CURR_DB,"<$database_to_use") or die "cant find $database_to_use";
    while (<CURR_DB>) {
      chomp;
      if( /(ensembl|gadfly|yeast|slimswissprot|slimtrembl|wormpep|ipi_human|brigpep)/ ) {
	$currentDBs{$1} = $_;
      }
    }
    close CURR_DB;
    
    #compare old and new database list
    foreach (keys %currentDBs){
      if( "$currentDBs{$_}" ne "$prevDBs{$_}" ){
	push( @updated_DBs, "$_");
      }
    }
  }



sub run_RuleManager
  {
    my ($dbname, $moltype ) = @_;
    my $script;
    $script = "$bdir/RuleManager3.pl" if $moltype eq "dna";
    $script = "$bdir/RuleManager3Prot.pl" if $moltype eq "pep";

    die "invalid or no moltype passed to run_RuleManager : $moltype\n" unless $script;
    $wormbase->run_command("perl $script -dbhost $dbhost -dbname $dbname -dbpass $dbpass -dbuser $dbuser", $log);

  }

__END__
  
=pod

  
=head2 NAME - wormBLAST.pl

=head1 USAGE
  
=over 4
 
=item wormBLAST.pl [-chromosomes -wormpep -databases -datemysql -setup -run -nosql -dump -distribute]
  
=back
  
This script:
  
I<wormBLAST.pl MANDATORY arguments:>

B<NONE>

I<wormBLAST.pl  Overview:>

This script is a collection of subroutines that automate the BLAST part of the Wormbase build process.  It keeps track of which databases are being used in the files ~wormpipe/BlastDB/databases_used_WSXX and databases_used_WSXX-1.


I<wormBLAST.pl  OPTIONAL arguments:>

B<-chromosomes> Runs ~wormpipe/Pipeline/copy_files_to_acari.pl -c to copy the newly formed chromosomes from the build and cats them in to one

B<-wormpep>      Runs ~wormpipe/Pipeline/copy_files_to_acari.pl -c to take the new wormpepXX file from WORMPEP and creates a BLASTable database (setdb)

B<-databases>    Checks existing database files (slimtremblXX.pep etc) against what was used last time and updates them.  It takes the new .pep file and runs setdb.  Modifies the databases_used_WSXX file to reflect changes.  This will ensure that the update propegates to the remainder of the process.

B<-distribute>   Distribute new databases over the farm.  Compares the database files used in this and the previous build to tell system which files to remove and what to replace them with.

B<-updatemysql>    Updates any new databases to be used in MySQL.  

B<-setup>          Prepares MySQL for the pipeline run.  Performs the 'delete' commands so that new data is included in the run

B<-run>            Actually starts the BLAST analyses.  Does a single analysis at a time based on what new databases are being used, plus a couple of "do everything runs" to finish it all off.
The BLAST pipeline is limited so that we can only have one RuleManager running at a time.  These means that even if all the balstx jobs have been submitted we cant start the blastp run until they have all gone through.  Therefore the script allows the running of these separately by using the -blastx and -blastp options.  Both can be entered together (same as -run).  If this is done the script will monitor the progress of the blastx jobs (done 1st) and only start the blastp run when this has finished.

B<-blastx>      Submits blastx jobs based on updated databases

B<-blastp>      Submits blastp jobs based on updated databases

B<-dump>        Dumps data from MySQL after anaylsis is complete.

B<-nosql>       Debug option where SQL calls to databases are not performed. 

=back

=over 4

=head1 REQUIREMENTS

=over 4

=back

=head1 AUTHOR

=over 4

=item Anthony Rogers (ar2@sanger.ac.uk)

=back

=cut
