#!/bin/bash

# This is not necessarily the top-level run.sh as it is in other directories.   see README.txt first.
[ ! -f ./lang.conf ] && echo 'Language configuration does not exist! Use the configurations in conf/lang/* as a startup' && exit 1
[ ! -f ./conf/common_vars.sh ] && echo 'the file conf/common_vars.sh does not exist!' && exit 1

. conf/common_vars.sh || exit 1;
. ./lang.conf || exit 1;

[ -f local.conf ] && . ./local.conf

keep_silence_segments=false   # If true, then keep all silence segments 
                              # while preparing the training data for 
                              # segmentation model
silence_segment_fraction=1.0  # Keep only fraction of silence segments 
                              # Used only when --keep-silence-segments is 
                              # false
use_whole_cmvn_only=false
use_subset=false

. ./utils/parse_options.sh

set -e           #Exit on non-zero return code from any command
set -o pipefail  #Exit if any of the commands in the pipeline will 
                 #return non-zero return code
#set -u           #Fail on an undefined variable

#Preparing dev2h and train directories
if [ ! -d data/raw_train_data ]; then
    echo ---------------------------------------------------------------------
    echo "Subsetting the TRAIN set"
    echo ---------------------------------------------------------------------

    local/make_corpus_subset.sh "$train_data_dir" "$train_data_list" ./data/raw_train_data
    train_data_dir=`readlink -f ./data/raw_train_data`

fi
nj_max=`cat $train_data_list | wc -l`
if [[ "$nj_max" -lt "$train_nj" ]] ; then
    echo "The maximum reasonable number of jobs is $nj_max (you have $train_nj)! (The training and decoding process has file-granularity)"
    exit 1;
    train_nj=$nj_max
fi
train_data_dir=`readlink -f ./data/raw_train_data`

train_data_dir=`readlink -f ./data/raw_train_data`
if [[ ! -f data/train_whole/wav.scp || data/train_whole/wav.scp -ot "$train_data_dir" ]]; then
  echo ---------------------------------------------------------------------
  echo "Preparing acoustic training lists in data/train on" `date`
  echo ---------------------------------------------------------------------
  mkdir -p data/train_whole
  local/prepare_acoustic_training_data.pl --get-whole-transcripts "true" \
    --vocab data/local/lexicon.txt --fragmentMarkers \-\*\~ \
    $train_data_dir data/train_whole > data/train_whole/skipped_utts.log
  mv data/train_whole/text data/train_whole/text_orig
  if $keep_silence_segments; then
    # Keep all segments including silence segments
    cat data/train_whole/text_orig | awk '{if (NF == 2 && $2 == "<silence>") {print $1} else {print $0}}' > data/train_whole/text
  else
    # Keep only a fraction of silence segments
    #num_silence_segments=$(cat data/train_whole/text_orig | awk '{if (NF == 2 && $2 == "<silence>") {print $0}}' | wc -l)
    #num_keep_silence_segments=`echo $num_silence_segments | python -c "import sys; sys.stdout.write(\"%d\" % (float(sys.stdin.readline().strip()) * "$silence_segment_fraction"))"` 
    cat data/train_whole/text_orig \
      | awk '\
      { \
        if (NF == 2 && $2 == "<silence>") { \
          if (rand() < '$silence_segment_fraction') { \
            print $1; \
          } \
        } else {print $0}\
      }' > data/train_whole/text
  fi
  rm data/train_whole/text_orig
  utils/fix_data_dir.sh data/train_whole
fi

if [[ ! -f data/train_whole/glm || data/train_whole/glm -ot "$glmFile" ]]; then
  echo ---------------------------------------------------------------------
  echo "Preparing train stm files in data/train_whole on" `date`
  echo ---------------------------------------------------------------------
  local/prepare_stm.pl --fragmentMarkers \-\*\~ data/train_whole || exit 1
fi

echo ---------------------------------------------------------------------
echo "Starting plp feature extraction for data/train_whole in plp_whole on" `date`
echo ---------------------------------------------------------------------

if [ ! -f data/train_whole/.plp.done ]; then
  if $use_pitch; then
    steps/make_plp_pitch.sh --cmd "$train_cmd" --nj $train_nj \
      data/train_whole exp/make_plp_pitch/train_whole plp_whole
  else
    steps/make_plp.sh --cmd "$train_cmd" --nj $train_nj \
      data/train_whole exp/make_plp/train_whole plp_whole
  fi

  utils/fix_data_dir.sh data/train_whole
  steps/compute_cmvn_stats.sh data/train_whole exp/make_plp/train_whole plp_whole
  utils/fix_data_dir.sh data/train_whole
  touch data/train_whole/.plp.done
fi
 
if $use_subset; then
  echo ---------------------------------------------------------------------
  echo "Subsetting monophone training data in data/train_sub[123] on" `date`
  echo ---------------------------------------------------------------------
  numutt=`cat data/train_whole/feats.scp | wc -l`;
  utils/subset_data_dir.sh data/train_whole  5000 data/train_whole_sub1
  if [ $numutt -gt 10000 ] ; then
    utils/subset_data_dir.sh data/train_whole 10000 data/train_whole_sub2
  else
    (cd data; ln -s train_whole train_whole_sub2 )
  fi
  if [ $numutt -gt 20000 ] ; then
    utils/subset_data_dir.sh data/train_whole 20000 data/train_whole_sub3
  else
    (cd data; ln -s train_whole train_whole_sub3 )
  fi
fi

if $use_whole_cmvn_only; then
  [ -f data/train_whole/cmvn.scp ] && mv data/train_whole/cmvn.scp data/train_whole/cmvn.scp.temp
fi

if $use_whole_cmvn_only; then
  for f in data/train/*; do cp -r $f data/train_whole; done
  mv data/train_whole/cmvn.scp.temp data/train_whole/cmvn.scp
  utils/fix_data_dir.sh data/train_whole
fi

echo ---------------------------------------------------------------------
echo "Training segmentation model in exp/tri4b_seg"
echo ---------------------------------------------------------------------
 
datadir=data/train_whole

if $use_subset; then
  local/resegment/run_segmentation_train_old.sh \
    --boost-sil 1.0 --train-nj $train_nj \
    --nj $train_nj \
    exp/tri4 $datadir data/lang exp/tri4b_seg || exit 1
else
if $use_whole_cmvn_only; then
  local/resegment/run_segmentation_train.sh \
    --boost-sil 1.0 --train-nj $train_nj \
    --nj $train_nj --ext-alidir exp/sgmm5_ali \
    exp/tri4 $datadir data/lang exp/tri4b_seg || exit 1
else
  local/resegment/run_segmentation_train.sh \
    --boost-sil 1.0 --train-nj $train_nj \
    --nj $train_nj \
    exp/tri4 $datadir data/lang exp/tri4b_seg || exit 1
fi
fi

echo ---------------------------------------------------------------------
echo "Finished successfully on" `date`
echo ---------------------------------------------------------------------

exit 0
