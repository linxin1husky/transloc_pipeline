#!/usr/bin/perl


use strict;
use warnings;
use Getopt::Long;
use Carp;
use Switch;
use IO::Handle;
use IO::File;
use Text::CSV;
use File::Basename;
use File::Which;
use Bio::DB::Sam;
use List::Util qw(min max);
use Interpolation 'arg:@->$' => \&argument;
use Time::HiRes qw(gettimeofday tv_interval);

use Cwd qw(abs_path);
use FindBin;
use lib abs_path("$FindBin::Bin/../lib");

require "PerlSub.pl";
require "TranslocHelper.pl";


# Flush output after every write
select( (select(STDOUT), $| = 1 )[0] );

##
## This program
## 
## run with "--help" for usage information
##
## Robin Meyers

# Forward declarations
sub parse_command_line;
sub align_to_breaksite;
sub align_to_genome;
sub process_alignments;


# Global flags and arguments, 
# Set by command line arguments
my $read1;
my $read2;
my $workdir;
my $assembly;
my $threads = 4;

my $user_bowtie_opt = "";
my $user_bowtie_breaksite_opt = "";

# Global variables
my @tlxl_header = tlxl_header();
my @tlx_header = tlx_header();

my $stats = { totreads  => 0,
              aligned   => 0,
              alignment => 0,
              mapqual   => 0,
              dedup     => 0 };


#
# Start of Program
#

parse_command_line;


my $default_bowtie_breaksite_opt = "--local -D 20 -R 3 -N 1 -L 10 --score-min C,40 -p $threads --gbar 1 --dovetail --no-discordant --norc -X 1500 -t";
my $default_bowtie_opt = "--local -D 20 -R 3 -N 1 -L 20 --score-min G,20,6 -p $threads -k 10 --no-unal --gbar 1 --dovetail --no-discordant -X 1500 -t";

my $bt2_breaksite_opt = manage_program_options($default_bowtie_breaksite_opt,$user_bowtie_breaksite_opt);
my $bt2_opt = manage_program_options($default_bowtie_opt,$user_bowtie_opt);

my $t0 = [gettimeofday];

#check_working_dir;

my $expt = basename($workdir);
my $expt_stub = "$workdir/$expt";
my $tmpdir = "$workdir/tmp";
mkdir $tmpdir;
my $breaksite_fa = "$workdir/misc/breaksite.fa";
my $bt2_breaksite_idx = "$workdir/misc/breaksite";
my $breaksite_sam = "${expt_stub}_breaksite.sam";
my $breaksite_bam = "${expt_stub}_breaksite.bam";
my $sam = "$expt_stub.sam";
my $bam = "$expt_stub.bam";
my $tlxl = "$expt_stub.tlxl";
my $tlx = "$expt_stub.tlx";
my $statsfile = "$expt_stub.stats";


align_to_breaksite unless (-r $breaksite_bam);

align_to_genome unless (-r $bam);

if ($read1 =~ s/\.gz//) {
  System("gunzip -c $read1.gz > $read1") unless -r $read1;
}
if ($read2 =~ s/\.gz//) {
  System("gunzip -c $read2.gz > $read2") unless -r $read2;
}

process_alignments;

#filter_tlxl;


my $t1 = tv_interval($t0);

printf("\nFinished all processes in %.2f seconds.\n", $t1);

print("Some stats:\n".join("\t",$stats->{totreads},$stats->{aligned},$stats->{alignment},$stats->{mapqual})."\n");


#
# End of program
#

sub align_to_breaksite {
  print "\nRunning Bowtie2 alignment for $expt against breaksite locus\n";

  System("bowtie2-build -q $breaksite_fa $bt2_breaksite_idx");

  my $breaksite_bt2_cmd = "bowtie2 $bt2_breaksite_opt -x $bt2_breaksite_idx -1 $read1 -2 $read2 -S $breaksite_sam";

  System($breaksite_bt2_cmd);

  System("samtools view -bS -o $breaksite_bam $breaksite_sam");

}

sub align_to_genome {

  print "\nRunning Bowtie2 alignment for $expt against genome $assembly\n";

  my $bt2_cmd = "bowtie2 $bt2_opt -x $assembly -1 $read1 -2 $read2 -S $sam";

  System($bt2_cmd);

  # my $sortsam_jar = which("SortSam.jar");
  # croak "Error: could not find picard's SortSam.jar" unless defined $sortsam_jar;
  # my $markdup_jar = which("MarkDuplicates.jar");
  # croak "Error: could not find picard's MarkDuplicates.jar" unless defined $markdup_jar;


  # my $picard_sort_cmd = "java -Xmx2g -jar $sortsam_jar INPUT=$sam OUTPUT=$expt_stub.sort.sam SORT_ORDER=coordinate";
  # System($picard_sort_cmd);
  # my $picard_markdup_cmd = "java -Xmx2g -jar $markdup_jar INPUT=$expt_stub.sort.sam OUTPUT=$expt_stub.markdup.sam METRICS_FILE=$expt_stub.markdup.metrics";
  # System($picard_markdup_cmd);


  System("samtools view -bS -o $bam $sam");


}

sub process_alignments {

  print "\nProcessing alignments and writing tlxl and tlx files\n";


  my $samobj_brk = Bio::DB::Sam->new(-bam => $breaksite_bam,
                                     -fasta => $breaksite_fa,
                                     -expand_flags => 1);

  my $samobj = Bio::DB::Sam->new(-bam => $bam,
                                 -fasta => $ENV{'GENOME_DB'}."/$assembly/$assembly.fa",
                                 -expand_flags => 1);

  my $brk_iter = $samobj_brk->get_seq_stream(-type=>'read_pair');

  my $tlxlfh = IO::File->new(">$tlxl");
  my $tlxfh = IO::File->new(">$tlx");

  $tlxlfh->print(join("\t", @tlxl_header)."\n");
  $tlxfh->print(join("\t", @tlx_header)."\n");

  my %alns;

  my $iter = $samobj->get_seq_stream(-type=>'match');
  while (my $aln = $iter->next_seq) {
    my $qname = $aln->query->name;
    if (defined $alns{$aln->query->name}) {
      push(@{$alns{$qname}},$aln);
    } else {
      $alns{$qname} = [$aln];
    }
  }

  while (my $brk_aln = $brk_iter->next_seq) {


    $stats->{totreads}++;

    my ($R1_brk_aln, $R2_brk_aln) = $brk_aln->get_SeqFeatures;
    #my @q_alns = $samobj->get_features_by_name($R1_brk_aln->query->name);
    my @q_alns = @{$alns{$R1_brk_aln->query->name}} if exists $alns{$R1_brk_aln->query->name};

    if (scalar @q_alns > 0) {
      $stats->{aligned}++;

      my @alns = ();

      my $i = 0;
      my $j = 0;
      while ($i < @q_alns) {

        my $aln = $q_alns[$i++];
        my ($R1_aln,$R2_aln);

        if ($aln->get_tag_values('FIRST_MATE')) {
          $R1_aln = $aln;
          $R2_aln = $q_alns[$i++] unless ($R1_aln->munmapped);
        } else {
          $R2_aln = $aln;
        }
        $alns[$j++] = { R1_aln => $R1_aln, R2_aln => $R2_aln, mapq => undef, orientation => undef };
      }
      
      find_orientations(\@alns,$R1_brk_aln,$R2_brk_aln);
      
      filter_mapquals(\@alns,$R1_brk_aln,$R2_brk_aln);

      foreach my $aln (@alns) {

        $stats->{alignment}++;

        unless ( defined $aln->{orientation} && $aln->{orientation} > 0 ) { 
          create_tlxl_entry($tlxlfh,$aln,$R1_brk_aln,$R2_brk_aln,"BadOrientation");
          next;
        }

        unless ( defined $aln->{mapq} && $aln->{mapq} > 0 ) {
          create_tlxl_entry($tlxlfh,$aln,$R1_brk_aln,$R2_brk_aln,"MapQuality");
          next;
        }

        create_tlxl_entry($tlxlfh,$aln,$R1_brk_aln,$R2_brk_aln,$aln->{orientation});

        $stats->{mapqual}++;
        create_tlx_entry($tlxfh,$aln,$R1_brk_aln,$R2_brk_aln,$samobj,$samobj_brk);

      }

    } else {

      create_tlxl_entry($tlxlfh,undef,$R1_brk_aln,$R2_brk_aln,"Unaligned");
    }

  }

  $tlxlfh->close;
  $tlxfh->close;

}



sub create_tlx_entry ($$$$$$) {
  my $fh = shift;
  my $aln = shift;
  my $R1_brk_aln = shift;
  my $R2_brk_aln = shift;
  my $sam = shift;
  my $sam_brk = shift;
  
  my $R1_aln = $aln->{R1_aln};
  my $R2_aln = $aln->{R2_aln};

  my ($R1_Qstart,$R1_Qend,$R2_Qstart,$R2_Qend);
  my ($R1_BrkQstart,$R1_BrkQend,$R2_BrkQstart,$R2_BrkQend);

  if (defined $R1_aln) {
    $R1_Qstart = $R1_aln->reversed ? $R1_aln->l_qseq - $R1_aln->query->end + 1 : $R1_aln->query->start;
    $R1_Qend = $R1_aln->reversed ? $R1_aln->l_qseq - $R1_aln->query->start + 1 : $R1_aln->query->end;
  }

  if (defined $R2_aln) {
    $R2_Qstart = $R2_aln->reversed ? $R2_aln->query->start : $R2_aln->l_qseq - $R2_aln->query->end + 1;
    $R2_Qend = $R2_aln->reversed ? $R2_aln->query->end : $R2_aln->l_qseq - $R2_aln->query->start + 1;
  }
  unless ($R1_brk_aln->unmapped) {
    $R1_BrkQstart = $R1_brk_aln->query->start;
    $R1_BrkQend = $R1_brk_aln->query->end;
  }
  unless ($R2_brk_aln->unmapped) {
    $R2_BrkQstart = $R2_brk_aln->query->start;
    $R2_BrkQend = $R2_brk_aln->query->end;
  }

  my @tlx_header = tlx_header();
  my $ori = $aln->{orientation};
  my $entry = {};

  $entry->{Qname} = $R1_brk_aln->query->name;


  switch ($ori) {
    
    case 1 {
      $entry->{Orientation} = 1;
      $entry->{MapQ} = $R1_aln->qual;
      $entry->{Rname} = $R1_aln->seq_id;
      $entry->{Strand} = $R1_aln->strand;
      $entry->{Rstart} = $R1_aln->strand == 1 ? $R1_aln->start : $R2_aln->start;
      $entry->{Rend} = $R1_aln->strand == 1 ? $R2_aln->end : $R1_aln->end;
      $entry->{Junction} = $entry->{Strand} == 1 ? $entry->{Rstart} : $entry->{Rend};


      my $left = substr($R1_brk_aln->query->seq->seq,0,$R1_Qstart - 1);
      my $mid = merge_alignments($R1_aln,$R2_aln,$sam);
      $mid = $entry->{Strand} == 1 ? $mid : reverseComplement($mid);
      my $right = substr($R2_brk_aln->query->seq->seq,$R2_Qend);
      $entry->{Seq} = $left . $mid . $right;
      $entry->{Qlen} = length($entry->{Seq});

      $entry->{BrkRstart} = $R1_brk_aln->start;
      $entry->{BrkQstart} = $R1_BrkQstart;

      if ($R2_brk_aln->end > $R1_brk_aln->end) {
        $entry->{BrkRend} = $R2_brk_aln->end;

        if ($R1_aln->strand == 1) {
          $entry->{BrkQend} = $R1_Qstart + ( $R2_aln->start - $R1_aln->start ) - ( $R2_Qstart - $R2_BrkQend );
        } else {
          $entry->{BrkQend} = $R1_Qstart + ( $R1_aln->end - $R2_aln->end ) - ( $R2_Qstart - $R2_BrkQend );
        }

      } else {
        $entry->{BrkRend} = $R1_brk_aln->end;
        $entry->{BrkQend} = $R1_BrkQend;
      }
   
      $entry->{Qstart} = length($left) + 1;
      $entry->{Qend} = length($left.$mid);

    }

    case 2 {
      $entry->{Orientation} = 2;
      $entry->{MapQ} = $R1_aln->qual;
      $entry->{Rname} = $R1_aln->seq_id;
      $entry->{Strand} = $R1_aln->strand;
      $entry->{Rstart} = $R1_aln->strand == 1 ? $R1_aln->start : $R2_aln->start;
      $entry->{Rend} = $R1_aln->strand == 1 ? $R2_aln->end : $R1_aln->end;
      $entry->{Junction} = $entry->{Strand} == 1 ? $entry->{Rstart} : $entry->{Rend};



      my $left = substr($R1_brk_aln->query->seq->seq,0,$R1_Qstart - 1);
      my $mid = merge_alignments($R1_aln,$R2_aln,$sam);
      $mid = $entry->{Strand} == 1 ? $mid : reverseComplement($mid);
      my $right = substr(reverseComplement($R2_brk_aln->query->seq->seq),$R2_Qend);
      $entry->{Seq} = $left . $mid . $right;
      $entry->{Qlen} = length($entry->{Seq});



      $entry->{BrkRstart} = $R1_brk_aln->start;
      $entry->{BrkRend} = $R1_brk_aln->end;
      $entry->{BrkQstart} = $R1_BrkQstart;
      $entry->{BrkQend} = $R1_BrkQend;
      $entry->{Qstart} = length($left) + 1;
      $entry->{Qend} = length($left.$mid);

    }

    case 3 {
      $entry->{Orientation} = 3;
      $entry->{MapQ} = $R2_aln->qual;
      $entry->{Rname} = $R2_aln->seq_id;
      $entry->{Strand} = $R2_aln->strand * -1;
      $entry->{Rstart} = $R2_aln->start;
      $entry->{Rend} = $R2_aln->end;
      $entry->{Junction} = $entry->{Strand} == 1 ? $entry->{Rstart} : $entry->{Rend};


      my $left = substr($R1_brk_aln->query->seq->seq,0,$R1_BrkQstart - 1);
      my $mid = sw_align_pairs($R1_brk_aln,$R2_brk_aln,$tmpdir);
      $mid = merge_alignments($R1_brk_aln,$R2_brk_aln,$sam_brk) if $mid eq "";
      my $right = substr($R2_brk_aln->query->seq->seq,$R2_BrkQend);

      $entry->{Seq} = $left . $mid . $right;
      $entry->{Qlen} = length($entry->{Seq});


      $entry->{BrkRstart} = $R1_brk_aln->start;
      $entry->{BrkQstart} = $R1_BrkQstart;

      $entry->{BrkRend} = $R2_brk_aln->end;
      $entry->{BrkQend} = length($left.$mid);
   
      $entry->{Qstart} = $entry->{BrkQend} + $R2_Qstart - $R2_BrkQend;
      $entry->{Qend} = $entry->{BrkQend} + $R2_Qend - $R2_BrkQend;


    }

    case 4 {
      $entry->{Orientation} = 4;
      $entry->{MapQ} = $R1_aln->qual;
      $entry->{Rname} = $R1_aln->seq_id;
      $entry->{Strand} = $R1_aln->strand;
      $entry->{Rstart} = $R1_aln->start;
      $entry->{Rend} = $R1_aln->end;
      $entry->{Junction} = $entry->{Strand} == 1 ? $entry->{Rstart} : $entry->{Rend};

      $entry->{Seq} = $R1_brk_aln->query->seq->seq;
      $entry->{BrkRstart} = $R1_brk_aln->start;
      $entry->{BrkQstart} = $R1_BrkQstart;
      $entry->{BrkRend} = $R1_brk_aln->end;
      $entry->{BrkQend} = $R1_BrkQend;
      $entry->{Qstart} = $R1_Qstart;
      $entry->{Qend} = $R1_Qend;
    }

  }

  $fh->print(join("\t",map(check_undef($_,""),@{$entry}{@tlx_header}))."\n");

}

sub create_tlxl_entry ($$$$$) {
  my $fh = shift;
  my $aln = shift;
  my $R1_brk_aln = shift;
  my $R2_brk_aln = shift;
  my $filter = shift;

  my $R1_aln = $aln->{R1_aln};
  my $R2_aln = $aln->{R2_aln};


  my @tlxl_header = tlxl_header();

  my $entry = {};

  $entry->{Qname} = $R1_brk_aln->query->name;
  $entry->{Filter} = $filter if defined $filter;
  $entry->{R1_seq} = $R1_brk_aln->query->seq->seq;
  $entry->{R2_seq} = $R2_brk_aln->reversed ? $R2_brk_aln->query->seq->seq : reverseComplement($R2_brk_aln->query->seq->seq);


  unless ($R1_brk_aln->unmapped) {
    $entry->{R1_BrkQstart} = $R1_brk_aln->query->start;
    $entry->{R1_BrkQend} = $R1_brk_aln->query->end;
    $entry->{R1_BrkRstart} = $R1_brk_aln->start;
    $entry->{R1_BrkRend} = $R1_brk_aln->end;
    $entry->{R1_BrkCigar} = $R1_brk_aln->cigar_str;
  }
  unless ($R2_brk_aln->unmapped) {
    $entry->{R2_BrkQstart} = $R2_brk_aln->query->start;
    $entry->{R2_BrkQend} = $R2_brk_aln->query->end;
    $entry->{R2_BrkRstart} = $R2_brk_aln->start;
    $entry->{R2_BrkRend} = $R2_brk_aln->end;
    $entry->{R2_BrkCigar} = $R2_brk_aln->cigar_str;
  }

  if (defined $R1_aln) {
    $entry->{Rname} = $R1_aln->seq_id;
    $entry->{Strand} = $R1_aln->strand;
    $entry->{MapQ} = $R1_aln->qual;

    $entry->{R1_Qstart} = $R1_aln->reversed ? $R1_aln->l_qseq - $R1_aln->query->end + 1 : $R1_aln->query->start;
    $entry->{R1_Qend} = $R1_aln->reversed ? $R1_aln->l_qseq - $R1_aln->query->start + 1 : $R1_aln->query->end;
    $entry->{R1_Rstart} = $R1_aln->start;
    $entry->{R1_Rend} = $R1_aln->end;
    $entry->{R1_Cigar} = $R1_aln->cigar_str;
  }

  if (defined $R2_aln) {
    if ($R2_aln->munmapped) {
      $entry->{Rname} = $R2_aln->seq_id;
      $entry->{Strand} = -1 * $R2_aln->strand;
      $entry->{MapQ} = $R2_aln->qual;
    }

    unless (defined $R1_aln && ! $R1_aln->proper_pair) {
      $entry->{R2_Qstart} = $R2_aln->reversed ? $R2_aln->query->start : $R2_aln->l_qseq - $R2_aln->query->end + 1;
      $entry->{R2_Qend} = $R2_aln->reversed ? $R2_aln->query->end : $R2_aln->l_qseq - $R2_aln->query->start + 1;
      $entry->{R2_Rstart} = $R2_aln->start;
      $entry->{R2_Rend} = $R2_aln->end;
      $entry->{R2_Cigar} = $R2_aln->cigar_str;
    }
  }

  $fh->print(join("\t",map(check_undef($_,""),@{$entry}{@tlxl_header}))."\n");


}

sub parse_command_line {
	my $help;

	usage() if (scalar @ARGV == 0);

	my $result = GetOptions ( "read1=s" => \$read1,
                            "read2=s" => \$read2,
                            "assembly=s" => \$assembly,
                            "workdir=s" => \$workdir,
                            "threads=i" => \$threads,
                            "bt2opt=s" => \$user_bowtie_opt,
                            "bt2brkopt=s" => \$user_bowtie_breaksite_opt,
				            				"help" => \$help
				            			) ;
	
	usage() if ($help);

  #Check options

  croak "Error: cannot read sequence files" unless (-r $read1 & -r $read2);
  croak "Error: working directory does not exist" unless (-d $workdir);
  



	exit unless $result;
}


sub usage()
{
print<<EOF;
Title, by Robin Meyers, ddmonthyyyy

This program .


Usage: $0 arg1 arg2 arg3 ...
        [--option VAL] [--flag] [--help]

Arguments (defaults in parentheses):

$arg{"--read1","Input sequence file"}
$arg{"--read2","Input sequence file"}
$arg{"--workdir","Directory for results files - note: default Bowtie output goes to working directory"}
$arg{"--assembly","Genome assembly to align reads to"}
$arg{"--threads","Number of threads to run bowtie on","$threads"}
$arg{"--help","This helpful help screen."}


EOF

exit 1;
}
