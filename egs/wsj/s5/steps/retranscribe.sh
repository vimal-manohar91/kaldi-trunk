#!/bin/bash

# Copyright Johns Hopkins University (Author: Vimal Manohar) 2013.  Apache 2.0.

# This script takes two data directories that represent different
# segmentations of the same data (both must have "segments" files and
# the recording-ids must match), and it converts the text in one directory
# to correspond to the segmentation in the other using the ctm file.  
# Its output is the "text" file in the second directory. 
# The ctm is typically the original ctm augmented with additional filler
# models to better model the fillers in the training data

# begin configuration section.
stage=0
cmd=run.pl
get_whole_transcripts=false
#end configuration section.

[ -f ./path.sh ] && . ./path.sh
. parse_options.sh || exit 1;

if [ $# -ne 5 ]; then
  echo "Usage: $0 [options] <in-data-dir> <lang> <ctm-file> <out-data-dir> <temp/log-dir>"
  echo " Options:"
  echo "    --cmd (run.pl|queue.pl...)      # specify how to run the sub-processes."
  echo "    --stage (0|1|2)                 # start scoring script from part-way through."
  echo "e.g.:"
  echo "$0 data_reseg/train data/lang data_reseg/train/ctm.augmented data_augmented/train exp/tri4b_augment_train"
  exit 1;
fi

data=$1
lang=$2
ctm_file=$3
data_out=$4
dir=$5

mkdir -p $dir/log || exit 1;

for f in $data/feats.scp $lang/phones.txt $ctm_file \
   $data_out/reco2file_and_channel $data_out/segments; do
  if [ ! -f $f ]; then 
    echo "$0: no such file $f"
    exit 1;
  fi
done

if [ $stage -le 0 ]; then
  if [ ! -s $ctm_file ]; then
    echo "$0: file $data/ctm does not exist or is empty."
    exit 1;
  fi
  echo "$0: converting ctm to a format where we have the recording-id ..."
  echo "$0: ... in place of the side and channel, e.g. sw02008-B instead of sw02008 B"

  cat $ctm_file | awk -v r=$data_out/reco2file_and_channel  \
   'BEGIN{while((getline < r) > 0) { if(NF!=3) {exit(1);} map[ $2 "&" $3 ] = $1;}}
    {if (NF!=5) {print "bad line " $0; exit(2);} reco = map[$1 "&" $2];
     if (length(reco) == 0) { print "Bad key " $1 "&" $2; exit(3); } 
     print reco, $3, $4, $5; } ' > $dir/ctm_per_reco
fi

if [ $stage -le 1 ]; then
  cat $data_out/segments | perl -e '
     @ARGV == 1 || die;
     $ctm_per_reco = shift @ARGV;
     $chunk_size = 3;
     open(C, "<$ctm_per_reco") || die "opening ctm file $ctm_per_reco";
     # we build up an associative array indexed by a pair of ids: $reco,$n
     # where $n is a 5-second chunk of time.
     sub to_chunk { my $t = shift @_; return int($t / $chunk_size); }
     while (<C>) {
       @A = split;  @A == 4 || die "Bad line $_ in $ctm_per_reco";
       ($reco, $start, $length, $word) = @A;
       $chunk = to_chunk($start);
       if (! defined $reco2list{$reco,$chunk} ){ $reco2list{$reco,$chunk} = [ ]; } # new anonymous array
       $arrayref = $reco2list{$reco,$chunk};
       push @$arrayref, [ $start, $length, $word ]; # another level of anonymous array..
     }
     $num_utts = 0; $num_empty = 0;
     while(<STDIN>) {
       @A = split;  @A == 4 || die "Bad line $_ in stdin";
       ($utt, $reco, $start, $end) = @A;
       @text = ();
       for ($chunk = to_chunk($start); $chunk <= to_chunk($end); $chunk++) {
         $arrayref = $reco2list{$reco,$chunk};
         if (defined $arrayref) {
           foreach $entry ( @$arrayref ) { # note, $entry is itself an arrayref
                                           # to an array containing $start $end $word.
             $word_start = $$entry[0];
             if ($word_start >= $start && $word_start <= $end) {
               $word_end = $$entry[1] + $word_start;
               if ($word_end >= $start && $word_end <= $end) {
                 $word = $$entry[2]; defined $word || die;
                 push @text, $word;
               }
             }
           }
         }
       }
       $num_utts++;
       if (@text > 0) { $t = join(" ", @text); print "$utt $t\n";; }
       elsif ( '$get_whole_transcripts' eq "true" ) { print "$utt\n"; }
       else { $num_empty++; }
     }
     print STDERR "Processed $num_utts utterances, of which $num_empty had no text.\n"; ' \
       $dir/ctm_per_reco | sort > $data_out/text || exit 1;

  nw_old=`cat $data/text | wc | awk '{print $2 - $1}'`
  nw_new=`cat $data_out/text | wc | awk '{print $2 - $1}'`
  echo "Number of words of training text changed from $nw_old to $nw_new";

  if [ ! -s $data_out/text ]; then
    echo "$0: produced empty output.  Something went wrong."
    exit 1;
  fi
fi

