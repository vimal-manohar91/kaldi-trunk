#!/bin/bash

# Author: Vimal Manohar

# This script prepares new training data directory with new text, segments, 
# utt2spk, spk2utt files by taking a ctm file that is augmented with 
# artificial fillers to better model the noise in the training data.
# This script is typically called in local/run_retranscribe.sh after 
# add_fillers_to_transcription.py is used obtain the augmented train ctm.

set -o pipefail
set -e

# begin configuration section.
get_whole_transcripts=false   # If get_whole_transcripts is true, 
                              # empty transcriptions are retained 
                              # in the text file. This is required
                              # when using whole data to train 
                              # model for segmentation.
clean_insertions=true   # If clean_insertions is false, then this script 
                        # generates new text file for the segments file 
                        # in the output data directory. 
                        # But that might leave a whole long utterance in the
                        # segments for a single insertion of artificial filler. 
                        # On the other hand, if clean_insertions is true, 
                        # new segment file is created with separate utterances 
                        # covering the inserted fillers where there 
                        # is no segment before.
#end configuration section.

[ -f ./path.sh ] && . ./path.sh
. parse_options.sh || exit 1;

if [ $# -ne 3 ]; then
  echo "Usage: $0 [options] <ctm-file> <data-dir> <temp/log-dir>"
  echo "e.g.:"
  echo "$0 exp/tri4b_augment_train/ctm.augmented data/train exp/tri4b_augment_train"
  exit 1;
fi

ctm_file=$1
data=$2
dir=$3

mkdir -p $dir/log || exit 1;

if [ ! -s $ctm_file ]; then
  echo "$0: file $ctm_file does not exist or is empty."
  exit 1;
fi

if [ ! -f $data/reco2file_and_channel ]; then 
  echo "$0: no such file $f"
  exit 1;
fi

echo "$0: converting ctm to a format where we have the recording-id ..."
echo "$0: ... in place of the side and channel, e.g. sw02008-B instead of sw02008 B"

cat $ctm_file | awk -v r=$data/reco2file_and_channel  \
  'BEGIN{while((getline < r) > 0) { if(NF!=3) {exit(1);} map[ $2 "&" $3 ] = $1;}}
   {if (NF!=5) {print "bad line " $0; exit(2);} reco = map[$1 "&" $2];
   if (length(reco) == 0) { print "Bad key " $1 "&" $2; exit(3); } 
    print reco, $3, $4, $5; } ' > $dir/ctm_per_reco

if $clean_insertions; then
  for x in segments utt2spk spk2utt text; do
    [ -f $data/$x ] && mv $data/$x $data/$x.orig
  done
  utils/ctm2text_and_segments.py \
    --get-whole-transcripts $get_whole_transcripts \
    $dir/ctm_per_reco $data/segments.orig \
    $data/segments > $data/text || exit 1
  cat $data/text | awk '{print $1}' | \
    awk -F'-' '{print $0" "$1}' | sort > $data/utt2spk
  utt2spk_to_spk2utt.pl $data/utt2spk > $data/spk2utt || exit 1
  for x in segments utt2spk spk2utt text; do
    [ -f $data/$x.orig ] && rm $data/$x.orig
  done
else
  utils/ctm2text.py --get-whole-transcripts $get_whole_transcripts \
    $dir/ctm_per_reco $data/segments > $data/text || exit 1
  cat $data/text | awk '{print $1}' | \
    awk -F'-' '{print $0" "$1}' | sort > $data/utt2spk
  utt2spk_to_spk2utt.pl $data/utt2spk > $data/spk2utt || exit 1
fi

if [ ! -s $data/text ]; then
  echo "$0: produced empty output.  Something went wrong."
  exit 1;
fi

