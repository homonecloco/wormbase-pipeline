#!/usr/local/bin/perl5.8.0 -w

# Author: Chao-Kung Chen
# Last updated by $Author: ar2 $
# Last updated on: $Date: 2007-02-26 14:52:43 $ 

use strict;
use lib $ENV{'CVS_DIR'};
use Wormbase;
use Ace;
use Tk;
use Tk::DialogBox;
use Getopt::Long;
use GENEACE::Geneace;
use Wormbase;
use Storable;


my ($panel, $comp, $rev, $version, $debug, $store, $test);

GetOptions ("p|panel:s"   => \$panel,    # number of rows (panels) to create
            "c|comp=s"    => \$comp,     # cmp_gmap_with_coord_order_WSXXX.date.pid
	    "r|rev=s"     => \$rev,      # reverse_physicals_WSXXX.date.pid
	    "v|version=s" => \$version,  # WS version, eg. 115
	    "d|debug"     => \$debug,    # will use test db for upload, otherwise use autoace
	    "store:s"     => \$store,
	    "test"        => \$test
	   );

############################
# recreate configuration   #
############################
my $wb;
if ($store) { $wb = Storable::retrieve($store) or croak("cant restore wormbase from $store\n") }
else { $wb = Wormbase->new( -debug => $debug, -test => $test, ) }

my $log = Log_files->make_build_log($wb);

my $tace = $wb->tace;

# ----- main frame -----
my $mw = MainWindow -> new();
$mw -> configure(title => "Update marker Loci genetics map                                                                                 ck1");
$mw->resizable(0,0);

# ----- example frame with label -----
my $example_frm = $mw->Frame(-relief => 'groove', -borderwidth => 2)
                      ->pack(-side => 'top', -anchor => 'n', -expand => 1, -fill => 'x');


$example_frm -> Label(-text => "You need to correct $panel reverse physical(s)", -bg => "black", -fg => "white")
             -> pack(-side => "top", -anchor => "n", -fill => "x", -expand => 1);

my $usg = "Start by clicking [ View rev. physicals ] \& [ View genetics map ], then:";
$example_frm -> Label(-text => $usg, -background => "black", -fg => "orange")
             -> pack(-side => "top", -anchor => "n", -fill => "x", -expand => 1);

my $usage = "1: Enter locus, chromosome and new/old map positions\n2: As one rev. phys can affect two loci, click [ Add row ] for more panels\n3: Click upload AUTOACE when done";
$example_frm -> Label(-text => $usage, -background => "black", -fg => "orange")
             -> pack(-side => "top", -anchor => "n", -fill => "x", -expand => 1);

$example_frm -> Label(-text => "All changes made will be mailed to CGC", -background => "black", -fg => "white")
             -> pack(-side => "top", -anchor => "n", -fill => "x", -expand => 1);

#----- button frame with buttons -----
my $button_frm = $mw ->Frame(-relief => 'groove', -borderwidth => 2)
                    ->pack(-side => 'top', -anchor => 'n', -expand => 1, -fill => 'x');

$button_frm->Button(-text => "View rev. physicals",  -activebackground => "white", -activeforeground => "blue", -command => \&view_rev_physicals)
           -> pack(-side => "left",  -fill => "x", -expand => 1);

$button_frm->Button(-text => "View genetics map",  -activebackground => "white", -activeforeground => "blue", -command => \&view_gmap)
           -> pack(-side => "left",  -fill => "x", -expand => 1);

my $add_btn = $button_frm->Button(-text => "Add row",  -activebackground => "white", -activeforeground => "blue", -command => \&add_row)
                            -> pack(-side => "left",  -fill => "x", -expand => 1);

my $upload_btn = $button_frm->Button(-text => "Upload AUTOACE",  -activebackground => "white", -activeforeground => "red", -command => \&load_autoace)
                            -> pack(-side => "left",  -fill => "x", -expand => 1);

my $exit_btn = $button_frm->Button(-text => "EXIT",  -activebackground => "white", -activeforeground => "red", -command => sub{exit(0)})
                          -> pack(-side => "left",  -fill => "x", -expand => 1);

# ----- lexical variables -----
my ($locus, $chrom, $map, $oldmap, %locus_map, @objs);
my $length = 100;

# make number of locus map panels necessary according to number of rev. physicals
for (my $j = 0; $j < $panel; $j++){
  $length = &loci_map_panel($panel-$j);
}

my $add_length = $length;

MainLoop;

#####################
#    subroutines
#####################

# --- popup rev. physical message ---
sub view_rev_physicals {
  my $mw1 = MainWindow -> new();
  $mw1 -> geometry("620x260+610+0");
  $mw1 -> configure(title => "Reverse physicals");
  open(IN, $rev);
  my $text;
  while(<IN>){$text .= $_}; close IN;
  my $box = $mw1 -> Scrolled("Text", -scrollbars => "e", -width => 100, height => 20)
                -> pack(); # takes "Text" inside ()

  $box->insert('end', $text);
  $mw1->resizable(1,0);
}

# --- popup gmap list ---
sub view_gmap {
 
  my $mw2 = MainWindow -> new();
  $mw2 -> geometry("520x300+610+290");
  $mw2 -> configure(title => "Comparison of genetics map and reverse physicals");
  open(IN, $comp);
  my $text;
  while(<IN>){$text .= $_}; #close IN;
  my $box = $mw2 -> Scrolled("Text", -scrollbars => "e", -width => 70, height => 20)
                 -> pack(); # takes "Text" inside ()
  $box->insert('end', $text);
  $mw2->resizable(0,0);
}

# --- make number of panels according to number of rev. physicals ---
sub loci_map_panel {

  my $panel = shift;
  my ($param_locus, $param_map, $param_oldmap, $param_chrom);

  my $block = $mw ->Frame(-relief => 'groove', -borderwidth => 2)
                  ->pack(-side => 'top', -anchor => 'n', -after => $example_frm, -expand => 1, -fill => 'x');

  $block -> Label(-text => "Locus", -foreground => "black")
         -> pack(-side => "left", -anchor => "n", -fill => "x", -expand => 1);

  $locus = $block -> Entry(-textvariable => \$param_locus, -background => "white", -foreground => "black", -width => 10)
                  ->pack(-side =>"left");

  $block -> Label(-text => "Chrom", -foreground => "black")
         -> pack(-side => "left", -anchor => "n", -fill => "x", -expand => 1);

  $chrom = $block -> Entry(-textvariable => \$param_chrom, -background => "white", -foreground => "black", -width => 3)
                  ->pack(-side =>"left");

  $block -> Label(-text => "Old Map", -foreground => "black")
         ->pack(-side => "left", -anchor => "n", -fill => "x", -expand => 1);

  $oldmap = $block -> Entry(-textvariable => \$param_oldmap, -background => "white", -foreground => "black", -width => 10)
                   ->pack(-side =>"left");

  $block -> Label(-text => "New Map", -foreground => "black")
         ->pack(-side => "left", -anchor => "n", -fill => "x", -expand => 1);

  $map = $block -> Entry(-textvariable => \$param_map, -background => "white", -foreground => "black", -width => 10)
                ->pack(-side =>"left");


  # put all objs in an array for later cget query
  push(@objs, $locus, $chrom, $map, $oldmap);

  # enlarge window with each new locus map panel
  my $leng = 65 + $length;
  $mw -> geometry("600x$leng+0+0");
  return $length = $length + 30;
}

# --- add new rows ---
sub add_row {

  $length = &loci_map_panel(1);
  $add_length = $length;
}

sub load_autoace {

  my $map_dir = $wb->autoace."/MAPPINGS/INTERPOLATED_MAP";
  my $updt = "$map_dir/rev_physical_update_WS$version";
  open(CGC, ">>$map_dir/rev_physical_CGC_WS$version") || die $!;
  open(UPDT, ">$updt") || die $!;
  my @rev = `cat $rev`;
  print CGC "\n\n", @rev;
  print CGC ("M O D I F I C A T I O N S\n\n");
  printf CGC ("%-8s %-6s %8s %8s\n", "Locus", "Chrom", "old_map", "new_map");
  print CGC "-----------------------------------\n";

  ##############################################################
  # hash to retrieve Gene obj info: 
  #      eg. WBGenexxxxxxxx to CGC_name/Sequence_name/Other_name
  #          and vice verse
  ##############################################################

  my $ga = init Geneace();
  my %Gene_info = $ga -> gene_info();

  for (my $i = 0; $i < scalar @objs; $i=$i+4){
    $locus  = $objs[$i]  ->cget("textvariable");
    $chrom  = $objs[$i+1]->cget("textvariable");
    $map    = $objs[$i+2]->cget("textvariable");
    $oldmap = $objs[$i+3]->cget("textvariable");

    print UPDT "\/\/$$locus ---------\n";
    print UPDT "\nGene : \"$Gene_info{$$locus}{'Gene'}\"\n";
    print UPDT "-D Map\n\n";
    print UPDT "Gene : \"$Gene_info{$$locus}{'Gene'}\"\n";
    print UPDT "Map \"$$chrom\" Position $$map\n";
    printf CGC ("%-8s %-6s %8.4f %8.4f\n", $$locus, $$chrom, $$oldmap, $$map);
  }
  print CGC  ("\n***********************************\n");
  close CGC; close UPDT;


  # load data to autoace
  my $command=<<END;
parse $updt
save
quit
END

  my $autoace = $wb->autoace;
  my $log = $wb->logs."/upload_rev_phys_correction_$version";

  open (Load_GA,"| $tace $autoace > $log") || die "Failed to upload to Geneace";
  print Load_GA $command;
  close Load_GA;

  # pop up a window for AceDB log message
  my $dialog =  $mw -> DialogBox(-title   => "Uploading corrected map data to autoace . . .",
				 -buttons => ["Close" ]);

  $dialog->geometry("800x500");
  $dialog->resizable(0,0);
  my $txt=$dialog->Scrolled("Text",  -scrollbars=>"ow", height=>60, -width=> 170)->pack(-side => "left", -anchor => "w");
  open(LOG, "$log");
  while(<LOG>){$txt -> insert('end', "$_")}
  $dialog->Show();

}


