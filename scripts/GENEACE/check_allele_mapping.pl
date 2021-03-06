#!/usr/local/bin/perl5.8.0 -w
# 
# check_allele_mapping.pl
#
# by Chao-Kung Chen
#
# Script to check if allele sequence from allele mapping script is the same as current 
#
# Last updated by: $Author: gw3 $
# Last updated on: $Date: 2010-07-14 15:06:27 $

# What it does: this script is a small integrity check before loading data generated from 
# map_alleles.pl during the build it should warn you if mapping result returns a clone different 
# from current one in geneace

use strict;
use lib -e "/wormsrv2/scripts"  ? "/wormsrv2/scripts"  : $ENV{'CVS_DIR'};
use Wormbase;


my $tace = &tace;
my $curr_db = "/nfs/wormpub/DATABASES/current_DB";
my $ga_dir = "/nfs/wormpub/DATABASES/geneace/";
my (@mapping, $allele, $seq, %allele_seq, %allele_seq_map);

my $WS_release = &get_wormbase_version_name();  
print "Using data from $WS_release\n";


@mapping = `echo "table-maker -p /nfs/wormpub/DATABASES/geneace/wquery/allele_has_seq.def" | $tace $ga_dir`;

foreach (@mapping){
  chomp;
  if ($_ =~ /^\"(.+)\"\s+\"(.+)\"/){ # $1 = allele, $2 = seq
   $allele_seq{$1} = $2;
  }
}

#open main input file (output of map_Alleles.pl)
open(IN, "/wormsrv2/autoace/MAPPINGS/map_alleles_geneace_update.".$WS_release.".ace") || die $!;

while(<IN>){
  if ($_ =~ /^Variation\s+:\s+\"(.+)\"/){
    $allele = $1;
  }
  if ($_ =~ /^Sequence\s+\"(.+)\"/){
    $seq = $1;
  }  
  $allele_seq_map{$allele} = $seq;
}

foreach (keys %allele_seq_map){
  print "$_ from mapping has a different seq than the one in geneace\n" 
  if (exists $allele_seq{$_} && $allele_seq_map{$_} ne $allele_seq{$_})

}
    
  

