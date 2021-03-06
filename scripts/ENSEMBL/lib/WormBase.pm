#
# You may distribute this module under the same terms as perl itself
#
# POD documentation - main docs before the code
# mod fsk

=pod 

=head1 NAME

WormBase

=head1 SYNOPSIS

the methods are all used by wormbase_to_ensembl.pl script which should be in the same directory

=head1 DESCRIPTION

parse gff and agp files from the wormbase database for caenorhabditis elegans to create ensembl database.

=head1 CONTACT

ensembl-dev@ebi.ac.uk about code issues
wormbase-hel@wormbase.org about data issues

=head1 APPENDIX

=cut

#use lib '/nfs/acari/wormpipe/ensembl/ensembl-pipeline/scripts/DataConversion/wormbase';
#use lib '/nfs/acari/wormpipe/ensembl/ensembl/modules';

package WormBase;
require Exporter;

our @ISA    = qw(Exporter);
our @EXPORT =
  qw( parse_gff parse_gff3_fh write_genes translation_check display_exons non_translate process_file parse_operons write_simple_features parse_rnai parse_expr parse_SL1 parse_SL2 parse_pseudo_files parse_simplefeature parse_gff_fh parse_pcr_product);

use strict;
use Storable qw(store retrieve freeze thaw dclone);

use Bio::EnsEMBL::Exon;
use Bio::EnsEMBL::Gene;
use Bio::EnsEMBL::Transcript;
use Bio::EnsEMBL::Translation;
use Bio::EnsEMBL::SimpleFeature;
use Bio::EnsEMBL::CoordSystem;
use Bio::EnsEMBL::Slice;
use Bio::EnsEMBL::Analysis::Tools::GeneBuildUtils::ExonUtils;

$WormBase::Species = "";
$WormBase::DEBUG = 0;

=head2 parse_gff

  Arg [1]   : filename of gff file
  Arg [2]   : Bio::Seq object
  Arg [3]   : Bio::EnsEMBL::Analysis object
  Function  : parses gff file given into genes
  Returntype: array ref of Bio::EnEMBL::Genes
  Exceptions: dies if can't open file or seq isn't a Bio::Seq 
  Caller    : 
  Example   : 

=cut

sub parse_gff {
  my ( $file, $slice_hash, $analysis ) = @_;
  
  my $fh; 
  
  open( $fh, $file ) or die "couldn't open " . $file . " $!";
  
  my $genes = &parse_gff_fh($fh, $slice_hash, $analysis);
  
  return $genes;
}


sub parse_gff_fh {
  my ( $fh, $slice_hash, $analysis ) = @_;
    
  my ( $transcripts, $five_prime, $three_prime, $parent_seqs ) = &process_file( $fh );
  print STDERR "there are " . keys(%$transcripts) . " distinct transcripts\n";
  
  my ( $processed_transcripts, $five_start, $three_end, $trans_start_exon, $trans_end_exon ) =
      &generate_transcripts( $transcripts, $slice_hash, $analysis, $five_prime, $three_prime, $parent_seqs );
  
  print STDERR "\nthere are " . keys(%$processed_transcripts) . " transcripts\n";
  
  my $genes = &create_transcripts( $processed_transcripts, $five_start, $three_end, $trans_start_exon, $trans_end_exon );
  
  print STDERR "\nPARSE GFF has " . keys(%$genes) . " genes\n";
  my @genes;
  foreach my $gene_id ( keys(%$genes) ) {
    my $transcripts = $genes->{$gene_id};
    my $gene    = &create_gene( $transcripts, $gene_id, 'protein_coding' );
    push( @genes, $gene );
  }
  
  print STDERR "\nPARSE_GFF got " . @genes . " genes\n";
  return \@genes;
}



=head2 parse_gff3

  Arg [1]   : filename of gff file
  Arg [2]   : Bio::Seq object
  Arg [3]   : Bio::EnsEMBL::Analysis object
  Function  : parses gff file given into genes
  Returntype: array ref of Bio::EnEMBL::Genes
  Exceptions: dies if can't open file or seq isn't a Bio::Seq 
  Caller    : 
  Example   : 

=cut

sub parse_gff3_fh {
  my ($fh, $slice_hash, $analysis_hash) = @_;

  #
  # gene
  # mRNA
  # exon
  # CDS
  #
  my (%genes, %transcripts);

  while(<$fh>) {
    chomp;
    next if /^\#/;
    my @l = split(/\t+/, $_);
    
    next if ($l[2] ne 'mRNA' and 
             $l[2] ne 'rRNA' and 
             $l[2] ne 'tRNA' and 
             $l[2] ne 'primary_transcript' and 
             $l[2] ne 'protein_coding_primary_transcript' and  
             $l[2] ne 'CDS' and 
             $l[2] ne 'exon');
    
    my ($id, $name, %parents);

    foreach my $el (split(/;/, $l[8])) {
      my ($k, $v) = $el =~ /(\S+)=(.+)/;
      if ($k eq 'ID') {
        $id = $v;
      } elsif ($k eq 'Name') {
        $name = $v;
      } elsif ($k eq 'Parent') {
        my @p = split(/,/, $v);
        map { $parents{$_} = 1 } @p;
      }
    }
    
    if ($l[2] eq 'exon') {
      # parent is mRNA
      foreach my $parent (keys %parents) {
        push @{$transcripts{$parent}->{exons}}, {
          seq       => $l[0],
          start     => $l[3],
          end       => $l[4],
          strand    => $l[6],
          phase     => -1,
          end_phase => -1,
        };
      }
    } elsif ($l[2] eq 'CDS') {
      foreach my $parent (keys %parents) {
        push @{$transcripts{$parent}->{cds}}, {
          seq        => $l[0],
          start      => $l[3],
          end        => $l[4],
          strand     => $l[6],
          gff_phase  => $l[7],
        };
      }
    } elsif ($l[2] eq 'mRNA' or 
             $l[2] eq 'tRNA' or
             $l[2] eq 'rRNA' or
             $l[2] eq 'primary_transcript' or 
             $l[2] eq 'protein_coding_primary_transcript') {
      $transcripts{$id}->{source} = $l[1];
      $transcripts{$id}->{type}   = $l[2];
      $transcripts{$id}->{seq}    = $l[0];
      $transcripts{$id}->{start}  = $l[3];
      $transcripts{$id}->{end}    = $l[4];
      $transcripts{$id}->{strand} = $l[6];
      $transcripts{$id}->{name}   = $name;

      foreach my $parent (keys %parents) {
        push @{$genes{$parent}}, $id;
      }
    }
  }
   
  my @all_ens_genes;

  GENE: foreach my $gid (keys %genes) {
    my @tids = sort @{$genes{$gid}};

    my $gene = Bio::EnsEMBL::Gene->new(
      -stable_id => $gid,
        );

    my $gene_is_coding = 0;

    TRAN: foreach my $tid (@tids) {

      my $tran = $transcripts{$tid};
      my $gff_source = $tran->{source};
      my $gff_type = $tran->{type};

      if (not exists $tran->{exons}) {
        # For some single-exon features, e.g. ncRNAs, exons are not compulsory in the GFF3. 
        # Add that exon dynamically here then
        push @{$tran->{exons}}, {
          seq       => $tran->{seq},
          start     => $tran->{start},
          end       => $tran->{end},
          strand    => $tran->{strand},
          phase     => -1,
          end_phase => -1,
        };
      }

      my @exons = sort { $a->{start} <=> $b->{start} } @{$tran->{exons}};

      # sanity check: exons do not overlap
      for(my $i=0; $i < scalar(@exons) - 1; $i++) {
        if ($exons[$i]->{end} >= $exons[$i+1]->{start}) {
          $WormBase::DEBUG and print STDERR "Skipping gene with  transcript $tid ($gff_source) - exons overlap\n";
          next GENE;
        }
      }

      my $strand = $exons[0]->{strand};
      my $slice = $slice_hash->{$exons[0]->{seq}};
      die "Could not find slice\n" if not defined $slice;

      if (exists $tran->{cds}) {
        my @cds = sort { $a->{start} <=> $b->{start} } @{$tran->{cds}};

        # sanity check: CDS segments do not overlap
        for(my $i=0; $i < scalar(@cds) - 1; $i++) {
          if ($cds[$i]->{end} >= $cds[$i+1]->{start}) {
            die "Bailing on transcript $tid - CDS segments overlap\n";
          }
        }

        #
        # match up the CDS segments with exons
        #

        foreach my $exon (@exons) {
          my ($matching_cds, @others) = grep { $_->{start} <= $exon->{end} and $_->{start} >= $exon->{start} } @cds;
          
          if (@others) {
            die "Bailing on transcript $tid: multiple matching CDSs for a single exon segment\n";
          }
          if (defined $matching_cds) {
            $exon->{cds_seg} = $matching_cds;
          }
        }
      }

      #
      # sort out phases
      # 
      @exons = reverse @exons if $strand eq '-';

      foreach my $exon (@exons) {

        if (exists $exon->{cds_seg}) {

          if (($strand eq '+' and $exon->{start} == $exon->{cds_seg}->{start}) or
              ($strand eq '-' and $exon->{end} == $exon->{cds_seg}->{end})) {
            # convert the GFF phase to Ensembl phase
            $exon->{phase} = (3 - $exon->{cds_seg}->{gff_phase}) % 3;
          }
          
          if (($strand eq '+' and $exon->{end} == $exon->{cds_seg}->{end}) or
              ($strand eq '-' and $exon->{start} == $exon->{cds_seg}->{start})) {
            my $cds_seg_len = $exon->{cds_seg}->{end} - $exon->{cds_seg}->{start} + 1;
            if ($exon->{phase} > 0) {
              $cds_seg_len += $exon->{phase};
            }
            $exon->{end_phase} = $cds_seg_len % 3;
          }

          if ($strand eq '+') {
            $exon->{cds_exon_start} = $exon->{cds_seg}->{start} - $exon->{start} + 1;
            $exon->{cds_exon_end}   = $exon->{cds_seg}->{end} - $exon->{start} + 1; 
          } else {
            $exon->{cds_exon_start} = $exon->{end} - $exon->{cds_seg}->{end} + 1;
            $exon->{cds_exon_end}   = $exon->{end} - $exon->{cds_seg}->{start} + 1;
          }
        }
      }
      
      my $transcript = Bio::EnsEMBL::Transcript->new(
        -stable_id => $tid,
        -analysis  => (exists $analysis_hash->{$gff_source}) ? $analysis_hash->{$gff_source} : $analysis_hash->{wormbase});

      my ($tr_st_ex, $tr_en_ex, $tr_st_off, $tr_en_off);

      foreach my $ex (@exons) {
        
        my $ens_ex = Bio::EnsEMBL::Exon->new(
          -slice     => $slice,
          -start     => $ex->{start},
          -end       => $ex->{end},
          -strand    => ($ex->{strand} eq '+') ? 1 : -1,
          -phase     => $ex->{phase},
          -end_phase => $ex->{end_phase},
            );

        $transcript->add_Exon($ens_ex);

        if ($ex->{cds_seg}) {
          if (not defined $tr_st_ex) {
            $tr_st_ex = $ens_ex;
            $tr_st_off = $ex->{cds_exon_start};
          }
          $tr_en_ex = $ens_ex;
          $tr_en_off = $ex->{cds_exon_end};
        }
      }
  
      if (defined $tr_st_ex and defined $tr_en_ex) {
        my $tr = Bio::EnsEMBL::Translation->new();
        $tr->start_Exon($tr_st_ex);
        $tr->end_Exon($tr_en_ex);
        $tr->start($tr_st_off);
        $tr->end($tr_en_off);
        $tr->stable_id($tid);
        $tr->version(1);

        $transcript->translation($tr);
        $transcript->biotype('protein_coding');
        $gene_is_coding = 1;
      } else {
        if ($gff_type =~ /RNA/) {
          $transcript->biotype($gff_type);
        } else {
          $transcript->biotype('ncRNA');
        }
      }

      $gene->add_Transcript($transcript);
    }

    if ($gene_is_coding) {
      $gene->biotype('protein_coding');
    } else {
      $gene->biotype('ncRNA');
    }
    # propagate analysis for first transcript up to the gene
    $gene->analysis( $gene->get_all_Transcripts->[0]->analysis );

    push @all_ens_genes, $gene;
  }

  return \@all_ens_genes;
  #
  # should probably test that the genes translate etc here
  # 
}


=head2 process_file

  Arg [1]   : filehandle pointing to a gff file
  Function  : parses out lines for exons
  Returntype: hash keyed on transcript id each containig array of lines for that transcript
              and two hashes of hashes with arrays containing 5 prime and 3 prime UTR lines
  Exceptions: 
  Caller    : 
  Example   : 

=cut

sub process_file {
  my ($fh) = @_;
  
  my %genes;
  my $transcript;
  my %five_prime;
  my %three_prime;
  my %parent_seqs;
  LOOP: while (<$fh>) {

    #CHROMOSOME_I    curated three_prime_UTR 11696828        11697110        .       -       .       Transcript "T22H2.5a"
    #CHROMOSOME_I    curated three_prime_UTR 11697157        11697230        .       -       .       Transcript "T22H2.5a"
    #CHROMOSOME_I    curated five_prime_UTR  11698944        11698954        .       -       .       Transcript "T22H2.5a"
    
    chomp;
    my ( $chr, $status, $type, $start, $end, $score, $strand, $frame, $sequence, $gene ) = split;
    my $element = $_;
    
    if ( $chr =~ /sequence-region/ ) {
      next LOOP;
    }
    if (/^##/) {
      next LOOP;
    }
    if ( !$status && !$type ) {
      next LOOP;
    }
    my $line = $status . " " . $type;
    
    if ( $line eq 'Coding_transcript protein_coding_primary_transcript') {
      
      $gene =~ s/\"//g;
      $transcript = $gene;
      
      if ($WormBase::Species and $WormBase::Species !~ /elegans/) {
        $gene =~ s/^(\w+)\.\d+$/$1/;
      } else {
        $gene =~ s/(\.\w+)\.\d+$/$1/;
      }
      
      if (not $five_prime{$gene}) {
        $five_prime{$gene} = {};
      }
      if (not $five_prime{$gene}{$transcript}) {
        $five_prime{$gene}{$transcript} = [];
      }
      
      if (not $three_prime{$gene}) {
        $three_prime{$gene} = {};
      }
      if (not $three_prime{$gene}{$transcript}) {
        $three_prime{$gene}{$transcript} = [];
      }
    
      next LOOP;
    } elsif ( ( $line eq 'Coding_transcript five_prime_UTR' ) or ( $line eq 'Coding_transcript three_prime_UTR' ) ) {
      $gene =~ s/\"//g;
      $transcript = $gene;
      
      #remove transcript-specific part: Y105E8B.1a.2
      if ($WormBase::Species and $WormBase::Species !~ /elegans/) {
        $gene =~ s/^(\w+)\.\d+$/$1/;
      } else {
        $gene =~ s/(\.\w+)\.\d+$/$1/;
      }
      
      my ($position) = $type;
      if ( $position =~ /^five/ ) {
        
        if ( !$five_prime{$gene} ) {
          $five_prime{$gene} = {};
          if ( !$five_prime{$gene}{$transcript} ) {
            $five_prime{$gene}{$transcript} = [];
          }
          push( @{ $five_prime{$gene}{$transcript} }, $element );
        }
        else {
          if ( !$five_prime{$gene}{$transcript} ) {
            $five_prime{$gene}{$transcript} = [];
          }
          push( @{ $five_prime{$gene}{$transcript} }, $element );
        }
      }
      elsif ( $position =~ /^three/ ) {
        
        if ( !$three_prime{$gene} ) {
          $three_prime{$gene} = {};
          if ( !$three_prime{$gene}{$transcript} ) {
            $three_prime{$gene}{$transcript} = [];
          }
          push( @{ $three_prime{$gene}{$transcript} }, $element );
        }
        else {
          if ( !$three_prime{$gene}{$transcript} ) {
            $three_prime{$gene}{$transcript} = [];
          }
          push( @{ $three_prime{$gene}{$transcript} }, $element );
        }
      }
      next LOOP;
    }
    elsif ( $line ne 'curated coding_exon' ) {
      next LOOP;
    }
    $gene =~ s/\"//g;
    if ( !$genes{$gene} ) {
      $genes{$gene} = [];
      $parent_seqs{$gene} = $chr;
    }
    push( @{ $genes{$gene} }, $element );
  }

  #
  # Add "empty" UTRs for all of the genes that did not have one; downstream code needs this
  #
  foreach my $gene (keys %genes) {
    if (not $five_prime{$gene} ) {
      $five_prime{$gene} = {};
      $five_prime{$gene}{$gene} = [];
    }
    if (not $three_prime{$gene}) {
      $three_prime{$gene} = {};
      $three_prime{$gene}{$gene} = [];
    }
  }

  return \%genes, \%five_prime, \%three_prime, \%parent_seqs;
}

=head2 generate_transcripts
      
  Arg [1]   : hash ref (as returned by process_file, containing
              information about the CDS)
  Arg [2]   : Bio::EnsEMBL::Slice
  Arg [3]   : Bio::EnsEMBL::Analysis
  Arg [4]   : ref to hash of hashes (as returned by process_file, containing
              information about the 5' UTR regions
  Arg [5]   : ref to hash of hashes (as returned by process_file, containing
              information about the 3' UTR regions
  Function  : takes line representing a transcript and creates an exon for each one
  Returntype: hash ref hash keyed on transcript id containing an array of exons
  Exceptions: 
  Caller    : 
  Example   : 

=cut

sub generate_transcripts {
    my ( $genesRef, $slice_hash, $analysis, $five_prime, $three_prime, $parent_seqs ) = @_;
    my %genes;
    my %transcripts;
    my %temp_transcripts;
    my %five_trans_start;
    my %three_trans_end;
    my %trans_start_exon;
    my %trans_end_exon;
    my $translation_end;
    my $genecount = 0;
    my @global_exons;
    my %overlapcheck;

    use Bio::EnsEMBL::Analysis::Tools::GeneBuildUtils::ExonUtils;

    #go through all genes
    GENE: foreach my $gene_name ( keys(%$genesRef) ) {
      if (not exists $parent_seqs->{$gene_name}) {
        die "Could not find parent sequence for $gene_name\n";
      }
      my $parent_seq = $parent_seqs->{$gene_name};

      if (not exists $slice_hash->{$parent_seq}) {
        die "Could not find slice object for $parent_seq\n";
      }
      my $slice = $slice_hash->{$parent_seq};

      #create gene-hash entry
      $genes{$gene_name} = [];
      my $transcriptcount = 0;
      %temp_transcripts = ();
      
      ## collect all "curated_coding_exons" for this gene ##
      my @lines        = @{ $$genesRef{$gene_name} };    #is this right?
      my @global_exons = ();
      my %three_prime_exons;
      my %five_prime_exons;
      
      foreach my $line (@lines) {
        my ( $chr, $status, $type, $start, $end, $score, $strand, $frame, $sequence, $gene ) = split /\s+/, $line;

        my $exon  = new Bio::EnsEMBL::Exon;
        my $phase = ( 3 - $frame ) % 3;       

        $exon->start($start);
        $exon->end($end);
        $exon->analysis($analysis);
        $exon->slice($slice);
        $exon->phase($phase);
        my $end_phase = ( $phase + ( $exon->end - $exon->start ) + 1 ) % 3;
        
        $exon->end_phase($end_phase);
        if ( $strand eq '+' ) {
          $exon->strand(1);
        }
        else {
          $exon->strand(-1);
        }
        
        #$exon->score(100);
        push( @global_exons, $exon );
      }
      
      #sort exons for this gene
      if ( $global_exons[0]->strand == -1 ) {
        @global_exons = sort { $b->start <=> $a->start } @global_exons;
      }
      else {
        @global_exons = sort { $a->start <=> $b->start } @global_exons;
      }
      
      #collect 5' UTRs
      foreach my $transcript_name ( keys( %{ $$five_prime{$gene_name} } ) ) {
        
        my @five_prime_exons = ();
        %overlapcheck = ();
        
        #more than one transcript at 5 prime level
        $temp_transcripts{$transcript_name} = 1;
        
        #get UTR lines
        foreach my $line ( @{ $$five_prime{$gene_name}{$transcript_name} } ) {
          my ( $chr, $status, $type, $start, $end, $score, $strand, $frame, $sequence, $gene ) = split( /\s+/, $line );
          
          #avoid saving two identical exons
          if ( defined $overlapcheck{$start} ) {
            next;
          }
          $overlapcheck{$start} = 1;
          my $exon  = new Bio::EnsEMBL::Exon;
          my $phase = -1;
          $exon->start($start);
          $exon->end($end);
          $exon->analysis($analysis);
          $exon->slice($slice);
          $exon->phase($phase);
          my $end_phase = -1;
          $exon->end_phase($end_phase);
          
          if ( $strand eq '+' ) {
            $exon->strand(1);
          }
          else {
            $exon->strand(-1);
          }
          push( @five_prime_exons, $exon );
        }
        
        #sort exons for this transcript
        if ( @five_prime_exons and $five_prime_exons[0]->strand == -1 ) {
          @five_prime_exons = sort { $b->start <=> $a->start } @five_prime_exons;
        }
        else {
          @five_prime_exons = sort { $a->start <=> $b->start } @five_prime_exons;
        }
        
        #save them to transcript
        $five_prime_exons{$transcript_name} = \@five_prime_exons;
      }
      
      ## collect 3' UTRs ##
      foreach my $transcript_name ( keys( %{ $$three_prime{$gene_name} } ) ) {
        
        my @three_prime_exons = ();
        %overlapcheck = ();
        
        #more than one transcript at the 3 prime level, save the name
        $temp_transcripts{$transcript_name} = 1;
        
        #get UTR lines
        foreach my $line ( @{ $$three_prime{$gene_name}{$transcript_name} } ) {
          my ( $chr, $status, $type, $start, $end, $score, $strand, $frame, $sequence, $gene ) = split /\s+/, $line;
          
          #avoid saving two identical exons
          if ( defined $overlapcheck{$start} ) {
            next;
          }
          $overlapcheck{$start} = 1;
          my $exon  = new Bio::EnsEMBL::Exon;
          my $phase = -1;
          $exon->start($start);
          $exon->end($end);
          $exon->analysis($analysis);
          $exon->slice($slice);
          $exon->phase($phase);
          my $end_phase = -1;
          $exon->end_phase($end_phase);
          
          if ( $strand eq '+' ) {
            $exon->strand(1);
          }
          else {
            $exon->strand(-1);
          }
          push( @three_prime_exons, $exon );
        }
        
        #sort exons for this transcript
        if ( @three_prime_exons and $three_prime_exons[0]->strand == -1 ) {
          @three_prime_exons = sort { $b->start <=> $a->start } @three_prime_exons;
        }
        else {
          @three_prime_exons = sort { $a->start <=> $b->start } @three_prime_exons;
        }

        #save them to transcript
        $three_prime_exons{$transcript_name} = \@three_prime_exons;
      }
      
      ## combine exons, 5' and 3' for every transcript ##
      foreach my $transcript_name ( keys %temp_transcripts ) {
        $transcriptcount++;
        my @exons = ();
        foreach my $temp_exon (@global_exons) {
          push( @exons, &clone_Exon($temp_exon) );
        }
        my $translation_start = 1;
        my $first             = 1;
        
        #set default translation range
        $trans_start_exon{$transcript_name} = 0;
        $trans_end_exon{$transcript_name}   = $#exons;
        #print "\ntrans-exons: " . $trans_start_exon{$transcript_name} . " - " . $trans_end_exon{$transcript_name} . " (" . scalar @exons . ")";
        
        #check 5' exons
        if ( @{$five_prime_exons{$transcript_name}} ) {
          my @five_prime_exons = @{ $five_prime_exons{$transcript_name} };
          $WormBase::DEBUG and print STDERR "\nworking on 5' of $transcript_name (" . scalar @five_prime_exons . ") ";
          
          #is last 5' UTR exon part of first coding exon?
          
          FIVEUTR: while ( my $five_prime_exon = shift(@five_prime_exons) ) {

            my $start  = $five_prime_exon->start;
            my $end    = $five_prime_exon->end;
            my $strand = $five_prime_exon->strand;
            
            if ( $exons[ $trans_start_exon{$transcript_name} ]->strand == 1 and $strand == 1 ) {
              
              #forward strand
              if ( $start > $end ) {
                next FIVEUTR;
              }
              if ( $end == ( $exons[ $trans_start_exon{$transcript_name} ]->start ) - 1 ) {
                
                #combine exons, adjust translation start
                $translation_start = $exons[ $trans_start_exon{$transcript_name} ]->start - $start + 1;
                
                $five_trans_start{$transcript_name} = $translation_start;
                $exons[ $trans_start_exon{$transcript_name} ]->start($start);
                $exons[ $trans_start_exon{$transcript_name} ]->phase(-1);
              }
              elsif ( $end < $exons[ $trans_start_exon{$transcript_name} ]->start - 1 ) {
                
                #additional non-coding exon
                #add to exon array, keep translation start on last coding exon
                $trans_start_exon{$transcript_name}++;
                $trans_end_exon{$transcript_name}++;
                unshift( @exons, $five_prime_exon );
                $WormBase::DEBUG and print "\nadditional non-coding exon (+) " . $start . " - " . $end;
              }
              else {
                $WormBase::DEBUG and print STDERR "\n>>$transcript_name strange 5' UTR exon (+): $start - $end with 1.exons at "
                    . $exons[ $trans_start_exon{$transcript_name} ]->start . " - "
                    . $exons[ $trans_start_exon{$transcript_name} ]->end;
                next FIVEUTR;
              }
            }
            elsif ( $exons[ $trans_start_exon{$transcript_name} ]->strand == -1 and $strand == -1 ) {
              
              #reverse strand
              if ( $start > $end ) {
                next FIVEUTR;
              }
              if ( $start == ( $exons[ $trans_start_exon{$transcript_name} ]->end ) + 1 ) {
                
                #combine exons, adjust translation start
                $translation_start = ( $end - $exons[ $trans_start_exon{$transcript_name} ]->end + 1 );
                
                $five_trans_start{$transcript_name} = $translation_start;
                $exons[ $trans_start_exon{$transcript_name} ]->end($end);
                $exons[ $trans_start_exon{$transcript_name} ]->phase(-1);
              }
              elsif ( $start > ( $exons[ $trans_start_exon{$transcript_name} ]->end ) + 1 ) {
                
                #additional non-coding exon
                #add to exon array, keep translation start on last coding exon
                $trans_start_exon{$transcript_name}++;
                $trans_end_exon{$transcript_name}++;
                unshift( @exons, $five_prime_exon );
                
              }
              else {
                $WormBase::DEBUG and print STDERR "\n>>$transcript_name strange 5' UTR exon (-): $start - $end with 1.exons at "
                    . $exons[ $trans_start_exon{$transcript_name} ]->start . " - "
                    . $exons[ $trans_start_exon{$transcript_name} ]->end;
                next FIVEUTR;
              }
            }
            else {
              $WormBase::DEBUG and rint STDERR "\n>>strand switch in UTR / coding!";
            }
          }
        }
        
        #check 3' exons
        if ( @{$three_prime_exons{$transcript_name}} ) {
          my @three_prime_exons = @{ $three_prime_exons{$transcript_name} };
          
          #is first 3' UTR exon part of last coding exon?
          
          THREEUTR: while ( my $three_prime_exon = shift(@three_prime_exons) ) {
          
            my $start  = $three_prime_exon->start;
            my $end    = $three_prime_exon->end;
            my $strand = $three_prime_exon->strand;
            
            if ( $exons[ $trans_end_exon{$transcript_name} ]->strand == 1 and $strand == 1 ) {
              
              #forward strand
              if ( $start > $end ) {
                $WormBase::DEBUG and print STDERR "\n>>$transcript_name strange 3' UTR (+) exon: " . $start . " - " . $end;
                next THREEUTR;
              }
              if ( $start == ( ( $exons[ $trans_end_exon{$transcript_name} ]->end ) + 1 ) ) {
                
                #combine exons, adjust translation start
                $translation_end =
                    ( ( $exons[ $trans_end_exon{$transcript_name} ]->end - $exons[ $trans_end_exon{$transcript_name} ]->start ) + 1 );
                
                $three_trans_end{$transcript_name} = $translation_end;
                $exons[ $trans_end_exon{$transcript_name} ]->end($end);
                $exons[ $trans_end_exon{$transcript_name} ]->end_phase(-1);
                
              }
              elsif ( $start > ( ( $exons[ $trans_end_exon{$transcript_name} ]->end ) + 1 ) ) {
                
                #additional non-coding exon
                #add to exon array
                push( @exons, $three_prime_exon );
                
              }
              else {
                $WormBase::DEBUG and print STDERR "\n$transcript_name strange 3' UTR exon (+): $start - $end with 1.exons at "
                    . $exons[ $trans_end_exon{$transcript_name} ]->start;
                next THREEUTR;
              }
            }
            elsif ( $exons[ $trans_end_exon{$transcript_name} ]->strand == -1 and $strand == -1 ) {
              
              #reverse strand
              if ( $start > $end ) {
                $WormBase::DEBUG and print STDERR "\n>>$transcript_name strange 3' UTR (-) exon: " . $start . " - " . $end;
                next THREEUTR;
              }
              if ( $end == ( ( $exons[ $trans_end_exon{$transcript_name} ]->start ) - 1 ) ) {
                
                #combine exons, keep translation start
                $translation_end =
                    ( ( $exons[ $trans_end_exon{$transcript_name} ]->end - $exons[ $trans_end_exon{$transcript_name} ]->start ) + 1 );
                
                $three_trans_end{$transcript_name} = $translation_end;
                $exons[ $trans_end_exon{$transcript_name} ]->start($start);
                $exons[ $trans_end_exon{$transcript_name} ]->end_phase(-1);
              }
              elsif ( $end < ( ( $exons[ $trans_end_exon{$transcript_name} ]->start ) - 1 ) ) {
                
                #additional non-coding exon
                #add to exon array
                push( @exons, $three_prime_exon );
                
              }
              else {
                $WormBase::DEBUG and print STDERR "\n$transcript_name strange 3' UTR exon (-): $start - $end with 1.exons at "
                    . $exons[ $trans_end_exon{$transcript_name} ]->start;
                next THREEUTR;
              }
            }
          }
          
        }
        
        #add exon data to transcript
        $transcripts{$transcript_name} = \@exons;
        
      }
    }

    return ( \%transcripts, \%five_trans_start, \%three_trans_end, \%trans_start_exon, \%trans_end_exon );
}

=head2 create_transcripts

  Arg [1]   : hash ref from process transcripts
  Function  : creates actually transcript objects from the arrays of exons
  Returntype: hash ref keyed on gene id containg an array of transcripts
  Exceptions: 
  Caller    : 
  Example   : 

=cut

sub create_transcripts {
  my ( $transcriptsRef, $five_start, $three_end, $trans_start_exon, $trans_end_exon ) = @_;
  
  my %transcripts = %$transcriptsRef;
  my @non_translate;
  my %genes;
  my $gene_name;
  my $transcript_id;
  foreach my $transcript ( keys(%transcripts) ) {
    my $time  = time;
    my @exons = @{ $transcripts{$transcript} };
    
    #get the gene-name

    if ($WormBase::Species and $WormBase::Species !~ /elegans/) {
      $gene_name= ( $transcript =~ /([a-zA-Z]{2,3}\d+)[a-z]*(\.\d+)*$/ ) ? $1 : $transcript;
    } else {
      $gene_name= ( $transcript =~ /(.*?\w+\.\d+)[a-z A-Z]*\.*\d*/ ) ? $1 : $transcript; 
    }
    
    $transcript_id = $transcript;

    my $transcript  = new Bio::EnsEMBL::Transcript;
    my $translation = new Bio::EnsEMBL::Translation;
    my @sorted_exons;
    if ( $exons[0]->strand == 1 ) {
      @sorted_exons = sort { $a->start <=> $b->start } @exons;
    }
    else {
      @sorted_exons = sort { $b->start <=> $a->start } @exons;
    }
    my $exon_count = 1;
    my $phase      = 0;
    foreach my $exon (@sorted_exons) {
      
      #$exon->created($time);
      #$exon->modified($time);
      $exon->stable_id( $transcript_id . "." . $exon_count );
      $exon_count++;
      eval {
        $transcript->add_Exon($exon);
      };
      if ($@) { 
        print STDERR "\n>>$transcript_id EXON ERROR: " . $@ . "\n";
      }
    }
    my $start_exon_ind;
    if ( exists( $trans_start_exon->{$transcript_id} ) ) {
      $WormBase::DEBUG and 
          print STDERR "\n adjusting coding exons to " . $trans_start_exon->{$transcript_id} . " - " . $trans_end_exon->{$transcript_id};
      $translation->start_Exon( $sorted_exons[ $trans_start_exon->{$transcript_id} ] );
      $translation->end_Exon( $sorted_exons[ $trans_end_exon->{$transcript_id} ] );
      $start_exon_ind = $trans_start_exon->{$transcript_id};
    }
    else {
      $WormBase::DEBUG and print STDERR  "\n no UTRs - setting translation to span whole transcript\n";
      $translation->start_Exon( $sorted_exons[0] );
      $translation->end_Exon( $sorted_exons[$#sorted_exons] );
      $start_exon_ind = 0;
    }
    
    if ( exists( $five_start->{$transcript_id} ) ) {
      $WormBase::DEBUG and print STDERR "1 setting translation start on transcript " . $transcript_id . " to " . $five_start->{$transcript_id} . "\n";
      $translation->start( $five_start->{$transcript_id} );
    }
    else {
      $WormBase::DEBUG and print STDERR "1 setting translation start on transcript $transcript_id to 1\n";
      $translation->start(1);
    }
    
    if ( ( !defined( $translation->start ) ) or ( $translation->start <= 0 ) ) {
      $WormBase::DEBUG and do {
        print STDERR ">> no translation start info for " . $transcript_id;
        print STDERR ".." . $five_start->{$transcript_id} . "\n";
      };
      die();
    }
    
    if ( exists( $three_end->{$transcript_id} ) ) {
      $WormBase::DEBUG and print STDERR "2 setting translation end on transcript " . $transcript_id . " to " . $three_end->{$transcript_id} . " (1)\n";
      $translation->end( $three_end->{$transcript_id} );
    }
    else {
      if ( defined( $trans_end_exon->{$transcript_id} ) ) {
        $translation->end( $sorted_exons[ $trans_end_exon->{$transcript_id} ]->end - $sorted_exons[ $trans_end_exon->{$transcript_id} ]->start + 1 );
        $WormBase::DEBUG and print STDERR "3 setting translation end on transcript "
            . $transcript_id . " to "
            . ( $exons[ $trans_end_exon->{$transcript_id} ]->end - $exons[ $trans_end_exon->{$transcript_id} ]->start + 1 )
            . " (2)\n";
      }
      else {
        $translation->end( $sorted_exons[$#sorted_exons]->end - $sorted_exons[$#sorted_exons]->start + 1 );
        $WormBase::DEBUG and print STDERR "4 setting translation end on transcript "
            . $transcript_id . " to "
            . ( $sorted_exons[$#sorted_exons]->end - $sorted_exons[$#sorted_exons]->start + 1 )
            . " (2)\n";
      }
    }
    
    $translation->stable_id($transcript_id);
    $translation->version(1);
    $transcript->translation($translation);
    $transcript->stable_id($transcript_id);
    $transcript->biotype('protein_coding');
    if ( !$genes{$gene_name} ) {
      $genes{$gene_name} = [];
      push( @{ $genes{$gene_name} }, $transcript );
    }
    else {
      push( @{ $genes{$gene_name} }, $transcript );
    }
  }
  return \%genes;
}

=head2 create_gene

  Arg [1]   : array ref of Bio::EnsEMBL::Transcript
  Arg [2]   : name to be used as stable_id
  Function  : take an array of transcripts and create a gene
  Returntype: Bio::EnsEMBL::Gene
  Exceptions: 
  Caller    : 
  Example   : 

=cut

sub create_gene {
    my ( $transcripts, $name, $biotype ) = @_;
    my $time     = time;
    my $gene     = new Bio::EnsEMBL::Gene;
    my $exons    = $transcripts->[0]->get_all_Exons;
    my $analysis = $exons->[0]->analysis;

    $gene->analysis($analysis);
    $gene->biotype( $biotype ) if defined $biotype;
    $gene->stable_id($name);
    foreach my $transcript (@$transcripts) {
      $transcript->analysis($analysis) if not $transcript->analysis;
      $gene->add_Transcript($transcript);
    }

    return $gene;
}

=head2 prune_Exons

  Arg [1]   : Bio::EnsEMBL::Gene
  Function  : remove duplicate exons between two transcripts
  Returntype: Bio::EnsEMBL::Gene
  Exceptions: 
  Caller    : 
  Example   : 

=cut

sub prune_Exons {
    my ($gene) = @_;

    my @unique_Exons;

    # keep track of all unique exons found so far to avoid making duplicates
    # need to be very careful about translation->start_Exon and translation->end_Exon

    foreach my $tran ( @{ $gene->get_all_Transcripts } ) {
        my @newexons;
        foreach my $exon ( @{ $tran->get_all_Exons } ) {
            my $found;

            #always empty
          UNI: foreach my $uni (@unique_Exons) {
                if (   $uni->start == $exon->start
                    && $uni->end == $exon->end
                    && $uni->strand == $exon->strand
                    && $uni->phase == $exon->phase
                    && $uni->end_phase == $exon->end_phase )
                {
                    $found = $uni;
                    last UNI;
                }
            }
            if ( defined($found) ) {
                push( @newexons, $found );
                if ( $exon == $tran->translation->start_Exon ) {
                    $tran->translation->start_Exon($found);
                }
                if ( $exon == $tran->translation->end_Exon ) {
                    $tran->translation->end_Exon($found);
                }
            }
            else {
                push( @newexons,     $exon );
                push( @unique_Exons, $exon );
            }
        }
        $tran->flush_Exons;
        foreach my $exon (@newexons) {
            $tran->add_Exon($exon);
        }
    }
    return $gene;
}

=head2 write_genes

  Arg [1]   : array ref of Bio::EnsEMBL::Genes
  Arg [2]   : Bio::EnsEMBL::DBSQL::DBAdaptor
  Function  : transforms genes into raw conti coords then writes them to the db provided
  Returntype: hash ref of genes keyed on clone name which wouldn't transform
  Exceptions: dies if a gene could't be stored
  Caller    : 
  Example   : 

=cut

sub write_genes {
  my ( $genes, $db, $stable_id_check ) = @_;
  my $e = 0;
  my %stable_ids;
  if ($stable_id_check) {
    my $sql = 'select stable_id from gene';
    my $sth = $db->dbc->prepare($sql);
    $sth->execute;
    while ( my ($stable_id) = $sth->fetchrow ) {
      $stable_ids{$stable_id} = 1;
    }
  }
  my %stored;
  
  GENE: foreach my $gene (@$genes) {

    if ($stable_id_check) {
      if ( $stable_ids{ $gene->stable_id } ) {
        $WormBase::DEBUG and print STDERR $gene->stable_id . " already exists\n";
        my $id = $gene->stable_id . ".pseudo";
        $gene->stable_id($id);
        foreach my $transcript ( @{ $gene->get_all_Transcripts } ) {
          my $trans_id = $transcript->stable_id . ".pseudo";
          $transcript->stable_id($trans_id);
          foreach my $e ( @{ $transcript->get_all_Exons } ) {
            my $id = $e->stable_id . ".pseudo";
            $e->stable_id($id);
          }
        }
      }
    }
    if ( $stored{ $gene->stable_id } ) {
      print STDERR "we have stored " . $gene->stable_id . " already\n";
      next GENE;
    }
    my $gene_adaptor = $db->get_GeneAdaptor;
    eval {
      $stored{ $gene->stable_id } = 1;
      $gene_adaptor->store($gene);
      $e++;
    };
    if ($@) {
      die("couldn't store " . $gene->stable_id . " problems=:$@:\n");
    }
  }
  print "\nStored gene: " . $e . "\n";
}

=head2 translation_check

  Arg [1]   : Bio::EnsEMBL::Gene
  Function  : checks if the gene translates
  Returntype: Bio::EnsEMBL::Gene if translates undef if doesn't'
  Exceptions: 
  Caller    : 
  Example   : 

=cut

sub translation_check {
  my ( $gene, $db ) = @_;
  
  my @transcripts = @{ $gene->get_all_Transcripts };
  foreach my $t (@transcripts) {
    unless ($t->translate){
      $t->adaptor()->db()->get_TranslationAdaptor()->fetch_by_Transcript($t);
    }
    my $pep = $t->translate->seq;
    if ( $pep =~ /\*/g ) {
      if ( $gene->stable_id eq 'C06G3.7' and $db ) {
        
        #add Selenocysteine to translation. There seems to be only on Selenoc. in our worm...
        my $pos = pos($pep);
        print STDERR "transcript "
            . $t->stable_id
            . " doesn't translate. Adding Selenocystein at position $pos.\n"
            . "Please beware of problems during further analysis steps because of this.";
        selenocysteine( $t, $pos, $db );
      }
      else {
        print STDERR "transcript " . $t->stable_id . " doesn't translate\n";
        print STDERR "translation start " . $t->translation->start . " end " . $t->translation->end . "\n";
        print STDERR "start exon coords " . $t->translation->start_Exon->start . " " . $t->translation->start_Exon->end . "\n";
        print STDERR "end exon coords " . $t->translation->end_Exon->start . " " . $t->translation->end_Exon->end . "\n";
        print STDERR "peptide " . $pep . "\n";
        
        &display_exons( @{ $t->get_all_Exons } );
        &non_translate($t);
        return undef;
      }
    }
  }
  return $gene;
}

=head2 selenocysteine

  Arg [1]   : transcript object to be modified
  Arg [2]   : position (integer) in transcripts sequence to be modified
  Arg [3]   : Bio::EnsEMBL::DBSQL::DBAdaptor
  Function  : modifiy transcript/translation by adding a seleocysteine residue
  Returntype: 
  Exceptions: 
  Caller    : 
  Example   : 

=cut

sub selenocysteine {
  my ( $transcript, $pos, $db ) = @_;
  print "\nmodifying " . $transcript->stable_id;
  
  my $seq_edit = Bio::EnsEMBL::SeqEdit->new(
    -CODE    => '_selenocysteine',
    -NAME    => 'Selenocysteine',
    -DESC    => 'Selenocysteine',
    -START   => $pos,
    -END     => $pos,
    -ALT_SEQ => 'U'                  #the one-letter symbol for selenocysteine
      );
  my $attribute         = $seq_edit->get_Attribute();
  my $translation       = $transcript->translation();
  my $attribute_adaptor = $db->get_AttributeAdaptor();
  $attribute_adaptor->store_on_Translation( $translation, [$attribute] );
}

=head2 display_exons

  Arg [1]   : array of Bio::EnsEMBL::Exons
  Function  : displays the array of exons provided for debug purposes put here for safe keeping
  Returntype: 
  Exceptions: 
  Caller    : 
  Example   : 

=cut

sub display_exons {
  my (@exons) = @_;
  
  @exons = sort { $a->start <=> $b->start || $a->end <=> $b->end } @exons if ( $exons[0]->strand == 1 );
  
  @exons = sort { $b->start <=> $a->start || $b->end <=> $a->end } @exons if ( $exons[0]->strand == -1 );
  
  foreach my $e (@exons) {
    print STDERR $e->stable_id . "\t " . $e->start . "\t " . $e->end . "\t " . $e->strand . "\t " . $e->phase . "\t " . $e->end_phase . "\n";
  } 
}

=head2 non_translate

  Arg [1]   : array of Bio::EnsEMBL::Transcripts
  Function  : displays the three frame translation of each exon here for safe keeping and debug purposes
  Returntype: 
  Exceptions: 
  Caller    : 
  Example   : 

=cut

sub non_translate {
  my (@transcripts) = @_;
  
  foreach my $t (@transcripts) {
    
    my @exons = @{ $t->get_all_Exons };
    
    foreach my $e (@exons) {
      print "exon " . $e->stable_id . " " . $e->start . " " . $e->end . " " . $e->strand . "\n";
      if ($e->end - $e->start + 1 < 5) {
        print " Exon too short; not attempting to translate\n";
        next;
      }
      my $seq  = $e->seq;
      my $pep0 = $seq->translate( '*', 'X', 0 );
      my $pep1 = $seq->translate( '*', 'X', 1 );
      my $pep2 = $seq->translate( '*', 'X', 2 );
      print "exon sequence :\n" . $e->seq->seq . "\n\n";
      print $e->seqname . " " . $e->start . " : " . $e->end . " translation in 0 frame\n " . $pep0->seq . "\n\n";
      print $e->seqname . " " . $e->start . " : " . $e->end . " translation in 1 phase\n " . $pep2->seq . "\n\n";
      print $e->seqname . " " . $e->start . " : " . $e->end . " translation in 2 phase\n " . $pep1->seq . "\n\n";
      print "\n\n";
      
    }
  }
}

=head2 parse_simplefeature
  Arg [1]   : gff file path
  Arg [2]   : Bio:Seq object
  Arg [3]   : analysis object
  ARG [4]   : source tag
  Function  : parse operon information
  Returntype: list of SimpleFeatures
  Exceptions: 
  Caller    : 
  Example   : 

=cut

sub parse_simplefeature {
  my ( $file, $slice_hash, $analysis, $source ) = @_;
  
  use IO::File;
  my $fh = new IO::File $file, 'r' or die "couldn't open " . $file . " $!";
  
  #CHROMOSOME_I	operon	transcription	13758388	13764178	.	-	.	Operon "CEOP1716"
  
  my @features;
  LINE: while (<$fh>) {
    chomp;
    my ( $chr, $type, $start, $end, $gff_strand, $id ) = (split)[0, 1, 3, 4, 6, 9 ];
    next LINE if ( $type ne $source );
    my $strand = $gff_strand eq '+' ? 1 : -1;
    $id =~ s/\"//g;
    
    die "Could not find slice for $chr\n" if not exists $slice_hash->{$chr};
    
    push @features, Bio::EnsEMBL::SimpleFeature->new(
      -start         => $start,
      -end           => $end,
      -strand        => $strand,
      -slice         => $slice_hash->{$chr},
      -analysis      => $analysis,
      -display_label => $id,
        )
  }
  undef $fh;
  return \@features;
}

=head2 parse_operons

  Arg [1]   : gff file path
  Arg [2]   : Bio:Seq object
  Arg [3]   : analysis object
  Function  : parse operon information

=cut

sub parse_operons {
  my ( $file, $slice_hash, $analysis ) = @_;
  
  open(my $fh, $file ) or die "couldn't open " . $file . " $!";
  
  #CHROMOSOME_I	operon	transcription	13758388	13764178	.	-	.	Operon "CEOP1716"
  
  my @operons;
  LINE: while (<$fh>) {
   chomp;
   my ( $chr, $type, $start, $end, $strand, $id ) = (split)[0, 1, 3, 4, 6, 9 ];
   
   if ( $type ne 'operon' ) {
     next LINE;
   }
   if ( $strand eq '-' ) {
     $strand = -1;
   }
   else {
     $strand = 1;
   }
   
   $id =~ s/\"//g;
   
   die "Could not find slice for $chr\n" if not exists $slice_hash->{$chr};
   
   my $simple_feature = Bio::EnsEMBL::SimpleFeature->new();
   $simple_feature->start($start);
   $simple_feature->strand($strand);
   $simple_feature->end($end);
   $simple_feature->display_label($id);
   $simple_feature->slice($slice_hash->{$chr});
   $simple_feature->analysis($analysis);
   push( @operons, $simple_feature );
  }
  
  return \@operons;
}


=head2 parse_rnai

  Arg [1]   : gff file path
  Arg [2]   : Bio:Seq object
  Arg [3]   : analysis object
  Function  : parse rnai information

=cut

sub parse_rnai {
  my ( $file, $slice_hash, $analysis ) = @_;
  
  open(my $fh, $file ) or die "couldn't open " . $file . " $!";
  
  my @rnai;
  LINE: while (<$fh>) {

    #CHROMOSOME_IV	RNAi	experimental	3195031	3196094	.	+	.	RNAi "JA:Y67D8A_375.b"
    #CHROMOSOME_I    RNAi_primary    RNAi_reagent    15040052        15041000        .       .       .       Target "RNAi:WBRNAi00027818" 1371 423
    #CHROMOSOME_I    RNAi_secondary  RNAi_reagent    15040723        15040982        .       .       .       Target "RNAi:WBRNAi00027816" 475 216      #print;
    chomp;
    my @values = split;
    if ( $values[1] ne 'cDNA_for_RNAi' ) {
      next LINE;
    }
    my ( $chr, $start, $end, $strand, $id);
    
    $chr    = $values[0];
    $start  = $values[3];
    $end    = $values[4];
    $strand = $values[6];
    $id     = $values[9];
    $id =~ s/\"//g;
    
    if ( $strand eq '+' ) {
      $strand = 1;
    }
    else {
      $strand = -1;
    }

    die "Could nor find slice for $chr\n" if not exists $slice_hash->{$chr};
    
    my $simple_feature = &create_simple_feature( $start, $end, $strand, $id, $slice_hash->{$chr}, $analysis );
    push( @rnai, $simple_feature );
  }
  
  return \@rnai;
}


=head2 parse_pcr_product

  Arg [1]   : gff file path
  Arg [2]   : Bio:Seq object
  Arg [3]   : analysis object
  Function  : parse pcr_product information

=cut

sub parse_pcr_product {
  my ($file, $slice_hash, $analysis) = @_;

  my @f;

  open(my $fh, $file) or die("Could not open $file for reading\n");

  while(<$fh>) {
    next if /^\#/;
    my @l = split(/\t/, $_);

    next if $l[2] ne 'PCR_product';
    die("Could not fine slice for $l[0]") if not exists $slice_hash->{$l[0]};

    my ($id) = $l[8] =~ /PCR_product\s+\"(\S+)\"/;
    my $sf = &create_simple_feature( $l[3],
                                     $l[4],
                                     $l[6] eq '-' ? -1 : 1,
                                     $id, 
                                     $slice_hash->{$l[0]}, 
                                     $analysis );
    push @f, $sf;

  }
  return \@f;
}


=head2 parse_expr

  Arg [1]   : gff file path
  Arg [2]   : Bio:Seq object
  Arg [3]   : analysis object
  Function  : parse expression information

=cut

sub parse_expr {
  my ( $file, $slice_hash, $analysis ) = @_;
  
  open( my $fh, $file ) or die "couldn't open " . $file . " $!";
  
  my @expr;
  LINE: while (<$fh>) {

    #CHROMOSOME_IV	RNAi	experimental	3195031	3196094	.	+	.	RNAi "JA:Y67D8A_375.b"
    chomp;
    my @values = split;
    if ( $values[1] ne 'Expr_profile' ) {
      next LINE;
    }
    my ( $chr,  $start, $end, $strand, $id);
    
    $chr    = $values[0];
    $start  = $values[3];
    $end    = $values[4];
    $strand = $values[6];
    $id     = $values[9];

    $id =~ s/\"//g;
    
    die "Could not find slice for $chr\n" if not exists $slice_hash->{$chr};

    if ( $strand eq '+' ) {
      $strand = 1;
    }
    else {
      $strand = -1;
    }

    my $simple_feature = &create_simple_feature( $start, $end, $strand, $id, $slice_hash->{$chr}, $analysis );
    push( @expr, $simple_feature );
  }

  return \@expr;
}

sub parse_SL1 {
  my ( $file, $slice_hash, $analysis ) = @_;

  open( my $fh, $file ) or die "couldn't open " . $file . " $!";
  
  my @sl1;
  LINE: while (<$fh>) {
    
    #CHROMOSOME_I	SL1	trans-splice_acceptor	6473786	6473787	.	-	.	Note "SL1 trans-splice site; see yk719h1.5"
    chomp;
    my @values = split;
    if ( $values[1] ne 'SL1' ) {
      next LINE;
    }
    if ( $_ =~ /personal\s+communication/ ) {
      print STDERR "Can't put information in table about " . $_ . "\n";
      next LINE;
    }
    my ($chr,  $start, $end, $strand, $id);
    
    $start  = $values[3];
    $end    = $values[4];
    $strand = $values[6];
    $id     = $values[14];
    if ( !$id ) {
      $id = $values[13];
    }
    if ( ( $id =~ /cDNA/ ) || ( $id =~ /EST/ ) ) {
      $id = $values[15];
    }
    if ( $id eq '"' ) {
      $id = $values[13];
    }
    if ( ( !$id ) || ( $id eq '"' ) ) {
      $id = $values[12];
    }
    $id =~ s/\"//g;

    if ( $strand eq '+' ) {
      $strand = 1;
    }
    else {
      $strand = -1;
    }
    
    if ( ( !$id ) || ( $id eq '.' ) || ( $id =~ /EST/ ) || ( $id =~ /cDNA/ ) || ( $id eq '"' ) ) {
      print "line " . $_ . " produced a weird id " . $id . "\n";
      next LINE;
    }

    die "Could not find slice for $chr\n" if not exists $slice_hash->{$chr};

    my $simple_feature = &create_simple_feature( $start, $end, $strand, $id, $slice_hash->{$chr}, $analysis );
    push( @sl1, $simple_feature );
  }
  
  return \@sl1;
}

sub parse_SL2 {
  my ( $file, $slice_hash, $analysis ) = @_;
  
  open( my $fh, $file ) or die "couldn't open " . $file . " $!";
  
  my @sl2;
  LINE: while (<$fh>) {
    
    #CHROMOSOME_I	SL2	trans-splice_acceptor	6473786	6473787	.	-	.	Note "SL2 trans-splice site; see yk729h2.5"
    chomp;
    my @values = split;
    if ( $values[1] ne 'SL2' ) {
      next LINE;
    }
    if ( $_ =~ /personal\s+communication/ ) {
      print STDERR "Can't put information in table about " . $_ . "\n";
      next LINE;
    }
    my ($chr,  $start, $end, $strand, $id);

    $chr    = $values[0];
    $start  = $values[3];
    $end    = $values[4];
    $strand = $values[6];
    $id     = $values[14];
    if ( !$id ) {
      $id = $values[13];
    }
    if ( ( $id =~ /cDNA/ ) || ( $id =~ /EST/ ) ) {
      $id = $values[15];
    }
    if ( $id eq '"' ) {
      $id = $values[13];
      if ( $id eq 'ESTyk1004g06.5' ) {
        $id =~ s/EST//g;
      }
    }
    if ( ( !$id ) || ( $id eq '"' ) ) {
      $id = $values[12];
    }
    $id =~ s/\"//g;    

    if ( $strand eq '+' ) {
      $strand = 1;
    }
    else {
      $strand = -1;
    }
    
    if ( ( !$id ) || ( $id eq '.' ) || ( $id =~ /EST/ ) || ( $id =~ /cDNA/ ) || ( $id eq '"' ) ) {
      print "line " . $_ . " produced a weird id " . $id . "\n";
      next LINE;
    }

    die "Could not find slice for $chr\n" if not exists $slice_hash->{$chr};

    my $simple_feature = &create_simple_feature( $start, $end, $strand, $id, $slice_hash->{$chr}, $analysis );
    push( @sl2, $simple_feature );
  }

  return \@sl2;
}

sub create_simple_feature {
  my ( $start, $end, $strand, $id, $seq, $analysis ) = @_;
  
  #warn "first: $start, $end, $strand, $id...";
  
  my $simple_feature = Bio::EnsEMBL::SimpleFeature->new();
  $simple_feature->start($start);
  $simple_feature->strand($strand);
  $simple_feature->end($end);
  $simple_feature->display_label($id);
  $simple_feature->slice($seq);
  $simple_feature->analysis($analysis);
  
  return $simple_feature;
}

sub write_simple_features {
  my ( $features, $db ) = @_;
  eval { print "\n check 1: " . $$features[0]->display_label };
  eval { print "\n check 2: " . $$features[0]->start . " - " . $$features[0]->end . "\n" };
  
  my $feature_adaptor = $db->get_SimpleFeatureAdaptor;
  
  eval { $feature_adaptor->store(@$features); };
  if ($@) {
    die "couldn't store simple features problems " . $@;
  }
}

=head2 parse_pseudo_gff

  Arg [1]   : gff file path
  Arg [2]   : Bio:Seq object
  Arg [3]   : analysis object
  Function  : parse pseudogene information

=cut

sub parse_pseudo_gff {
    my $type = "Pseudogene";
    my ( $file, $slice_hash, $analysis ) = @_;
    &parse_pseudo_files( $file, $slice_hash, $analysis, $type );
}

=head2 parse_pseudo_files

  Arg [1]   : gff file path
  Arg [2]   : Bio:Seq object
  Arg [3]   : analysis object
  Arg [4]   : type of feature to be parsed
  Function  : parse specific feature information from gff file
  Returntype: 
  Exceptions: 
  Caller    : 
  Example   : 

=cut

sub parse_pseudo_files {
  my ( $file, $slice_hash, $analysis, $types, $biotype ) = @_;
  
  open( my $fh, $file ) or die "couldn't open " . $file . " $!";
  
  my @genes;
  my ($transcripts, $tran2seq) = &process_pseudo_files( $fh, $types );
  print "there are " . keys(%$transcripts) . " distinct special transcripts\n";
  
  my ($processed_transcripts) = &process_pseudo_transcripts( $transcripts, $slice_hash, $analysis );
  print "there are " . keys(%$processed_transcripts) . " processed special transcripts\n";
  
  $biotype = $types if not defined $biotype; 
  
  my $genes = &create_pseudo_transcripts($processed_transcripts, $biotype);
  print "PARSE GFF there are " . keys(%$genes) . " special genes\n";
  
  foreach my $gene_id ( keys(%$genes) ) {
    my $transcripts = $genes->{$gene_id};
    my $gene = &create_gene( $transcripts, $gene_id, $biotype );
    push( @genes, $gene );
  }
  return \@genes;
}

#generic version
sub process_pseudo_files {
  my ( $fh, $types ) = @_;
  my (%transcripts);

  LOOP: while (<$fh>) {
    chomp;
    if (/^##/) {
      next LOOP;
    }
    my ( $chr, $status, $type, $start, $end, $score, $strand, $frame, $sequence, $gene ) = split;
    my $element = $_;
    if ( $chr =~ /sequence-region/ ) {    
      next LOOP;
    }
    if ( !$status && !$type ) {
      print "status and type no defined skipping\n";
      next LOOP;
    }
    my $line = $status . " " . $type;
    
    if ( $line ne $types . ' exon' ) {
      next LOOP;
    }
    $gene =~ s/\"//g;
    
    if ( !$transcripts{$gene} ) {
      $transcripts{$gene} = [];
      push( @{ $transcripts{$gene} }, $element );
    }
    else {
      push( @{ $transcripts{$gene} }, $element );
    }
  }
  return \%transcripts;
}

sub process_pseudo_transcripts {
  my ( $transcripts, $slice_hash, $analysis ) = @_;
  
  my %genes;
  my %transcripts = %$transcripts;
  my @names       = keys(%transcripts);
  
  foreach my $name (@names) {
    my @lines = @{ $transcripts{$name} };
    $transcripts{$name} = [];
    my @exons;
    foreach my $line (@lines) {
      
      my ( $chr, $status, $type, $start, $end, $score, $strand, $frame, $sequence, $gene ) = split /\s+/, $line;
      
      if ( $start == $end ) {
        next;
      }
      
      die "Could not not find slice for '$chr' in hash\n" if not exists $slice_hash->{$chr};
      
      my $exon = new Bio::EnsEMBL::Exon;
      
      # non-coding/pseudogene exons always have a phase -1/-1
      
      my $phase = -1; 
      my $end_phase = -1;
      
      $exon->start($start);
      $exon->end($end);
      $exon->analysis($analysis);
      $exon->slice($slice_hash->{$chr});
      $exon->phase($phase);
      $exon->end_phase($end_phase);
      if ( $strand eq '+' ) {
        $exon->strand(1);
      }
      else {
        $exon->strand(-1);
      }
      
      #$exon->score(100);
      push( @exons, $exon );
    }
    if ( $exons[0]->strand == -1 ) {
      @exons = sort { $b->start <=> $a->start } @exons;
    }
    else {
      @exons = sort { $a->start <=> $b->start } @exons;
    }
    my $phase = 0;
    foreach my $e (@exons) {
      push( @{ $transcripts{$name} }, $e );

    }
  }
  
  return ( \%transcripts );
}

sub create_pseudo_transcripts {
  my ($transcripts, $biotype) = @_;
  
  my %transcripts = %$transcripts;
  my %genes;
  my $gene_name;
  my $transcript_id;

  foreach my $transcript ( keys(%transcripts) ) {
    my $time  = time;
    my @exons = @{ $transcripts{$transcript} };


    if ($WormBase::Species and $WormBase::Species !~ /elegans/) {
      $gene_name= ( $transcript =~ /([a-zA-Z]{2,3}\d+)[a-z]$/ ) ? $1 : $transcript;
    } else {
      $gene_name= ( $transcript =~ /(\w+\.\d+)[a-z]/ ) ? $1 : $transcript; 
    }

    $transcript_id = $transcript;

    my $transcript = new Bio::EnsEMBL::Transcript;
    my @sorted_exons;
    if ( $exons[0]->strand == 1 ) {
      @sorted_exons = sort { $a->start <=> $b->start } @exons;
    }
    else {
      @sorted_exons = sort { $b->start <=> $a->start } @exons;
    }
    my $exon_count = 1;
    my $phase      = 0;
    foreach my $exon (@sorted_exons) {
      $exon->stable_id( $transcript_id . "." . $exon_count );
      $exon_count++;
      $transcript->add_Exon($exon);
    }
    $transcript->stable_id($transcript_id);
    $transcript->biotype($biotype) if defined $biotype;
    
    if ( !$genes{$gene_name} ) {
      $genes{$gene_name} = [];
      push( @{ $genes{$gene_name} }, $transcript );
    }
    else {
      push( @{ $genes{$gene_name} }, $transcript );
    }
  }
  return \%genes;
  
}

1;
