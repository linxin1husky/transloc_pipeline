
<br>

*Under New Construction! (Fall 2024)* 

Robin Meyers originally wrote this pipeline. Xin Lin is now the editor of the new version.

<br>

# Installation

<br>

## Get The Code

Either visit our [download](download.html) page or clone our git repo.

```
$ git clone https://github.com/robinmeyers/transloc_pipeline.git
```

Add directories to $PATH in `~/.profile` or `~/.bash_profile`

```
$ echo 'export PATH=~/transloc_pipeline/bin:~/transloc_pipeline/R:$PATH' >> ~/.bash_profile
```

<br>

## Reference Genomes

The pipeline requires both a fasta file and a bowtie2 index of your reference genome. The pipeline will search for these elements in the locations specified by two environment variables: `$GENOME_DB` and `$BOWTIE2_INDEXES`. The pipeline will throw an error if it cannot find the bowtie2 index files at `$BOWTIE2_INDEXES/<reference id>` and the genome fasta at `$GENOME_DB/<reference id>/<reference id>.fa`.

First decide on your paths (e.g. `~/genomes` or `/usr/local/genomes` for `$GENOME_DB`) and then add required environment variables to in `~/.profile` or `~/.bash_profile`

```
$ echo 'export GENOME_DB=~/genomes' >> ~/.bash_profile
$ echo 'export BOWTIE2_INDEXES=~/genomes/bowtie2_indexes' >> ~/.bash_profile
$ source ~/.bash_profile
```

The code below is one way to set up the pipeline to run against the *hg19* reference genome. Running this will take some time to download the bowtie2 index and write the fasta file.

```
$ mkdir -p $BOWTIE2_INDEXES
$ cd $BOWTIE2_INDEXES
$ wget ftp://ftp.ccb.jhu.edu/pub/data/bowtie2_indexes/hg19.zip
$ unzip hg19.zip
$ mkdir -p $GENOME_DB/hg19
$ bowtie2-inspect hg19 > $GENOME_DB/hg19/hg19.fa 
```

<br>

## Software Dependencies

There are lots. Sorry about that.

### Bowtie2

Install [Bowtie2](http://bowtie-bio.sourceforge.net/bowtie2/index.shtml)

If on OS X and using [homebrew](http://brew.sh/):

```
$ brew tap homebrew/science
$ brew install bowtie2
```

### Samtools

Install [Samtools](http://samtools.sourceforge.net/)

**IMPT:** The perl module that uses the samtools installation requires an older version of samtools. From the (README)[http://cpansearch.perl.org/src/LDS/Bio-SamTools-1.43/README], *"This is a Perl interface to the SAMtools sequence alignment
interface. It ONLY works on versions of Samtools up to 0.1.17. It does
not work on version 1.0 or higher due to major changes in the library
structure."*

### Perl >= 5.16

On **OS X**, I have had good success with the [ActivePerl](http://www.activestate.com/activeperl/downloads) distribution. [Perlbrew](http://perlbrew.pl/) is a good option for a **Linux** machine, especially without root access.

### Bioperl

Install [Bioperl](http://www.bioperl.org/wiki/Installing_BioPerl_on_Unix)

Open an interactive cpan shell:

```
$ cpan
```

Find the most recent version of bioperl:

```
cpan> d /bioperl/
Distribution    CJFIELDS/BioPerl-1.6.901.tar.gz
Distribution    CJFIELDS/BioPerl-1.6.923.tar.gz
Distribution    CJFIELDS/BioPerl-1.6.924.tar.gz
```

Now install:

```
cpan> install CJFIELDS/BioPerl-1.6.924.tar.gz
```
or
```
cpan> force install CJFIELDS/BioPerl-1.6.924.tar.gz
```

Other modules (all of which can be installed using cpan install commands)

```
cpan > install Getopt::Long Text::CSV List::MoreUtils Data::GUID Interpolation IPC::System::Simple Storable Switch::Plain
```

I have missed a few. Missing modules can be installed the same as above.

### SeqPrep

[SeqPrep](https://github.com/jstjohn/SeqPrep) is used in the pre-processing of the libraries.

```
$ git clone https://github.com/jstjohn/SeqPrep.git
$ cd SeqPrep
$ make
```
Then add SeqPrep to your `$PATH`.

### R >= 3.1.2

Download and install [R](https://cran.r-project.org/)

Load an R session:

```
$ R
```

Install required packages:

```
> install.packages(c("magrittr", "readr", "stringr", "plyr", "dplyr", "data.table", ))
> source("https://bioconductor.org/biocLite.R")
> biocLite(c("GenomicRanges", "BSGenome"))
```

<br>

***

<br>

# Running the Pipeline

<br>

## Download Sample Data

[Download .zip](https://github.com/robinmeyers/transloc_pipeline/zipball/tutorial-data)

or

```
$ git clone -b tutorial-data https://github.com/robinmeyers/transloc_pipeline.git tutorial_data
$ cd ./tutorial_data
```

## Pre-processing libraries

The Alt Lab primarily uses in-line barcodes (sequenced by the MiSeq at the head of the forward read) and then deconvolutes pooled libraries using this program. This script also calls an external tool to trim Illumina adapter sequence. If using Illumina multi-plex barcoding strategy, this script will not be useful except for trimming adapters, which is still recommended.

### Starting from pooled library fastq files
Deconvolutes and trims adapters
```
$ TranslocPreprocess.pl tutorial_metadata.txt preprocess/ --read1 pooled_R1.fq.gz --read2 pooled_R2.fq.gz
```

### Starting from deconvoluted fastq files
Just trims adapters
```
$ cd ~/transloc_pipeline/data
$ TranslocPreprocess.pl tutorial_metadata.txt preprocess/ --indir ./
```

## Running the pipeline

```
$ TranslocWrapper.pl tutorial_metadata.txt preprocess/ results/ --threads 2
```

<br>

***

<br>

# Post-processing

<br>

## Filtering

The TranslocPipeline main output is the *.tlx file. One master tlx file will be generated per library. It can be thought of as similar to a sam file for NGS libraries. It contains output for every read in the library, and will serve as the starting point for all down-stream analyses. However, for most analyses, it will need to be filtered into only the required reads for the specific analysis. There is a default filtering that the pipeline will generate automatically. For any other filtering regime, the user will have to re-filter the master tlx file.

### Available filters

**- unaligned:** No OCS alignments.

**- baitonly:** Bait alignment is either the only alignent in the OCS or  only followed by adapter alignment.

**- uncut:** Bait alignment runs greater than some number of bases past the cutsite.

**- misprimed:** Bait alignment runs fewer than some number of bases past the primer.

**- freqcut:** Restriction enzyme site within some number of bases from the junction. (Fairly depricated.)

**- largegap:** More than some number of bases between the bait and prey alignments.

**- mapqual:** OCS had a competing prey junction.

**- breaksite:** Prey alignment maps into non-endogenous breaksite cassette. (Fairly depricated.)

**- sequential:** Junction occurs downstream on read from first bait-prey junction.


### Re-filtering a library

```
$ TranslocFilter.pl results/RF204_Alt055/RF204_Alt055.tlx results/RF204_Alt055_refiltered.tlx --filters ""
```

#### Ex. 1 Keep duplicate junctions

```
$ TranslocFilter.pl results/RF204_Alt055/RF204_Alt055.tlx results/RF204_Alt055_refiltered.tlx --filters ""
```

#### Ex. 2 Keep all un-translocated reads

```
$ TranslocFilter.pl results/RF204_Alt055/RF204_Alt055.tlx results/RF204_Alt055_refiltered.tlx --filters ""
```

#### Using a config file

## Hotspot Detection

Two methods of detecting hotspots.

### Using MACS2 to do translocaiton peak detection

Must have MACS2 installed.

```
$ tlx2BED-MACS.pl
$ macs2
```

### Using scan statistics script to call peaks
```
$ TranslocHotspots.R
```

## Circos Plots

And other viz.

<br>

***

