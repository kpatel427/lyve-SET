#!/usr/bin/env perl

# Update paths
use FindBin qw/$RealBin/;
use lib "$FindBin::RealBin/../lib";
# Make sure the path is set up correctly but do not take priority 
# over what the user truly wants, as dictated by the already-existing path.
# This cannot be used as a solution if the user has the incorrect
# software version in the path (e.g., samtools 0.1.19)
#$ENV{PATH}="$ENV{PATH}:$FindBin::RealBin";
# Aw, screw it.  Force the path on the user.
$ENV{PATH}="$RealBin:$ENV{PATH}";

use strict;
use warnings;
use Bio::Perl;
use Data::Dumper;
use Getopt::Long;
use File::Basename;
use File::Spec;
use threads;
use Thread::Queue;
use Schedule::SGELK;
use Config::Simple;

use LyveSET qw/@fastaExt @fastqExt @bamExt/;

my ($name,$scriptsdir,$suffix)=fileparse($0);
$scriptsdir=File::Spec->rel2abs($scriptsdir);

# Logging
my $logmsgFh;
sub logmsg {
  local $0=basename $0;
  my $FH = *STDOUT; 
  my $msg="$0: ".(caller(1))[3].": @_\n";

  # print the message to the logfile if it's not the same as stdout
  #print join("\t","===",fileno($logmsgFh),fileno($FH))."\n";
  if(defined($logmsgFh) && fileno($logmsgFh) > 0){
    print $logmsgFh $msg;
  }
  print $FH $msg;
}
local $SIG{'__DIE__'} = sub { local $0=basename $0; my $e = $_[0]; $e =~ s/(at [^\s]+? line \d+\.$)/\nStopped $1/; my $msg="$0: ".(caller(1))[3].": ".$e; logmsg($msg);  die(); };
END{
  close $logmsgFh if(defined($logmsgFh) && fileno($logmsgFh) > 0);
}

my $sge=Schedule::SGELK->new(-verbose=>1,-numnodes=>20,-numcpus=>1);
exit(main());

sub main{
  # start with the settings that are on by default, and which can be turned off by, e.g., --notrees
  my $settings={trees=>1,msa=>1, matrix=>1};
  GetOptions($settings,qw(ref=s bamdir=s logdir=s vcfdir=s tmpdir=s readsdir=s asmdir=s msadir=s help numcpus=s numnodes=i allowedFlanking=s keep min_alt_frac=s min_coverage=i trees! queue=s qsubxopts=s msa! matrix! mapper=s snpcaller=s mask-phages! mask-cliffs! rename-taxa=s fast downsample sample-sites singleend presets=s read_cleaner=s)) or die $!;
  # TODO put these global options into LyveSET.conf, now that it exists
  # Lyve-SET
  $$settings{allowedFlanking}||=0;
  $$settings{keep}||=0;
  $$settings{min_alt_frac}||=0.75;
  $$settings{min_coverage}||=10;
  $$settings{'mask-phages'}=1 if(!defined($$settings{'mask-phages'}));
  $$settings{'mask-cliffs'}=1 if(!defined($$settings{'mask-cliffs'}));
  $$settings{'rename-taxa'}||="";
  $$settings{downsample}||=0;
  $$settings{'sample-sites'}||=0;
  $$settings{singleend}||=0;
  # modules defaults
  $$settings{read_cleaner}||="";
  $$settings{mapper}||="smalt";
  $$settings{snpcaller}||="varscan";
  # queue stuff
  $$settings{numcpus}||=1;
  $$settings{numnodes}||=20;
  $$settings{qsubxopts}||="";
  $$settings{queue}||="all.q";

  # What options change when --fast is used?
  if($$settings{fast}){
    $$settings{mapper}="snap";
    $$settings{'mask-phages'}=0;
    $$settings{'mask-cliffs'}=0;
    $$settings{downsample}=1;
    $$settings{'sample-sites'}=1;
  }

  # If the user wants to use preset configurations
  if($$settings{presets}){
    # Load the configuration
    my $confPath="$FindBin::RealBin/../config/presets.conf";
    my $cfg=new Config::Simple($confPath) or die "ERROR: could not open $confPath";
    # Find the configuration that was specified
    my $block=$cfg->block($$settings{presets});
    die "ERROR: configuration $$settings{presets} was not found in $confPath!" if(!keys(%$block));
    # Put the presets into the current settings
    $$settings{$_}=$$block{$_} for(keys(%$block));
  }

  # Some things need to just be lowercase to make things easier downstream
  $$settings{$_}=lc($$settings{$_}) for(qw(snpcaller mapper read_cleaner));

  ###########################################################
  ### Other defaults: reference genome; default directories #
  ###########################################################
  my $project=shift(@ARGV) || '.'; # by default the user is in the project directory
  die usage($settings) if($$settings{help});
  logmsg "Project was defined as $project";
  # Checks to make sure that this is a project
  #system("set_manage.pl '$project'"); die if $?;
  # Set the defaults if they aren't set already
  $$settings{ref}||="$project/reference/reference.fasta";
  $$settings{refdir}||=dirname($$settings{ref});
  # Check SET directories' existence and set their defaults
  die "ERROR: could not find dir $project" if(!-e $project);
  for my $param (qw(vcfdir bamdir msadir readsdir tmpdir asmdir logdir)){
    my $b=$param;
    $b=~s/dir$//;  # e.g., vcfdir => vcf
    $$settings{$param}||="$project/$b";
    die "ERROR: Could not find $param under $$settings{$param}/\n  mkdir $$settings{$param} to resolve this problem.\n".usage($settings) if(!-d $$settings{$param});
    $$settings{$param}=File::Spec->rel2abs($$settings{$param});
  }

  # SGE params
  $$settings{workingdir}=$$settings{logdir};
  for (qw(workingdir numnodes numcpus keep qsubxopts queue)){
    $sge->set($_,$$settings{$_}) if($$settings{$_});
  }

  # open the log file now that we know the logdir is there
  open($logmsgFh,">$$settings{logdir}/launch_set.log") or die "ERROR: could not open log file $$settings{logdir}/launch_set.log";
  logmsg "======\nOpened logfile at $$settings{logdir}/launch_set.log\n=====";

  # Check the reference parameter
  die "ERROR: reference file was not given\n".usage($settings) if(!defined($$settings{ref}));
  die "ERROR: Could not find the reference file at $$settings{ref}\n".usage($settings) if(!-f $$settings{ref});
  my $ref=$$settings{ref};

  #####################################
  # Go through the major steps of SET #
  # ###################################
  $settings=readGlobalSettings(0,$settings);
  simulateReads($settings);
  maskReference($ref,$settings);
  indexReference($ref,$settings);
  mapReads($ref,$$settings{readsdir},$$settings{bamdir},$settings);
  variantCalls($ref,$$settings{bamdir},$$settings{vcfdir},$settings);

  # TODO put all the tree-making stuff into its own subroutine too
  my $pooled;
  if($$settings{matrix}){
    $pooled=variantsToMatrix($ref,$$settings{bamdir},$$settings{vcfdir},$$settings{msadir},$settings);
  } else {
    logmsg "The matrix was not requested; wrapping up";
    return 0;
  }

  if($$settings{msa}){
    pooledToAlignment($pooled,$settings);
  } else {
    logmsg "The alignment was not requested; wrapping up";
    return 0;
  }

  if($$settings{trees}){
    logmsg "Launching set_processMsa.pl";
    my $regexParam="";
    if($$settings{'rename-taxa'}){
      $regexParam="--rename-taxa ".$$settings{'rename-taxa'};
    }
    my $command="set_processMsa.pl --auto $regexParam --msaDir '$$settings{msadir}' --numcpus $$settings{numcpus} 2>&1 | tee $$settings{logdir}/set_processMsa.log ";
    logmsg "Processing the MSA\n  $command";
    $sge->pleaseExecute($command,{numcpus=>$$settings{numcpus},jobname=>"set_processMsa.pl"});
    $sge->wrapItUp();
  } else {
    logmsg "The phylogeny was not requested; wrapping up";
    return 0;
  }

  return 0;
}

# Pick information about SET from the Makefile where it is stored.
# If overwrite is set to true, then existing settings will be 
# overwritten. Otherwise, settings will be applied if no other
# value was there beforehand.
sub readGlobalSettings{
  my($overwrite,$settings)=@_;
  # make a copy of settings to avoid ridiculousness
  my %settingsCopy=%$settings;

  my $confPath="$FindBin::RealBin/../config/LyveSET.conf";
  my $cfg=new Config::Simple($confPath) or die "ERROR: could not open $confPath";
  # Find the configuration that was specified
  my $block=$cfg->block("global");
  die "ERROR: configuration [global] was not found in $confPath!" if(!keys(%$block));
  # Put the presets into the current settings
  for(keys(%$block)){
    if($overwrite){
      $settingsCopy{$_}=$$block{$_};
    } else {
      $settingsCopy{$_}=$$block{$_} if(!$settingsCopy{$_});
    }
  }

  return \%settingsCopy;
}

sub simulateReads{
  my($settings)=@_;
  logmsg "Simulating reads from any assemblies";
  my @asm=glob("$$settings{asmdir}/*.{fasta,fna,ffn,fa,mfa,mfasta}");
  return if(!@asm);

  my $exec=`which wgsim`;
  die "ERROR: Could not find wgsim which is part of samtools" if $?;
  chomp($exec);

  for my $asm (@asm){
    my $b=fileparse $asm;
    my $outFastq="$$settings{readsdir}/$b.wgsim.fastq";
    my $outGz="$outFastq.gz";
    my $out1="$$settings{tmpdir}/$b.1.fastq";
    my $out2="$$settings{tmpdir}/$b.2.fastq";
    next if(-e $outGz && !-e $outFastq); 
    logmsg "I did not find $outFastq simulated reads. Simulating now with $exec.";

    # How many simulated reads should there be with a reasonable coverage?
    my $coverage=100;
    my $readLength=250;
    my $approximateGenomeSize = (-s $asm); # estimate based on file size
    if($approximateGenomeSize < $readLength){
      logmsg "WARNING: I am not simulating reads from $asm because it is too small";
      next;
    }
    my $numReads=$approximateGenomeSize * 100 / ($readLength*2);
    
    # Four successive jobs that depend on each other:
    #   1. Simulate into paired ends
    #   2. Shuffle
    #   3. Gzip
    #   4. Remove simulated unshuffled reads (depends on the shuffle step and not gzip)
    $sge->pleaseExecute("$exec -d 400 -N $numReads -1 $readLength -2 $readLength -e 0.0 -r 0.0 -R 0.0000 -h '$asm' $out1 $out2 && run_assembly_shuffleReads.pl $out1 $out2 > $outFastq && gzip -v '$outFastq' 2>&1 && rm -v $out1 $out2", {jobname=>"simulate$b",numcpus=>1});
  }
  $sge->wrapItUp();
}

sub maskReference{
  my($ref,$settings)=@_;

  # Make the directory where these masking coordinates go
  my $maskDir="$$settings{refdir}/maskedRegions";
  mkdir($maskDir) if(!-d $maskDir);
  logmsg "Finding regions to mask, and recording them in $maskDir/*";
  
  # Mark phage locations if they haven't already been marked
  my $phageRegions="$maskDir/phages.bed";
  if($$settings{'mask-phages'} && !-e $phageRegions){
    logmsg "Masking the reference genome for phages";
    $sge->pleaseExecute("set_findPhages.pl --numcpus $$settings{numcpus} $ref > $phageRegions.tmp && mv -v $phageRegions.tmp $phageRegions",{numcpus=>$$settings{numcpus},jobname=>"set_findPhages"});
  }

  $sge->wrapItUp();

  logmsg "DONE with finding regions to mask";
  # END: finding regions to mask
  ##############################

  #########################
  # Find out which regions should be kept in the final pileups
  # and mark it as such in a final file.

  logmsg "Creating a unique list of coordinates to mask";
  # Find out how long each sequence is first.
  my $in=Bio::SeqIO->new(-file=>$ref);
  my %seqLength;
  while(my $seq=$in->next_seq){
    $seqLength{$seq->id}=$seq->length;
  }
  
  # Find out what the masked regions are in each bed file
  # and find a union of all masked regions, ie, a unique set of points.
  my %points;
  for my $bed(glob("$maskDir/*.bed")){
    open(BED,$bed) or die "ERROR: could not open $bed for reading: $!";
    while(<BED>){
      chomp;
      my($contig,$start,$stop)=split /\t/;
      for my $pos($start..$stop){
        $points{$contig}{$pos}=1;
      }
    }
    close BED;
  }
  # TODO use Number::Range here.

  # Change the unique points to ranges
  my @masked; 
  my $maskedRegions="$$settings{refdir}/maskedRegions.bed";
  open(MASKEDBED,">$maskedRegions") or die "ERROR: could not open $maskedRegions: $!";
  while(my($contig,$positions)=each(%points)){
    # Change the list to a range
    # http://www.perlmonks.org/?node_id=87538
    my $strList=integersToRange(keys(%$positions));
    while($strList=~/(\d+)\-(\d+)/g){
      print MASKEDBED join("\t",$contig,$1,$2)."\n";
      push(@masked,[$contig,$1,$2]);
    }
  }
  close MASKEDBED;

  # invert the coordinates
  my %unmaskedPoints;
  my $unmaskedRegions="$$settings{refdir}/unmaskedRegions.bed";
  open(UNMASKEDBED,">$unmaskedRegions") or die "ERROR: could not open $unmaskedRegions: $!";
  while(my($contig,$positions)=each(%points)){
    # Find the inverse by finding which coordinates of the contig
    # do not show up in the original masked datapoints.
    my @inverse=sort{$a<=>$b} grep{!$$positions{$_}} (0..$seqLength{$contig}-1);
    my %inverse;
    @inverse{@inverse}=(1) x @inverse;
    $unmaskedPoints{$contig}=\%inverse;
    my $unmaskedPointsStr=integersToRange(keys(%{$unmaskedPoints{$contig}}));
    while($unmaskedPointsStr=~/(\d+)\-(\d+)/g){
      print UNMASKEDBED join("\t",$contig,$1,$2)."\n";
    }
  }
  close UNMASKEDBED;

  logmsg "Inverted masked regions from $maskedRegions and put them into $unmaskedRegions";
  logmsg "I now know where 'good' regions are, as they are listed in $unmaskedRegions.";

  return $unmaskedRegions;
}

sub integersToRange{
  my @sorted=sort({$a<=>$b} @_);
  my $str=join(",",@sorted); # comma-separated
  $str=~s/(?<!\d)(\d+)(?:,((??{$++1}))){1,32766}(?!\d)/$1-$+/g; # range format
  return $str;
}

sub indexReference{
  my($ref,$settings)=@_;
  logmsg "Indexing the reference for read mapping";

  # sanity check: see if the reference has reserved characters
  my $in=Bio::SeqIO->new(-file=>$ref);
  while(my $seq=$in->next_seq){
    my $defline=$seq->id." ".$seq->desc;
    die "Offending character found in the defline\n $defline\n $1" if($defline=~/([\:])/);
  }

  logmsg "Indexing with $$settings{mapper}";
  if($$settings{mapper} eq 'smalt'){
    return $ref if(-e "$ref.sma" && -e "$ref.smi");
    system("smalt index -k 13 -s 2 $ref $ref 2>&1");
    die if $?;
  } elsif($$settings{mapper} eq 'snap'){
    return $ref if(-d "$ref.snap" && -e "$ref.snap/GenomeIndex");
    # -bSpace to make sure the deflines match up with what samtools expects
    # -exact -large to take the time to make a fast but somewhat smaller db
    # Must specify the number of CPUs or else it greedily takes them all instead of what the user specifies
    system("snap index $ref $ref.snap -exact -large -bSpace -t$$settings{numcpus}");
    die if $?;
  }
  return $ref;
}

sub mapReads{
  my($ref,$readsdir,$bamdir,$settings)=@_;

  logmsg "Mapping reads with $$settings{mapper}";
  $sge->set("numcpus",$$settings{numcpus});
  my $tmpdir=$$settings{tmpdir};
  my $log=$$settings{logdir};
  my @file=(glob("$readsdir/*.fastq"),glob("$readsdir/*.fastq.gz"),glob("$readsdir/*.fq"),glob("$readsdir/*.fq.gz"));

  if(!@file){
    logmsg "ERROR: no files were found in $readsdir/. However, in case you are continuing Lyve-SET after all the bam files have already been created and you just happened to delete all the input files, I will continue";
    return 0;
  }

  downsampleReads($ref,\@file,$settings) if($$settings{downsample});
  cleanReads(\@file,$settings) if($$settings{read_cleaner});

  my $snapxopts="";
  my $smaltxopts="";
  if($$settings{singleend}){
    $smaltxopts.="--pairedend 1";
    $snapxopts.= "--pairedend 1";
  }

  my (@bam,@job);
  for my $fastq(@file){
    my $b=fileparse $fastq;
    my $bamPrefix="$bamdir/$b-".basename($ref,@fastaExt);
    push(@bam,"$bamPrefix.sorted.bam");

    if(-e "$bamPrefix.sorted.bam"){
      logmsg "Found $bamPrefix.sorted.bam. Skipping.";
      next;
    }else{
      logmsg "Mapping to create $bamPrefix.sorted.bam";
    }

    if($$settings{mapper} eq 'smalt'){
      $sge->pleaseExecute("$scriptsdir/launch_smalt.pl $smaltxopts -ref $ref -f $fastq -b $bamPrefix.sorted.bam -tempdir $tmpdir --numcpus $$settings{numcpus} ",{jobname=>"smalt$b"});
    } elsif($$settings{mapper} eq 'snap'){
      $sge->pleaseExecute("$scriptsdir/launch_snap.pl $snapxopts -ref $ref -f $fastq -b $bamPrefix.sorted.bam -tempdir $tmpdir --numcpus $$settings{numcpus} ",{jobname=>"snap$b"});
    } else {
      die "ERROR: I do not understand the mapper $$settings{mapper}";
    }
  }
  logmsg "All mapping jobs have been submitted. Waiting on them to finish.";
  $sge->wrapItUp();

  # Look for cliffs in coverage levels
  if($$settings{'mask-cliffs'}){
    # Make the directory where these masking coordinates go
    my $maskDir="$$settings{refdir}/maskedRegions";
    mkdir($maskDir) if(!-d $maskDir);
    logmsg "Finding regions to mask, and recording them in $maskDir/*";

    for my $bam(@bam){
      my $b=basename($bam,@bamExt);
      my $bed="$maskDir/$b.cliffs.bed";
      next if(-e $bed);
      $sge->pleaseExecute("$scriptsdir/set_findCliffs.pl --numcpus $$settings{numcpus} $bam > $bed",{jobname=>"maskCliff$b",numcpus=>$$settings{numcpus}});
    }
    $sge->wrapItUp();
  }

  return 1;
}

sub downsampleReads{
  my($ref,$reads,$settings)=@_;
  my $coverage=50;
  my $reducedBases=(-s $ref) * $coverage;
  logmsg "Downsampling the reads to ${coverage}x.";
  for my $file(@$reads){
    # downsample into tmpdir
    # move the original reads to "$file.orig"
    my $b=basename($file,qw(.cleaned.fastq.gz .downsampled.fastq.gz),@fastqExt);
    my $d=dirname($file);
    my $backupDir="$d/notDownsampled";
    mkdir($backupDir);
    my $backup="$backupDir/$b.fastq.gz";
    next if(-e $backup);
    logmsg "Did not find $backup. Downsampling...";
    # 1. Downsample to file.downsampled
    # 2. Mv un-downsampled file to file.orig
    # 3. Mv file.downsampled to file
    $sge->pleaseExecute("run_assembly_removeDuplicateReads.pl -size $reducedBases $file | gzip -c > $file.downsampled && mv -v $file $backup && mv -v $file.downsampled $file",{numcpus=>1,jobname=>"downsample$b"});
  }
  $sge->wrapItUp();
}

sub cleanReads{
  my($reads,$settings)=@_;
  for my $file(@$reads){
    # Clean into tmpdir
    # move the original reads to "$file.orig"
    my $b=basename($file,qw(.cleaned.fastq.gz .downsampled.fastq.gz), @fastqExt);
    my $d=dirname($file);
    my $backupDir="$d/notCleaned";
    mkdir($backupDir);
    my $backup="$backupDir/$b.fastq.gz";
    my $tmp="$$settings{tmpdir}/$b.fastq.gz";
    next if(-e $backup);
    # 1. Clean to tmp/cleaned
    # 2. Mv uncleaned to backup/file.fastq.gz
    # 3. mv tmp/cleaned to ./file.fastq.gz
    if($$settings{read_cleaner} eq "cgp"){
      logmsg "Did not find $backup. Cleaning with CGP...";
      $sge->pleaseExecute("run_assembly_trimClean.pl -i $file -o $tmp --auto --nosingletons --numcpus $$settings{numcpus} 2>&1 && mv -v $file $backup && mv -v $tmp $file",{numcpus=>$$settings{numcpus},jobname=>"clean$b"});
    } elsif($$settings{read_cleaner} eq "bayeshammer"){
      logmsg "Did not find $backup. Cleaning with BayesHammer...";
      die "Bayeshammer not implemented";
      #...;
    } else {
      logmsg "ERROR: I do not understand the read cleaner $$settings{read_cleaner}";
      die;
    }
  }
  $sge->wrapItUp();
}

sub variantCalls{
  my($ref,$bamdir,$vcfdir,$settings)=@_;
  logmsg "Calling variants with $$settings{snpcaller}";
  my @bam=glob("$bamdir/*.sorted.bam");

  if(!@bam){
    logmsg "ERROR: no bam files were found in $bamdir/. However, in case you are continuing Lyve-SET after all the vcf files have already been created and you just happened to delete all the bam files, I will continue";
    return 0;
  }

  # see if bgzip and tabix exist
  my $bgzip=`which bgzip 2>/dev/null`; chomp($bgzip);
  my $tabix=`which tabix 2>/dev/null`; chomp($tabix);

  # If --fast is given, choose a genome. Find possible 
  # variant sites in that genome and use those regions 
  # for the next SNP-calling instances.
  my $regionsFile="";
  if($$settings{'sample-sites'}){
    logmsg "--sample-sites was specified: finding initial variant sites to make the downstream SNP calling faster. First, need to find most distant genome using kmers and jaccard distance";

    # Find the most different set of reads
    for(my $i=0;$i<@bam;$i++){
      for(my $j=$i+1;$j<@bam;$j++){
        my $tmpName="$$settings{tmpdir}/".join("_","genomeDist",$i,$j,".tmp");
        $sge->pleaseExecute("$scriptsdir/genomeDist.pl -n 1 $bam[$i] $bam[$j] > $tmpName",{numcpus=>1,jobname=>"genomeDist"});
      }
    }
    $sge->wrapItUp();
    
    # Figure out the most distant using sums of points.
    my %distance;
    open(SORTALLGENOMEDIST,"sort -k3,3n -k1,1 -k2,2 $$settings{tmpdir}/genomeDist*.tmp | ") or die "ERROR: could not open  $$settings{tmpdir}/genomeDist*.tmp: $!";
    while(<SORTALLGENOMEDIST>){
      chomp;
      my($bam1,$bam2,$d)=split /\t/;
      $distance{$bam1}+=$d;
      $distance{$bam2}+=$d;
    }
    close SORTALLGENOMEDIST;
    
    # The most distant genome is the one with the lowest jaccard distance overall.
    my $initBam=$bam[0];
    my $minScore=$distance{$initBam};
    for my $b(@bam){
      if($distance{$b} < $minScore){
        $minScore=$distance{$b};
        $initBam=$b;
      }
    }
    logmsg "The most distantly related by jaccard distance is $initBam.";
    system("rm -vf $$settings{tmpdir}/genomeDist*.tmp");

    # This complicated command does multithreaded samtools mpileup
    # using xargs and one cpu per contig.
    # https://www.biostars.org/p/48781/#48815
    $regionsFile="$$settings{tmpdir}/initialSnpSites.bed";
    if(!-e $regionsFile){
      system("rm -fv $regionsFile.*.tmp");
      my $command="samtools view -H $initBam | grep \"\@SQ\" | sed 's/^.*SN://g' | cut -f 1 | xargs -I {} -n 1 -P $$settings{numcpus} sh -c \"samtools mpileup -uf $ref -r '{}' $initBam | bcftools call -cv | grep -v '^#' | cut -f 1,2 > $regionsFile.'{}'.tmp \" ";
      $sge->pleaseExecute($command,{numcpus=>$$settings{numcpus},jobname=>"snpPositionDiscovery"});
      $sge->wrapItUp();

      system("sort -k1,1 -k2,2n $regionsFile.*.tmp | uniq | grep . > $regionsFile && rm -v $regionsFile.*.tmp");
      die if $?;
    }
  }

  # TODO make the variant callers output to bgzip and indexed files
  for my $bam(@bam){
    my $b=fileparse($bam,".sorted.bam");
    if(-e "$vcfdir/$b.vcf" || -e "$vcfdir/$b.vcf.gz"){
      logmsg "Found $vcfdir/$b.vcf. Skipping";
      next;
    }
    logmsg "Calling SNPs into $vcfdir/$b.vcf";
    my $jobname=""; # the job that the filter/sort scripts are waiting for
    if($$settings{snpcaller} eq 'varscan'){
      $jobname="varscan$b";
      my $varscanxopts="";
      $varscanxopts.="--region $regionsFile " if($regionsFile);
      $sge->pleaseExecute("$scriptsdir/launch_varscan.pl $bam --tempdir $$settings{tmpdir} --reference $ref --altfreq $$settings{min_alt_frac} --coverage $$settings{min_coverage} $varscanxopts > $vcfdir/$b.vcf",{numcpus=>1,jobname=>$jobname,qsubxopts=>""});
      # sort VCF
      $sge->pleaseExecute("mv $vcfdir/$b.vcf $vcfdir/$b.vcf.tmp && vcf-sort < $vcfdir/$b.vcf.tmp > $vcfdir/$b.vcf && rm -v $vcfdir/$b.vcf.tmp",{jobname=>"sort$b",qsubxopts=>"-hold_jid $jobname",numcpus=>1});
      $jobname="sort$b"; # the thing that bgzip waits on to finish
    #} elsif($$settings{snpcaller} eq 'freebayes'){
    #  $jobname="freebayes$b";
    #  $sge->pleaseExecute("$scriptsdir/launch_freebayes.sh $ref $bam $vcfdir/$b.vcf $$settings{min_alt_frac} $$settings{min_coverage}",{numcpus=>1,jobname=>$jobname});
    } else {
      die "ERROR: I do not understand snpcaller $$settings{snpcaller}";
    }

    # TODO move filtering here
    # TODO can bcftools query take care of filtering instead?

    # bgzip and tabix indexing
    indexAndCompressVcf("$vcfdir/$b.vcf",$jobname,$settings);

  } # END bam while loop
  logmsg "All variant-calling jobs have been submitted. Waiting on them to finish";
  $sge->wrapItUp();
  return 1;
}

# returns the last SGE job information in a hash ref
sub indexAndCompressVcf{
  my($vcf,$holdjid,$settings)=@_;
  my $j={};
  eval{
    $j=$sge->pleaseExecute("
      vcf-sort < '$vcf' > '$vcf.sorted.tmp' && mv '$vcf.sorted.tmp' '$vcf' && \
      bgzip -f '$vcf' && \
      tabix '$vcf.gz'
    ",{qsubxopts=>"-hold_jid $holdjid",jobname=>"sortAndCompress",numcpus=>1});
  };
  if($@){
    logmsg "Warning: Could not compress and index $vcf: $@\n  See if bgzip and tabix are both installed correctly.";
    die;
  }
  return $j;
}

sub variantsToMatrix{
  my ($ref,$bamdir,$vcfdir,$msadir,$settings)=@_;
  logmsg "Creating a core hqSNP matrix";
  my $logdir=$$settings{logdir};

  my $matrix="$msadir/out.matrix.tsv";
  my $pooled="$msadir/out.pooled.vcf.gz";
  if(-e $pooled){
    logmsg "Found $pooled -- already present. Not re-converting.";
    return $pooled;
  }

  # input files
  my @vcf=glob("$vcfdir/*.vcf.gz");
  my @bam=glob("$bamdir/*.sorted.bam");
  my @infile=(@bam,@vcf);
  my $infile="'".join("' '",@infile)."'";
  my $inVcf="'".join("' '",@vcf)."'";

  # Find the distance that we'd expect SNP-linkage, so that they can be filtered out
  #if($$settings{allowedFlanking} eq 'auto'){
  #  my $allowedFlanking=`snpDistribution.pl @vcf`;
  #  die if $?;
  #  chomp($allowedFlanking);
  #
  #  # let's make it a little bit more strict actually.
  #  $$settings{allowedFlanking}=$allowedFlanking*3;
  #}

  $sge->pleaseExecute("mergeVcf.sh -o $pooled $inVcf",{jobname=>"poolVcfs",numcpus=>1});
  $sge->wrapItUp();

  return $pooled;
}

sub pooledToAlignment{
  my($pooled,$settings)=@_;
  $$settings{allowedFlanking}||=0;
  my $outMsa="$$settings{msadir}/out.aln.fas";
  if(-e $outMsa){
    logmsg "Found $outMsa and so I will not remake it";
    return $outMsa;
  }

  # Make in order: bcftools matrix; filtered matrix; fasta alignment
  $sge->pleaseExecute("pooledToMatrix.sh -o $$settings{msadir}/out.bcftoolsquery.tsv $$settings{msadir}/out.pooled.vcf.gz",{jobname=>"pooledToMatrix",numcpus=>1});
  $sge->pleaseExecute("filterMatrix.pl --allowed $$settings{allowedFlanking} --tempdir $$settings{tmpdir} $$settings{msadir}/out.bcftoolsquery.tsv > $$settings{msadir}/out.filteredbcftoolsquery.tsv",{jobname=>"filterMatrix",numcpus=>1,qsubxopts=>"-hold_jid pooledToMatrix"});
  $sge->pleaseExecute("matrixToAlignment.pl $$settings{msadir}/out.filteredbcftoolsquery.tsv > $$settings{msadir}/out.aln.fas",{jobname=>"matrixToAlignment",numcpus=>1,qsubxopts=>"-hold_jid filterMatrix"});
  $sge->wrapItUp();

  return $outMsa;
}

sub usage{
  my($settings)=@_;

  ## Format a few variables correctly
  # simplified pathnames for some options
  my @dir=qw(asmdir msadir readsdir bamdir vcfdir tmpdir logdir);
  $$settings{$_}=File::Spec->abs2rel($_).'/' for(@dir);
  # right padding for some options
  $$settings{$_}=reverse(sprintf("%15s","".reverse($$settings{$_}))) for(qw(mapper snpcaller allowedFlanking),@dir);
  local $0=fileparse $0;

  # The help menu
  my $help="$0: Launches the Lyve-SET pipeline
    Usage: $0 [project] [-ref reference.fasta]
    If project is not given, then it is assumed to be the current working directory.
    If reference is not given, then it is assumed to be proj/reference/reference.fasta
    Where parameters with a / are directories
    -ref      proj/reference/reference.fasta   The reference genome assembly
    -reads    $$settings{readsdir} where fastq and fastq.gz files are located
    -bam      $$settings{bamdir} where to put bams
    -vcf      $$settings{vcfdir} where to put vcfs
    --tmpdir  $$settings{tmpdir} tmp/ Where to put temporary files
    --msadir  $$settings{msadir} multiple sequence alignment and tree files (final output)
    --logdir  $$settings{logdir} Where to put log files. Qsub commands are also stored here.
    -asm      $$settings{asmdir} directory of assemblies. Copy or symlink the reference genome assembly to use it if it is not already in the raw reads directory

    SNP MATRIX OPTIONS
    --allowedFlanking  $$settings{allowedFlanking} allowed flanking distance in bp. Nucleotides this close together cannot be considered as high-quality.
    --min_alt_frac     $$settings{min_alt_frac}  The percent consensus that needs to be reached before a SNP is called. Otherwise, 'N'
    --min_coverage     $$settings{min_coverage}  Minimum coverage needed before a SNP is called. Otherwise, 'N'
    --rename-taxa      ''  A perl regex to rename taxa in the MSA. See set_processMsa.pl for details and examples.  Use additional escapes for special characters, e.g. 's/\\\\..*//'
    ";
    return "$help\n  --help To view more help\n" if(!$$settings{help});

    $help.="
    SKIP CERTAIN STEPS
    --nomask-phages                  Do not search for and mask phages in the reference genome
    --nomask-cliffs                  Do not search for and mask 'Cliffs' in pileups
    --nomatrix                       Do not create an hqSNP matrix
    --nomsa                          Do not make a multiple sequence alignment
    --notrees                        Do not make phylogenies
    --singleend                      Treat everything like single-end. Useful for when you think there is a single-end/paired-end bias.
    OTHER SHORTCUTS
    --fast                           Shorthand for --downsample --mapper snap --nomask-phages --nomask-cliffs --sample-sites
    --presets \"\"                   See presets.conf for more information
    --downsample                     Downsample all reads to 50x. Approximated according to the ref genome assembly
    --sample-sites                   Randomly choose a genome and find SNPs in a quick and dirty way. Then on the SNP-calling stage, only interrogate those sites for SNPs for each genome (including the randomly-sampled genome).
    MODULES
    --read_cleaner $$settings{read_cleaner}   Which read cleaner?  Choices: none, CGP, BayesHammer
    --mapper       $$settings{mapper}   Which mapper? Choices: smalt, snap";
    #--snpcaller    $$settings{snpcaller}   Which SNP caller? Choices: freebayes, varscan
    $help.="
    SCHEDULER AND MULTITHREADING OPTIONS
    --queue        $$settings{queue}             The default queue to use.
    --numnodes     $$settings{numnodes}                maximum number of nodes
    --numcpus      $$settings{numcpus}                 number of cpus
    --qsubxopts    '-N lyve-set'     Extra options to pass to qsub. This is not sanitized; internal options might overwrite yours.
  ";
  return $help;
}

