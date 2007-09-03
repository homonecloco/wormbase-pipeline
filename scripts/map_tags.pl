#!/software/bin/perl -w
#!/nfs/disk100/wormpub/bin/perl -w

####################################################################################################################################
#
# This script maps SAGE tags to conceptual transcriptome and genome. Tags are mapped to the sense strand of the transcriptome 
# at first. If this does not succeed, tags are mapped to the antisense strand of transcriptome and the genome. Transcriptome-
# mapped tags are connected to apropriate transcripts and genes. The type of mapping is recorded using the Method field
# in Homol_data. Cumulative frequency of each tag over all libraries is calculated and included in Homol_data as a score.
#
# Requires: acedb, transcriptome generated by
# get_sequences_acedb_mysql.pl, chromosomes in fasta format
#
####################################################################################################################################

# ./map_tags.pl -output map_tags.out

use strict;
use lib $ENV{'CVS_DIR'};
use Wormbase;
use Log_files;
use Storable;
use Ace;
use Sequence_extract;
use Coords_converter;
use Getopt::Long;
#use LSF RaiseError => 0, PrintError => 1, PrintOutput => 0;
#use LSF::JobManager;


my ( $help, $debug, $test, $store );
my $verbose;    # for toggling extra output
my $load;

##############################
# command-line options       #
##############################

GetOptions(
    "help"      => \$help,
    "debug=s"   => \$debug,
    "test"      => \$test,
    "store:s"   => \$store,
    "load"      => \$load,
);

# Display help if required
&usage("Help") if ($help);

my $wormbase;
my $flags = "";
if ($store) {
    $wormbase = Storable::retrieve($store) or croak("Can't restore wormbase from $store\n");
    $flags = "-store $store";
}
else {
    $wormbase = Wormbase->new( -debug => $debug, -test => $test );
    $flags .= "-debug $debug " if $debug;
    $flags .= "-test "         if $test;
}

$debug = $wormbase->debug if $wormbase->debug;    # Debug mode, output only goes to one user

my $log = Log_files->make_build_log($wormbase);

###########################################################################
#
# run the get_sequences.pl script to create the files of transcript details
#
###########################################################################

#my $m = LSF::JobManager->new();

my @chroms = $wormbase->get_chromosome_names(-mito => 1, -prefix => 1);

foreach my $chrom ( @chroms ) {
#  my $mother = $m->submit("$ENV{'CVS_DIR'}/get_sequences_gff.pl -chromosome $chrom $flags");
  $wormbase->run_script("get_sequences_gff.pl -chromosome $chrom", $log);
}

#$m->wait_all_children( history => 1 );
print "All get_sequences_gff.pl children have completed!\n";

#foreach my $job ( $m->jobs ) {    # much quicker if history is pre-cached
#  $log->log_and_die("$job exited non zero\n") if $job->history->exit_status != 0;
#}

#$m->clear;                    # clear out the job manager


###########################################################################


$|=1;

my $map_to_genome='y';
print "tags will be mapped to genome in addition to transcriptome\n";


my $currentdb = $wormbase->database('current');	# use autoace when debugged 
my $ace_dir = $wormbase->autoace;     # AUTOACE DATABASE DIR
#my $database_path = $currentdb;     # full path to local AceDB database; change as appropriate
my $database_path = $ace_dir;     # full path to local AceDB database; change as appropriate
my $program = $wormbase->tace;  # full path to tace; change as appropriate
my $output = $wormbase->acefiles."/map_tags.ace"; # output file path

print "connecting to server...";
my $db = Ace->connect(-path => $database_path,  -program => $program) || die print "Connection failure: ", Ace->error;  # local database
print "done\n";
my $coords = Coords_converter->invoke($database_path, 0, $wormbase);
my %clonesize = $wormbase->FetchData('clonesize');


open OUT, ">$output" || die "cannot open $output : $!\n";


my %tags=();
my ($tagid, $tagseq, $tagfreq);

# get all SAGE_tag objects and show them
#
# reading directly from tace takes 5 mins longer than reading the data
# from a file of the keyset dumped out from tace, but is much more
# convenient.
my $sage_query="find SAGE_tag\nshow -a\nquit";

my $tace = $wormbase->tace;        # TACE PATH

open (TACE, "echo '$sage_query' | $tace $database_path |");
while (<TACE>) {
  chomp;
  next if (/acedb\>/);
  next if (/\/\//);

  chomp;
  next unless $_;
  if (/^SAGE_tag/) {		# store the cumulative results from the previous SAGE_tag
    if ($tagid) {
      $tags{$tagid}{seq}=$tagseq;
      $tags{$tagid}{freq}=$tagfreq;
      $tagfreq=0;
    }
    $tagid=$_=~/(SAGE:[agctAGCT]+)/ ? $1 : ''; # get the ID for this SAGE_tag
    if (!$tagid) {
      print "cannot parse tag name: $_\n";
      exit;
    }
  }
  elsif (/^Tag_sequence/) {
    $tagseq=$_=~/\"([agctAGCT]+)\"/ ? $1 : '';
    if (!$tagseq) {
      print "cannot parse tag sequence: $_\n";
      exit;
    }
  }
  elsif (/Frequency/) {
    my $tmp=$_=~/Frequency\s+([\d\.]+)/ ? $1 : '';
    if (!$tmp) {
      print "cannot parse tag frequency: $_\n";
      exit;
    }
    $tagfreq+=$tmp;
  }
}
close TACE;

if ($tagid) {
    $tags{$tagid}{seq}=$tagseq;
    $tags{$tagid}{freq}=$tagfreq;
}



print scalar keys %tags, " tags read\n";




my %sequences=();
my $seq;
my @tmp=();
foreach my $chrom (@chroms) {
  my $input  = "get_sequences_gff_${chrom}.out";
  open (IN, "<$input") or $log->log_and_die("Cant open $input: !$\n");
  while (<IN>) {          # create a transcriptome hash
    chomp;
    next unless $_;
    s/\"//g;#"
    if (/^>/) {
      if (@tmp) {
	$sequences{$tmp[0]}{type}=$tmp[1]; # transcript type e.g. 'coding transcript'
	$sequences{$tmp[0]}{refseq}=$tmp[2]; # the clone, superlink or chromosome that the transcript is in
	$sequences{$tmp[0]}{refseqlen}=$tmp[3]; # length of clone, superlink or chromosome
	$sequences{$tmp[0]}{UTR}=$tmp[4]; # real or estimated UTR
	$sequences{$tmp[0]}{strand}=$tmp[5]; # strand 1 or -1
	$sequences{$tmp[0]}{start}=$tmp[6]; # transcript start pos
	$sequences{$tmp[0]}{stop}=$tmp[7]; # transcript end pos
	my $start;
	my $len=-1;
#
# read the start & stop positions of the exons of the transcript in this clone/superlink/chromosome
#
	for (my $i=8; $i <= $#tmp; $i++) {
	  push @{$sequences{$tmp[0]}{limits}}, $tmp[$i];
	  if ($i % 2 == 0) {
	    $start=$tmp[$i];
	    $len=$len+1;
	  }
	  else {
	    if ($sequences{$tmp[0]}{strand} == 1) {
	      $len=$len+$tmp[$i]-$start;
	    }
	    else {
	      $len=$len-$tmp[$i]+$start;
	    }
	  }
	  push @{$sequences{$tmp[0]}{rellimits}}, $len;
	}
	$sequences{$tmp[0]}{seq}=$seq;
      }
      @tmp=split '\t';
      $tmp[0]=~s/>//;
      $seq='';
    } else {
      $seq.=$_;          # get the sequence of the transcript including the bounding UTR sequences
    }
  }
  close(IN) or $log->error("Problem closing $input: !$\n");
  unlink($input);

  if (@tmp) {			# duhrr. process the last input line with a duplicate block of code
    $sequences{$tmp[0]}{type}=$tmp[1];
    $sequences{$tmp[0]}{refseq}=$tmp[2];
    $sequences{$tmp[0]}{refseqlen}=$tmp[3];
    $sequences{$tmp[0]}{UTR}=$tmp[4];
    $sequences{$tmp[0]}{strand}=$tmp[5];
    $sequences{$tmp[0]}{start}=$tmp[6];
    $sequences{$tmp[0]}{stop}=$tmp[7];
    my $start;
    my $len=-1;
    for (my $i=8; $i <= $#tmp; $i++) {
      push @{$sequences{$tmp[0]}{limits}}, $tmp[$i];
      if ($i % 2 == 0) {
	$start=$tmp[$i];
	$len=$len+1;
      }
      else {
	if ($sequences{$tmp[0]}{strand} == 1) {
	  $len=$len+$tmp[$i]-$start;
	}
	else {
	  $len=$len-$tmp[$i]+$start;
	}
      }
      push @{$sequences{$tmp[0]}{rellimits}}, $len;
    }
    $sequences{$tmp[0]}{seq}=$seq;
  }
}
print scalar keys %sequences, " transcripts read\n";

#
# read in a file of all of the chromosomal sequences in fasta format
#
my %chrom=();

# read the chromosome files
my @chromosome = qw( I II III IV V X MtDNA);
foreach (@chromosome) {
  $/ = "";
  open (SEQ, "$database_path/CHROMOSOMES/CHROMOSOME_$_.dna") or die "can't open the dna file for $_:$!\n";
  my $seq = <SEQ>;
  close SEQ;
  $/ = "\n";
  $seq =~ s/>CHROMOSOME_\w+//;
  $seq =~ s/\n//g;
  $chrom{$_}=$seq;
}

print scalar keys %chrom, " chromosomes read\n";

# get rev-comp sequence of all chromosomes
my %chromrc=();
print "reverse and complement genomic sequence...";
foreach (keys %chrom) {                     # create a reversed and complemented chromosome hash
    my $seq = reverse $chrom{$_};
    $seq=~tr/agctAGCT/tcgaTCGA/;
    $chromrc{$_}=$seq;
}
print "done\n";

# is it faster to read the GFF files?
print "fetching coding transcripts...\n";   # this takes a while...
my $query="select a, a->Corresponding_CDS->Gene from a in class transcript where exists a->Corresponding_CDS";
my @raws=$db->aql($query);
print scalar @raws, " coding transcripts fetched\n";
my %ct=();
foreach (@raws) {
    $ct{$$_[0]}=$$_[1];
}

print "fetching non-coding transcripts...\n";
$query="select a, a->Gene from a in class transcript where exists a->Gene";
@raws=$db->aql($query);
print scalar @raws, " non-coding transcripts fetched\n";
my %nct=();
foreach (@raws) {
    $nct{$$_[0]}=$$_[1];
}

print "fetching pseudogenes...\n";
$query="select a, a->Gene from a in class pseudogene where exists a->Gene";
@raws=$db->aql($query);
print scalar @raws, " pseudogenes fetched\n";
my %pseudo=();
foreach (@raws) {
    $pseudo{$$_[0]}=$$_[1];
}

$db->close;


#
# get the cut site positions in the transcript sequence of the restriction enzyme
#

my $rs='catg';      # NlaIII restriction site - anchoring enzyme
my %alltags=();
print "digesting transcriptome...\n";         # create all possible tags from transcriptome - both regular (14 nt) and long (21 nt) SAGE
foreach my $tr (keys %sequences) {
  my @tmp=split($rs, $sequences{$tr}{seq}); # would this be faster using index() ?
    my @tmpcuts=$sequences{$tr}{seq}=~/($rs)/g;
    my $cuts=scalar @tmpcuts;
    my $j=0;
    my $pos=0;
    # if split matches at the beginning of the string, it puts an empty element in the array first
    foreach (@tmp) {
       	$pos+=length $_;
	last if ($pos == length $sequences{$tr}{seq});
	my $tag14=substr($sequences{$tr}{seq}, $pos, 14);
	my $tag21=substr($sequences{$tr}{seq}, $pos, 21);
	if (length $tag14 == 14) { # i.e cut sites 14 bases apart and not off the end of the transcript sequence
	    push @{$alltags{$tag14}{$tr}}, $cuts-$j, $pos;
	}
	if (length $tag21 == 21) { # i.e cut sites 21 bases apart and not off the end of the transcript sequence
	    push @{$alltags{$tag21}{$tr}}, $cuts-$j, $pos;
	}
	$pos+=length $rs;
	$j++;
    }
    
	

}
print scalar keys %alltags, " tags generated\n";



my %rc=();
print "reverse and complement transcriptome...";
foreach (keys %sequences) {
    my $seq=lc reverse $sequences{$_}{seq};
    $seq=~tr/agctAGCT/tcgaTCGA/;
    $rc{$_}{seq}=$seq;
    $rc{$_}{type}=$sequences{$_}{type};
    $rc{$_}{refseq}=$sequences{$_}{refseq};
    $rc{$_}{refseqlen}=$sequences{$_}{refseqlen};
    $rc{$_}{UTR}=$sequences{$_}{UTR};
    $rc{$_}{strand}= - $sequences{$_}{strand};
    $rc{$_}{start}=$sequences{$_}{stop};
    $rc{$_}{stop}=$sequences{$_}{start};
    for (my $i=$#{$sequences{$_}{limits}}; $i>=0; $i--) {
	push @{$rc{$_}{limits}}, ${$sequences{$_}{limits}}[$i];
	push @{$rc{$_}{rellimits}}, ${$sequences{$_}{rellimits}}[$#{$sequences{$_}{limits}}] - ${$sequences{$_}{rellimits}}[$i];
    }
}
print "done\n";

my %alltagsrc=();
print "digesting reverse transcriptome...\n";       # create all possible tags from reversed transcriptome - both regular (14 nt) and long (21 nt) SAGE
foreach my $tr (keys %rc) {
    my @tmp=split($rs, $rc{$tr}{seq});
    my @tmpcuts=$rc{$tr}{seq}=~/($rs)/g;
    my $cuts=scalar @tmpcuts;
    my $j=0;
    my $pos=0;
    #if split matches at the beginning of the string, it puts an empty element in the array first
    foreach (@tmp) {
       	$pos+=length $_;
	last if ($pos == length $rc{$tr}{seq});
	my $tag14=substr($rc{$tr}{seq}, $pos, 14);
	my $tag21=substr($rc{$tr}{seq}, $pos, 21);
	if (length $tag14 == 14) {
	    push @{$alltagsrc{$tag14}{$tr}}, $cuts-$j, $pos;
	}
	if (length $tag21 == 21) {
	    push @{$alltagsrc{$tag21}{$tr}}, $cuts-$j, $pos;
	}
	$pos+=length $rs;
	$j++;
    }
    
	

}
print scalar keys %alltagsrc, " tags generated from reverse transcriptome\n";

#
# yes, really - cut the chromosomal sequences up at the restriction sites to look for positions of 14-mers and 21-mer
# is using index() more efficient? and this is done above as well.
#

my %alltagsgenome=();
print "digesting genome...\n";       # create all possible tags from genome - both regular (14 nt) and long (21 nt) SAGE
foreach my $c (keys %chrom) {
    my @tmp=split($rs, $chrom{$c});
    my $pos=0;
    foreach (@tmp) {
       	$pos+=length $_;
	last if ($pos == length $chrom{$c});
	my $tag14=substr($chrom{$c}, $pos, 14);
	my $tag21=substr($chrom{$c}, $pos, 21);
	if (length $tag14 == 14) {
	    push @{$alltagsgenome{$tag14}{$c}{plus}}, $pos;
	}
	if (length $tag21 == 21) {
	    push @{$alltagsgenome{$tag21}{$c}{plus}}, $pos;
	}
	$pos+=length $rs;
    }
}
foreach my $c (keys %chromrc) {
    my @tmp=split($rs, $chromrc{$c});
    my $pos=0;
    foreach (@tmp) {
       	$pos+=length $_;
	last if ($pos == length $chromrc{$c});
	my $tag14=substr($chromrc{$c}, $pos, 14);
	my $tag21=substr($chromrc{$c}, $pos, 21);
	if (length $tag14 == 14) {
	    push @{$alltagsgenome{$tag14}{$c}{minus}}, length ($chromrc{$c}) - $pos;
	}
	if (length $tag21 == 21) {
	    push @{$alltagsgenome{$tag21}{$c}{minus}}, length ($chromrc{$c}) - $pos;
	}
	$pos+=length $rs;
    }
}
%chrom=();
%chromrc=();
print scalar keys %alltagsgenome, " tags generated from genome\n";





my %homol=();
my $i=0;
my $mapped_to_transcript=0;
my $mapped_to_reverse=0;
my $mapped_to_genome=0;
my %all_mapped=();

foreach my $tag (keys %tags) {          # go through all tags read from tags.ace and map them to transcriptome, reversed transcriptome and genome
    $i++;
    if ($i % 10000 == 0) {
	print "$i tags processed\n";
    }

    print OUT "SAGE_tag : \"$tag\"\n";
    print OUT "-D Homol_homol\n";
    print OUT "-D Most_three_prime\n";
    print OUT "-D Unambiguously_mapped\n";
    print OUT "-D Corresponds_to\n";
    print OUT "-D Remark\n";       
    print OUT "\n";


    my $mapped='';
    my $len=length $tags{$tag}{seq};
    my %mapping=();

    if ($alltags{lc $tags{$tag}{seq}}) {        # first try to map to the sense strand of transcrits
	$mapped='mapped_to_transcript';
	foreach (keys %{$alltags{lc $tags{$tag}{seq}}}) {  
	    my $n=scalar @{$alltags{lc $tags{$tag}{seq}}{$_}} - 1;
	    ${$mapping{$_}}[0]=${$alltags{lc $tags{$tag}{seq}}{$_}}[$n-1];
	    ${$mapping{$_}}[1]=${$alltags{lc $tags{$tag}{seq}}{$_}}[$n];
	}
	
    }

    if ($mapped ne 'mapped_to_transcript') {    # if not mapped to the sense strand, try to map to the antisense strand - apparently happens often due to SAGE experimental procedure
	if ($alltagsrc{lc $tags{$tag}{seq}}) {
	    $mapped='mapped_to_reverse';
	    foreach (keys %{$alltagsrc{lc $tags{$tag}{seq}}}) {                   
		my $n=scalar @{$alltagsrc{lc $tags{$tag}{seq}}{$_}} - 1;
		${$mapping{$_}}[0]=${$alltagsrc{lc $tags{$tag}{seq}}{$_}}[$n-1];
		${$mapping{$_}}[1]=${$alltagsrc{lc $tags{$tag}{seq}}{$_}}[$n];
	    }
	}
    }

    if ($mapped) {
	if ($mapped eq 'mapped_to_transcript') {
	    $mapped_to_transcript++;
	    map_sage_tag($tag, \%tags, \%mapping, \%sequences, \%homol, 'transcript');
	    $all_mapped{$tag}++;
	}
	elsif ($mapped eq 'mapped_to_reverse') {
	    $mapped_to_reverse++;
	    map_sage_tag($tag, \%tags, \%mapping, \%rc, \%homol, 'reverse');
	    $all_mapped{$tag}++;
	}
    }
    
    if ($mapped ne 'mapped_to_transcript' and $map_to_genome eq 'y') {       # map to genome all tags that were not mapped to transcriptome, including ones mapped to antisense strand
	my %genome_mapping=();
	if ($alltagsgenome{lc $tags{$tag}{seq}}) {
	    $mapped_to_genome++;
	    %genome_mapping=%{$alltagsgenome{lc $tags{$tag}{seq}}};
	    map_sage_tag_genome($tag, \%tags, \%genome_mapping, \%homol, 'genome');
	    $all_mapped{$tag}++;
	}
    }
	
}

$log->write_to("$i tags processed\n");
$log->write_to("$mapped_to_transcript tags are mapped to transcripts\n");
$log->write_to("$mapped_to_reverse tags are mapped to antisense strand of transcripts\n");
$log->write_to("$mapped_to_genome tags are mapped to genome\n");
my $final_total = scalar keys %all_mapped;
$log->write_to("$final_total tags mapped total\n");


# Upload file to autoace
if ($load) {
  $wormbase->load_to_database($database_path, $output, "map_tags.pl", $log);
}

# get a clean exit status by closing and undef'ing things
$log->mail();
$wormbase = undef;
$log = undef;
exit(0);

#########################################################
#
# mapping against the chromosome is a command-line option
#

sub map_sage_tag_genome {
    
    my ($tag, $tagsref, $mapref, $homolref, $type) = @_;

    my %chromosomes=(I => "CHROMOSOME_I",
		     II => "CHROMOSOME_II",
		     III => "CHROMOSOME_III",
		     IV => "CHROMOSOME_IV",
		     V => "CHROMOSOME_V",
		     X => "CHROMOSOME_X",
		     MtDNA => "CHROMOSOME_MtDNA");


    my @mapping=();
    my $i=0;
    foreach my $chr (keys %{$mapref}) {
	foreach my $strand (keys %{${$mapref}{$chr}}) {
	    foreach my $pos (@{${${$mapref}{$chr}}{$strand}}) {

		my ($start, $stop);
		if ($strand eq 'plus') {
		    $start=$pos+1;          # on plus strand +1 is needed...
		    $stop=$start + length ($$tagsref{$tag}{seq}) - 1;
		}
		else {
		    $stop=$pos;
		    $start=$pos - length ($$tagsref{$tag}{seq}) + 1;
		}

#
# reading chromosomal superlink and clone ID contained within a region
#
		
                # get enclosing clone/superlink/chromosome details
		if (! defined $chromosomes{$chr}) {print "have undefined value in chrom $chr\n"; print "undef value for tag $tag\n";}
		if (! defined $start) {print "have undefined start for tag $tag\n"}
		if (! defined $stop) {print "have undefined stop for tag $tag\n"}
                my ($refseq, $relstart, $relstop) = $coords->LocateSpan($chromosomes{$chr}, $start, $stop);
		my $refseqlen = &get_clone_len($refseq);


		${$mapping[$i]}{refseq}=$refseq; # name of enclosing clone/superlink/chromosome
		${$mapping[$i]}{refseqlen}=$refseqlen; # length of enclosing clone/superlink/chromosome
		${$mapping[$i]}{start}=$relstart;
		${$mapping[$i]}{stop}=$relstop;
		${$mapping[$i]}{strand}=$strand;
		
		
		if (!${$homolref}{$refseq}) {
		    ${$homolref}{$refseq}='done';
		    print OUT "Sequence : \"$refseq\"\n";
		    print OUT "Homol_data \t\"$refseq:SAGE\"\t1\t$refseqlen\n";
		    print OUT "\n";
		}
		$i++;

	    }
	}
    }

    my $mapping_type;
    if (scalar @mapping == 1) {
	$mapping_type='Unambiguously_mapped';
    }

    print OUT "SAGE_tag : \"$tag\"\n";
    if ($mapping_type) {
    }
    print OUT "\n";

    my $taglen=length ($$tagsref{$tag}{seq});

    foreach my $m (@mapping) {
	my $method="SAGE_tag";
	if ($mapping_type) {
	    $method.="_genomic_unique";
	}

	if ($mapping_type) {    # delete a possible line with SAGE_tag method that may come from mapping to antisense strand of a transcript
	    print OUT "Homol_data\t\"${$m}{refseq}:SAGE\"\n";
	    print OUT "-D SAGE_homol\t\"$tag\"\t\"SAGE_tag\"\t$$tagsref{$tag}{freq}";
	    if (${$m}{strand} eq 'plus') {
		print OUT "\t${$m}{start}\t${$m}{stop}\t1\t$taglen\n";
	    }
	    else {
		print OUT "\t${$m}{stop}\t${$m}{start}\t1\t$taglen\n";
	    }
	    print OUT "\n";
	}
	print OUT "Homol_data\t\"${$m}{refseq}:SAGE\"\n";
	print OUT "SAGE_homol\t\"$tag\"\t\"$method\"\t$$tagsref{$tag}{freq}";
	if (${$m}{strand} eq 'plus') {
	    print OUT "\t${$m}{start}\t${$m}{stop}\t1\t$taglen\n";
	}
	else {
	    print OUT "\t${$m}{stop}\t${$m}{start}\t1\t$taglen\n";
	}
	print OUT "\n";
    }
	
    

    

}


#########################################################
#
#
sub map_sage_tag {
    
    my ($tag, $tagsref, $mapref, $seqref, $homolref, $type) = @_;

    my %genes=();
    my %transcripts=();
    my %nctranscripts=();  # don't need this
    my %pseudogenes=();
    
    my $strand;
    if ($type eq 'transcript') {
	$strand="Sense";
    }
    elsif ($type eq 'reverse') {
	$strand="Antisense";
    }
    
    my %homol_mapping=();
    
    foreach (sort {${$mapref}{$a}[0] <=> ${$mapref}{$b}[0]} keys %{$mapref}) {
	
	if (!${$homolref}{${$seqref}{$_}{refseq}}) {
	    ${$homolref}{${$seqref}{$_}{refseq}}='done';
	    print OUT "Sequence : \"${$seqref}{$_}{refseq}\"\n";
	    print OUT "Homol_data \t\"${$seqref}{$_}{refseq}:SAGE\"\t1\t${$seqref}{$_}{refseqlen}\n";
	    print OUT "\n";
	}
	
	my %exons=();
	my $start=${$mapref}{$_}[1];
	my $stop=${$mapref}{$_}[1] + length($tags{$tag}{seq}) - 1;
	for (my $l=0; $l<=$#{${$seqref}{$_}{rellimits}}; $l++) {
	    if ($l % 2 == 0) {
		$exons{${${$seqref}{$_}{rellimits}}[$l]}{type}='begin';
		$exons{${${$seqref}{$_}{rellimits}}[$l]}{number}=$l;
	    }
	    else {
		$exons{${${$seqref}{$_}{rellimits}}[$l]}{type}='end';
		$exons{${${$seqref}{$_}{rellimits}}[$l]}{number}=$l
		    
		}
	}
	if (!$exons{$start}) {
	    $exons{$start}{type}='start';
	}
	if (!$exons{$stop}) {
	    $exons{$stop}{type}='stop';
	}
	my $c=0;
	my $prev;
	my ($startdiff, $stopdiff);
	my @self=();
	my @gc=();
	foreach my $b (sort {$a <=> $b} keys %exons) {
	    if ($b < $start) {
		$prev=$b;
		next;
	    }
	    elsif ($b == $start) {
		if ($exons{$b}{type} eq 'begin') {
		    $startdiff=0;
		    $prev=$b;
		}
		else {
		    $startdiff=$b-$prev;
		}
		push @self, $b;
		if (${$seqref}{$_}{strand} == 1) {
		    push @gc, ${${$seqref}{$_}{limits}}[$exons{$prev}{number}] + $startdiff;
		}
		else {
		    push @gc, ${${$seqref}{$_}{limits}}[$exons{$prev}{number}] - $startdiff;
		}
		$c++;
		if ($exons{$b}{type} eq 'end') {
		    push @self, $b;
		    if (${$seqref}{$_}{strand} == 1) {
			push @gc, ${${$seqref}{$_}{limits}}[$exons{$prev}{number}] + $startdiff;
		    }
		    else {
			push @gc, ${${$seqref}{$_}{limits}}[$exons{$prev}{number}] - $startdiff;
		    }
		    $c++;
		}
		
	    }
	    elsif ($b < $stop) {
		push @self, $b;
		push @gc, ${${$seqref}{$_}{limits}}[$exons{$b}{number}];
		$c++;
		$prev=$b;
	    }
	    elsif ($b == $stop) {
		if ($exons{$b}{type} eq 'begin') {
		    $stopdiff=0;
		}
		else {
		    $stopdiff=$b-$prev;
		}
		push @self, $b;
		if (${$seqref}{$_}{strand} == 1) {
		    push @gc, ${${$seqref}{$_}{limits}}[$exons{$prev}{number}] + $stopdiff;
		}
		else {
		    push @gc, ${${$seqref}{$_}{limits}}[$exons{$prev}{number}] - $stopdiff;
		}
		$c++;
		if ($exons{$b}{type} eq 'begin') {
		    push @self, $b;
		    if (${$seqref}{$_}{strand} == 1) {
			push @gc, ${${$seqref}{$_}{limits}}[$exons{$prev}{number}] + $stopdiff;
		    }
		    else {
			push @gc, ${${$seqref}{$_}{limits}}[$exons{$prev}{number}] - $stopdiff;
		    }
		    $c++;
		}
		
		last;
	    }
	    else {
		next;
	    }
	}
	
	@{$homol_mapping{$_}{self}}=@self;
	@{$homol_mapping{$_}{gc}}=@gc;
	foreach my $tmp (@self) {
	    push @{$homol_mapping{$_}{tag}}, ($tmp-$self[0]+1);
	}
	
	
	
	
	
	
	
	print OUT "SAGE_tag : \"$tag\"\n";
	if (${$seqref}{$_}{type} eq 'Coding transcript') {
	    my $gene=$ct{$_};
	    if (!$gene) {
		print "cannot fetch gene for $_\n";
		next;
	    }
	    else {
		push @{$genes{$gene}}, $_, ${$mapref}{$_}[0];
	    }
	    print OUT "Transcript\t\"$_\"\tPosition\t${$mapref}{$_}[0]\n";
	    print OUT "Transcript\t\"$_\"\tStrand\t$strand\n";
	    if (/MTCE/) {
		print OUT "Transcript\t\"$_\"\tTranscript_source\t\"Coding RNA (mitochondrial)\"\n";
	    }
	    else {
		print OUT "Transcript\t\"$_\"\tTranscript_source\t\"Coding RNA\"\n";
	    }
	    print OUT "Gene\t\"$gene\"\tStrand\t$strand\n";
	    if (/MTCE/) {
		print OUT "Gene\t\"$gene\"\tTranscript_source\t\"Coding RNA (mitochondrial)\"\n";
	    }
	    else {
		print OUT "Gene\t\"$gene\"\tTranscript_source\t\"Coding RNA\"\n";
	    }
	    print OUT "\n";

	    print OUT "Transcript : \"$_\"\n";
	    print OUT "SAGE_tag\t\"$tag\"\tStrand\t$strand\n";
	    print OUT "\n";

	    print OUT "Gene : \"$gene\"\n";
	    print OUT "SAGE_tag\t\"$tag\"\tStrand\t$strand\n";
	    print OUT "\n";
	}
	elsif (${$seqref}{$_}{type} eq 'Non-coding transcript') {
	    my $gene=$nct{$_};
	    if (!$gene) {
		print "cannot fetch gene for $_\n";
		next;
	    }
	    else {
		push @{$genes{$gene}}, $_, ${$mapref}{$_}[0];
	    }
	    print OUT "Transcript\t\"$_\"\tPosition\t${$mapref}{$_}[0]\n";
	    print OUT "Transcript\t\"$_\"\tStrand\t$strand\n";
	    if (/MTCE/) {
		print OUT "Transcript\t\"$_\"\tTranscript_source\t\"Non-coding RNA (mitochondrial)\"\n";
	    }
	    else {
		print OUT "Transcript\t\"$_\"\tTranscript_source\t\"Non-coding RNA\"\n";
	    }
	    print OUT "Gene\t\"$gene\"\tStrand\t$strand\n";
	    if (/MTCE/) {
		print OUT "Gene\t\"$gene\"\tTranscript_source\t\"Non-coding RNA (mitochondrial)\"\n";
	    }
	    else {
		print OUT "Gene\t\"$gene\"\tTranscript_source\t\"Non-coding RNA\"\n";
	    }
	    print OUT "\n";

	    print OUT "Transcript : \"$_\"\n";
	    print OUT "SAGE_tag\t\"$tag\"\tStrand\t$strand\n";
	    print OUT "\n";

	    print OUT "Gene : \"$gene\"\n";
	    print OUT "SAGE_tag\t\"$tag\"\tStrand\t$strand\n";
	    print OUT "\n";
	}
	elsif (${$seqref}{$_}{type} eq 'Pseudogene') {
	    my $gene=$pseudo{$_};
	    if (!$gene) {
		print "cannot fetch gene for $_\n";
		next;
	    }
	    else {
		push @{$genes{$gene}}, $_, ${$mapref}{$_}[0];
	    }
	    print OUT "Pseudogene\t\"$_\"\tPosition\t${$mapref}{$_}[0]\n";
	    print OUT "Pseudogene\t\"$_\"\tStrand\t$strand\n";
	    print OUT "Pseudogene\t\"$_\"\tTranscript_source\t\"Pseudogene\"\n";
	    print OUT "Gene\t\"$gene\"\tStrand\t$strand\n";
	    print OUT "Gene\t\"$gene\"\tTranscript_source\t\"Pseudogene\"\n";
	    print OUT "\n";

	    print OUT "Pseudogene : \"$_\"\n";
	    print OUT "SAGE_tag\t\"$tag\"\tStrand\t$strand\n";
	    print OUT "\n";

	    print OUT "Gene : \"$gene\"\n";
	    print OUT "SAGE_tag\t\"$tag\"\tStrand\t$strand\n";
	    print OUT "\n";
	}
    }
    
    if ($type eq 'transcript') {

	my $mapping_type='';
	my $min;
	my $min_gene;
	if (scalar keys %genes == 1) {
	    $mapping_type='Unambiguously_mapped';
	    my @tmp=keys %genes;
	    $min_gene=$tmp[0];
	}
	elsif (scalar keys %genes > 1) {
	    foreach (sort {$genes{$a}[1]<=>$genes{$b}[1]} keys %genes) {
		if (!$min) {
		    $min=$genes{$_}[1];
		    $min_gene=$_;
		    next;
		}
		if ($genes{$_}[1] > $min) {
		    $mapping_type="Most_three_prime";
		    last;
		}
		else {
		    $min_gene='';
		    last;
		}
	    }
	}
	
	if ($min_gene) {
	    print OUT "SAGE_tag : \"$tag\"\n";
	    print OUT "$mapping_type\n";
	    print OUT "Gene\t\"$min_gene\"\t$mapping_type\n";
	    for (my $i=0; $i<=$#{$genes{$min_gene}}; $i++) {
		if ($i % 2 == 0) {
		    if (${$seqref}{${$genes{$min_gene}}[$i]}{type} eq 'Coding transcript' || 
			${$seqref}{${$genes{$min_gene}}[$i]}{type} eq 'Non-coding transcript') {
			if ($mapping_type eq "Most_three_prime" and ${$genes{$min_gene}}[$i+1] != $min) {  # only flag transcripts with lowest position
			    next;
			}
			print OUT "Transcript\t\"${$genes{$min_gene}}[$i]\"\t$mapping_type\n";
			$transcripts{${$genes{$min_gene}}[$i]}=$mapping_type;
		    }
		    elsif (${$seqref}{${$genes{$min_gene}}[$i]}{type} eq 'Pseudogene') {
			if ($mapping_type eq "Most_three_prime" and ${$genes{$min_gene}}[$i+1] != $min) {  # only flag pseudogenes with lowest position
			    next;
			}
			print OUT "Pseudogene\t\"${$genes{$min_gene}}[$i]\"\t$mapping_type\n";
			$pseudogenes{${$genes{$min_gene}}[$i]}=$mapping_type;
		    }
		}
		
	    }
	}
	print OUT "\n";
	
	if ($min_gene) {
	    print OUT "Gene : \"$min_gene\"\n";
	    print OUT "SAGE_tag\t\"$tag\"\t$mapping_type\n";
	    print OUT "\n";
	    
	    foreach (keys %transcripts) {
		print OUT "Transcript : \"$_\"\n";
		print OUT "SAGE_tag\t\"$tag\"\t$mapping_type\n";
		print OUT "\n";
	    }
	    
	    foreach (keys %pseudogenes) {
		print OUT "Pseudogene : \"$_\"\n";
		print OUT "SAGE_tag\t\"$tag\"\t$mapping_type\n";
		print OUT "\n";
	    }
	}
	print OUT "\n";
    }
    
    foreach my $tr (keys %homol_mapping) {
	my $method="SAGE_tag";
	if ($transcripts{$tr}) {
	    $method.="_". lc $transcripts{$tr};
	}
	elsif ($pseudogenes{$tr}) {
	    $method.="_". lc $pseudogenes{$tr};
	}
	print OUT "Homol_data\t\"${$seqref}{$tr}{refseq}:SAGE\"\n";
	for (my $i=0; $i<=$#{$homol_mapping{$tr}{self}}; $i+=2) {
	    print OUT "SAGE_homol\t\"$tag\"\t\"$method\"\t$$tagsref{$tag}{freq}";
	    print OUT "\t${$homol_mapping{$tr}{gc}}[$i]\t${$homol_mapping{$tr}{gc}}[$i+1]\t${$homol_mapping{$tr}{tag}}[$i]\t${$homol_mapping{$tr}{tag}}[$i+1]\n";
	}
	print OUT "\n";
	
    }
}

##########################################
# get the length of a clone/superlink/chromosome
# $len = get_clone_len($clone)

sub get_clone_len {
  my ($clone) = @_;

  my $clonelen = $clonesize{$clone};

  if (! defined $clonelen) {
    if ($clone =~ /SUPERLINK/ || $clone =~ /CHROMOSOME/) {
      # get the Superlink lengths from the Coords_converter data
      $clonelen = $coords->Superlink_length($clone);
    } else {
      die "undef returned for length of $clone\n";
    }
  }

  return $clonelen;

}

##########################################

sub usage {
  my $error = shift;

  if ($error eq "Help") {
    # Normal help menu
    system ('perldoc',$0);
    exit (0);
  }
}

##########################################

=pod

=head2 NAME - map_tags.pl

=head1 USAGE

=over 4

=item map_tags.pl  [-options]

=back

This script maps the SAGE tags to transcripts and to the genome. It
runs get_sequences_gff.pl under LSF for each chromosome to produce
files of the details of the transcripts and psuedogenes. It reads in
these files and maps the SAGE tags against them. It reads in the
chromosomal sequences and maps the SAGE tags against those. It writes
out an ACE file giving the mapping position, associated genes and tags
for most3 prime and unique mapping.

script_template.pl MANDATORY arguments:

=over 4

=item -output AceFile  to output the result to.

=back

script_template.pl  OPTIONAL arguments:

=over 4

=item -h, Help

=back

=over 4
 
=item -debug, Debug mode, set this to the username who should receive the emailed log messages. The default is that everyone in the group receives them.
 
=back

=over 4

=item -test, Test mode, run the script, but don't change anything.

=back

=over 4
    
=item -verbose, output lots of chatty test messages

=back


=head1 REQUIREMENTS

=over 4

=item This requires the autoace database and GFF files to read the transcript data from and to read the SAGE data from.

=back

=head1 AUTHOR

=over 4

=item Gary Williams

=back

=cut
