#!/bin/bash

# This is not necessarily the top-level run.sh as it is in other directories.   see README.txt first.

tri5_only=false
[ ! -f ./lang.conf ] && echo "Language configuration does not exist! Use the configurations in conf/lang/* as a startup" && exit 1
[ ! -f ./conf/common_vars.sh ] && echo "the file conf/common_vars.sh does not exist!" && exit 1

. conf/common_vars.sh || exit 1;
. ./lang.conf || exit 1;

[ -f local.conf ] && . ./local.conf

set -e           #Exit on non-zero return code from any command
set -o pipefail  #Exit if any of the commands in the pipeline will 
                 #return non-zero return code
#set -u           #Fail on an undefined variable

data_only=false
share_silence_phones=true   # If set to true, silence phones 
                            # share same root in context dependency tree
nonshared_noise=false       # If set to true, pdf is not 
                            # shared across the noise phones
full_initial=false          # Set this to true to build SGMM models without 
                            # adding artificial fillers in 
                            # exp/sgmm5_initial_mmi_b0.1. 
                            # This is only to get baseline results.

# Configuration for adding artificial fillers
train_decode_dir=                 # The best LMWT score is taken automatically. e.g. exp/tri5_initial/decode_train.seg/score_8
train_ali_dir=exp/tri5_initial_ali
add_fillers_opts="--num-fillers 5 --count-threshold 30"
extract_insertions_opts=          # Give "--segments data/train/segments" if you want to add insertions only outside the human segments
clean_insertions=true             # See steps/retranscribe.sh for details

[ -z "$add_fillers_opts" ] && exit 1    # Just to be safe, give the options here explicitly.

. ./path.sh
. utils/parse_options.sh

# Configuration for decoding train data
max_states=150000
wip=0.5

# Configuration for segmenting train data
segmentation_opts="--max-length-diff 0.4 --min-inter-utt-silence-length 1.0 --silence-proportion 0.5" 
silence_segment_fraction=1.0      # Fraction of silence segments that are kept as part of whole data
keep_silence_segments=true       # If true, equivalent to silence_segment_fraction=1.0; otherwise silence_segment_fraction=0.0

mkdir -p data
mkdir -p data/train
mkdir -p data/train_whole
mkdir -p data_initial

function make_plp {
  t=$1
  data=$2
  plpdir=$3

  if [ "$use_pitch" = "false" ] && [ "$use_ffv" = "false" ]; then
   steps/make_plp.sh --cmd "$train_cmd" --nj $train_nj ${data}/${t} exp/make_plp/${t} ${plpdir}
  elif [ "$use_pitch" = "true" ] && [ "$use_ffv" = "true" ]; then
    cp -rT ${data}/${t} ${data}/${t}_plp; cp -rT ${data}/${t} ${data}/${t}_pitch; cp -rT ${data}/${t} ${data}/${t}_ffv
    steps/make_plp_pitch.sh --cmd "$train_cmd" --nj $train_nj ${data}/${t}_plp_pitch exp/make_plp_pitch/${t} plp_pitch_tmp_${t}
    local/make_ffv.sh --cmd "$train_cmd"  --nj $train_nj ${data}/${t}_ffv exp/make_ffv/${t} ffv_tmp_${t}
    steps/append_feats.sh --cmd "$train_cmd" --nj $train_nj ${data}/${t}{_plp_pitch,_ffv,} exp/make_ffv/append_${t}_pitch_ffv ${plpdir}
    rm -rf {plp_pitch,ffv}_tmp_${t} ${data}/${t}_{plp_pitch,ffv}
  elif [ "$use_pitch" = "true" ]; then
    steps/make_plp_pitch.sh --cmd "$train_cmd" --nj $train_nj ${data}/${t} exp/make_plp_pitch/${t} ${plpdir}
  elif [ "$use_ffv" = "true" ]; then
    cp -rT ${data}/${t} ${data}/${t}_plp; cp -rT ${data}/${t} ${data}/${t}_ffv
    steps/make_plp.sh --cmd "$train_cmd" --nj $train_nj ${data}/${t}_plp exp/make_plp/${t} plp_tmp_${t}
    local/make_ffv.sh --cmd "$train_cmd" --nj $train_nj ${data}/${t}_ffv exp/make_ffv/${t} ffv_tmp_${t}
    steps/append_feats.sh --cmd "$train_cmd" --nj $train_nj ${data}/${t}{_plp,_ffv,} exp/make_ffv/append_${t} ${plpdir}
    rm -rf {plp,ffv}_tmp_${t} ${data}/${t}_{plp,ffv}
  fi
  
  utils/fix_data_dir.sh ${data}/${t}
  steps/compute_cmvn_stats.sh ${data}/${t} exp/make_plp/${t} ${plpdir}
  utils/fix_data_dir.sh ${data}/${t}
}

#Preparing dev2h and train directories
if [ ! -d data/raw_train_data ]; then
    echo ---------------------------------------------------------------------
    echo "Subsetting the TRAIN set"
    echo ---------------------------------------------------------------------

    local/make_corpus_subset.sh "$train_data_dir" "$train_data_list" ./data/raw_train_data
    train_data_dir=`readlink -f ./data/raw_train_data`

    nj_max=`cat $train_data_list | wc -l`
    if [[ "$nj_max" -lt "$train_nj" ]] ; then
        echo "The maximum reasonable number of jobs is $nj_max (you have $train_nj)! (The training and decoding process has file-granularity)"
        exit 1;
        train_nj=$nj_max
    fi
fi
train_data_dir=`readlink -f ./data/raw_train_data`

if [ ! -d data/raw_dev2h_data ]; then
  echo ---------------------------------------------------------------------
  echo "Subsetting the DEV2H set"
  echo ---------------------------------------------------------------------  
  local/make_corpus_subset.sh "$dev2h_data_dir" "$dev2h_data_list" ./data/raw_dev2h_data || exit 1
fi

if [ ! -d data/raw_dev10h_data ]; then
  echo ---------------------------------------------------------------------
  echo "Subsetting the DEV10H set"
  echo ---------------------------------------------------------------------  
  local/make_corpus_subset.sh "$dev10h_data_dir" "$dev10h_data_list" ./data/raw_dev10h_data || exit 1
fi

decode_nj=$dev2h_nj
nj_max=`cat $dev2h_data_list | wc -l`
if [[ "$nj_max" -lt "$decode_nj" ]] ; then
  echo "The maximum reasonable number of jobs is $nj_max -- you have $decode_nj! (The training and decoding process has file-granularity)"
  exit 1
  decode_nj=$nj_max
fi

mkdir -p data_initial/local
if [[ ! -f data_initial/local/lexicon.txt || data_initial/local/lexicon.txt -ot "$lexicon_file" ]]; then
  echo ---------------------------------------------------------------------
  echo "Preparing lexicon in data_initial/local on" `date`
  echo ---------------------------------------------------------------------
  local/prepare_lexicon_separate_fillers.pl --nonshared-noise $nonshared_noise --phonemap "$phoneme_mapping" \
    $lexiconFlags $lexicon_file data_initial/local
fi

###############################################################################
#
# Data preparation in data_initial/train
#
###############################################################################

if [[ ! -f data_initial/train/wav.scp || data_initial/train/wav.scp -ot "$train_data_dir" ]]; then
  echo ---------------------------------------------------------------------
  echo "Preparing acoustic training lists in data_initial/train on" `date`
  echo ---------------------------------------------------------------------
  mkdir -p data_initial/train
  local/prepare_acoustic_training_data_separate_fillers.pl \
    --vocab data_initial/local/lexicon.txt --fragmentMarkers \-\*\~ \
    $train_data_dir data_initial/train > data_initial/train/skipped_utts.log
  mv data_initial/train/text data_initial/train/text_orig
  cat data_initial/train/text_orig | sed 's/<silence>\ //g' | sed 's/\ <silence>//g' | awk '{if (NF > 1) {print $0}}' > data_initial/train/text
  cat data_initial/train/text | tr ' ' '\n' | \
    sed -n '/<.*>/p' | sed '/'$oovSymbol'/d' | sed '/<hes>/d' | \
    sort -u > data_initial/local/fillers.list
  rm data_initial/local/lexicon.txt
fi

if [[ ! -f data_initial/local/lexicon.txt || data_initial/local/lexicon.txt -ot "$lexicon_file" ]]; then
  echo ---------------------------------------------------------------------
  echo "Preparing lexicon with all fillers in data_initial/local on" `date`
  echo ---------------------------------------------------------------------
  local/prepare_lexicon_separate_fillers.pl  --nonshared-noise $nonshared_noise --add data_initial/local/fillers.list --phonemap "$phoneme_mapping" \
    $lexiconFlags $lexicon_file data_initial/local
fi

mkdir -p data_initial/lang
if [[ ! -f data_initial/lang/L.fst || data_initial/lang/L.fst -ot data_initial/local/lexicon.txt ]]; then
  echo ---------------------------------------------------------------------
  echo "Creating L.fst etc in data_initial/lang on" `date`
  echo ---------------------------------------------------------------------
  utils/prepare_lang.sh \
    --share-silence-phones $share_silence_phones \
    data_initial/local $oovSymbol data_initial/local/tmp.lang data_initial/lang
fi

if [[ ! -f data_initial/train/glm || data_initial/train/glm -ot "$glmFile" ]]; then
  echo ---------------------------------------------------------------------
  echo "Preparing train stm files in data_initial/train on" `date`
  echo ---------------------------------------------------------------------
  local/prepare_stm.pl --fragmentMarkers \-\*\~ data_initial/train || exit 1
fi

if [[ ! -f data_initial/dev2h/wav.scp || data_initial/dev2h/wav.scp -ot ./data/raw_dev2h_data/audio ]]; then
  echo ---------------------------------------------------------------------
  echo "Preparing dev2h data lists in data_initial/dev2h on" `date`
  echo ---------------------------------------------------------------------
  mkdir -p data_initial/dev2h
  local/prepare_acoustic_training_data_separate_fillers.pl \
    --fragmentMarkers \-\*\~ \
    `pwd`/data/raw_dev2h_data data_initial/dev2h > data_initial/dev2h/skipped_utts.log || exit 1
fi

if [[ ! -f data_initial/dev2h/glm || data_initial/dev2h/glm -ot "$glmFile" ]]; then
  echo ---------------------------------------------------------------------
  echo "Preparing dev2h stm files in data_initial/dev2h on" `date`
  echo ---------------------------------------------------------------------
  if [ -z $stm_file ]; then 
    echo "WARNING: You should define the variable stm_file pointing to the IndusDB stm"
    echo "WARNING: Doing that, it will give you scoring close to the NIST scoring.    "
    local/prepare_stm.pl --fragmentMarkers \-\*\~ data_initial/dev2h || exit 1
  else
    local/augment_original_stm.pl $stm_file data_initial/dev2h || exit 1
  fi
  [ ! -z $glmFile ] && cp $glmFile data_initial/dev2h/glm

fi

# We will simply override the default G.fst by the G.fst generated using SRILM
if [[ ! -f data_initial/srilm/lm.gz || data_initial/srilm/lm.gz -ot data_initial/train/text ]]; then
  echo ---------------------------------------------------------------------
  echo "Training SRILM language models on" `date`
  echo ---------------------------------------------------------------------
  local/train_lms_srilm.sh --dev-text data_initial/dev2h/text \
    --train-text data_initial/train/text data_initial data_initial/srilm 
fi
if [[ ! -f data_initial/lang/G.fst || data_initial/lang/G.fst -ot data_initial/srilm/lm.gz ]]; then
  echo ---------------------------------------------------------------------
  echo "Creating G.fst on " `date`
  echo ---------------------------------------------------------------------
  local/arpa2G.sh data_initial/srilm/lm.gz data_initial/lang data_initial/lang
fi
  
echo ---------------------------------------------------------------------
echo "Starting plp feature extraction for data_initial/train in plp on" `date`
echo ---------------------------------------------------------------------

if [ ! -f data_initial/train/.plp.done ]; then
  mkdir -p exp/plp_initial
  make_plp train data_initial exp/plp_initial

  #if [ "$use_pitch" = "false" ] && [ "$use_ffv" = "false" ]; then
  # steps/make_plp.sh --cmd "$train_cmd" --nj $train_nj data_initial/train exp/make_plp/train plp
  #elif [ "$use_pitch" = "true" ] && [ "$use_ffv" = "true" ]; then
  #  cp -rT data_initial/train data_initial/train_plp; cp -rT data_initial/train data_initial/train_pitch; cp -rT data_initial/train data_initial/train_ffv
  #  steps/make_plp.sh --cmd "$train_cmd" --nj $train_nj data_initial/train_plp exp/make_plp/train plp_tmp_train
  #  local/make_pitch.sh --cmd "$train_cmd" --nj $train_nj data_initial/train_pitch exp/make_pitch/train pitch_tmp_train
  #  local/make_ffv.sh --cmd "$train_cmd"  --nj $train_nj data_initial/train_ffv exp/make_ffv/train ffv_tmp_train
  #  steps/append_feats.sh --cmd "$train_cmd" --nj $train_nj data_initial/train{_plp,_pitch,_plp_pitch} exp/make_pitch/append_train_pitch plp_tmp_train
  #  steps/append_feats.sh --cmd "$train_cmd" --nj $train_nj data_initial/train{_plp_pitch,_ffv,} exp/make_ffv/append_train_pitch_ffv plp
  #  rm -rf {plp,pitch,ffv}_tmp_train data_initial/train_{plp,pitch,plp_pitch}
  #elif [ "$use_pitch" = "true" ]; then
  #  cp -rT data_initial/train data_initial/train_plp; cp -rT data_initial/train data_initial/train_pitch
  #  steps/make_plp.sh --cmd "$train_cmd" --nj $train_nj data_initial/train_plp exp/make_plp/train plp_tmp_train
  #  local/make_pitch.sh --cmd "$train_cmd" --nj $train_nj data_initial/train_pitch exp/make_pitch/train pitch_tmp_train
  #  steps/append_feats.sh --cmd "$train_cmd" --nj $train_nj data_initial/train{_plp,_pitch,} exp/make_pitch/append_train plp
  #  rm -rf {plp,pitch}_tmp_train data_initial/train_{plp,pitch}
  #elif [ "$use_ffv" = "true" ]; then
  #  cp -rT data_initial/train data_initial/train_plp; cp -rT data_initial/train data_initial/train_ffv
  #  steps/make_plp.sh --cmd "$train_cmd" --nj $train_nj data_initial/train_plp exp/make_plp/train plp_tmp_train
  #  local/make_ffv.sh --cmd "$train_cmd" --nj $train_nj data_initial/train_ffv exp/make_ffv/train ffv_tmp_train
  #  steps/append_feats.sh --cmd "$train_cmd" --nj $train_nj data_initial/train{_plp,_ffv,} exp/make_ffv/append_train plp
  #  rm -rf {plp,ffv}_tmp_train data_initial/train_{plp,ffv}
  #fi

  #steps/compute_cmvn_stats.sh \
  #  data_initial/train exp/make_plp/train plp
  ## In case plp or pitch extraction failed on some utterances, delist them
  #utils/fix_data_dir.sh data_initial/train
  
  touch data_initial/train/.plp.done
fi

if [ ! -f data_initial/train_sub3/.done ]; then
  echo ---------------------------------------------------------------------
  echo "Subsetting monophone training data in data_initial/train_sub[123] on" `date`
  echo ---------------------------------------------------------------------
  numutt=`cat data_initial/train/feats.scp | wc -l`;
  utils/subset_data_dir.sh data_initial/train  5000 data_initial/train_sub1
  if [ $numutt -gt 10000 ] ; then
    utils/subset_data_dir.sh data_initial/train 10000 data_initial/train_sub2
  else
    (cd data_initial; ln -s train train_sub2 )
  fi
  if [ $numutt -gt 20000 ] ; then
    utils/subset_data_dir.sh data_initial/train 20000 data_initial/train_sub3
  else
    (cd data_initial; ln -s train train_sub3 )
  fi

  touch data_initial/train_sub3/.done
fi

###############################################################################
#
# Data preparation in data_initial/train_whole
#
###############################################################################

train_data_dir=`readlink -f ./data/raw_train_data`
if [[ ! -f data_initial/train_whole/wav.scp || data_initial/train_whole/wav.scp -ot "$train_data_dir" ]]; then
  echo ---------------------------------------------------------------------
  echo "Preparing acoustic training lists in data_initial/train on" `date`
  echo ---------------------------------------------------------------------
  mkdir -p data_initial/train_whole
  local/prepare_acoustic_training_data_separate_fillers.pl --get-whole-transcripts "true" \
    --vocab data_initial/local/lexicon.txt --fragmentMarkers \-\*\~ \
    $train_data_dir data_initial/train_whole > data_initial/train_whole/skipped_utts.log
  mv data_initial/train_whole/text data_initial/train_whole/text_orig
  if $keep_silence_segments; then
    # Keep all segments including silence segments
    cat data_initial/train_whole/text_orig | awk '{if (NF == 2 && $2 == "<silence>") {print $1} else {print $0}}' > data_initial/train_whole/text
  else
    # Keep only a fraction of silence segments
    num_silence_segments=$(cat data_initial/train_whole/text_orig | awk '{if (NF == 2 && $2 == "<silence>") {print $0}}' | wc -l)
    num_keep_silence_segments=`echo $num_silence_segments | python -c "import sys; sys.stdout.write(\"%d\" % (float(sys.stdin.readline().strip()) * "$silence_segment_fraction"))"` 
    cat data_initial/train_whole/text_orig \
      | awk 'BEGIN{i=0} \
      { \
        if (NF == 2 && $2 == "<silence>") { \
          if (i<'$num_keep_silence_segments') { \
            print $1; \
            i++; \
          } \
        } else {print $0}\
      }' > data_initial/train_whole/text
  fi
  rm data_initial/train_whole/text_orig
  utils/fix_data_dir.sh data_initial/train_whole
fi

if [[ ! -f data_initial/train_whole/glm || data_initial/train_whole/glm -ot "$glmFile" ]]; then
  echo ---------------------------------------------------------------------
  echo "Preparing train stm files in data_initial/train_whole on" `date`
  echo ---------------------------------------------------------------------
  local/prepare_stm.pl --keep-fillers true --fragmentMarkers \-\*\~ data_initial/train_whole || exit 1
fi

echo ---------------------------------------------------------------------
echo "Starting plp feature extraction for data_initial/train_whole in plp_whole on" `date`
echo ---------------------------------------------------------------------

if [ ! -f data_initial/train_whole/.plp.done ]; then
  mkdir -p exp/plp_initial_whole
  make_plp train_whole data_initial exp/plp_initial_whole
  touch data_initial/train_whole/.plp.done
fi

if [ ! -f data_initial/train_whole_sub3/.done ]; then
  echo ---------------------------------------------------------------------
  echo "Subsetting monophone training data in data_initial/train_whole_sub[123] on" `date`
  echo ---------------------------------------------------------------------
  numutt=`cat data_initial/train_whole/feats.scp | wc -l`;
  utils/subset_data_dir.sh data_initial/train_whole  5000 data_initial/train_whole_sub1
  if [ $numutt -gt 10000 ] ; then
    utils/subset_data_dir.sh data_initial/train_whole 10000 data_initial/train_whole_sub2
  else
    (cd data_initial; ln -s train_whole train_whole_sub2 )
  fi
  if [ $numutt -gt 20000 ] ; then
    utils/subset_data_dir.sh data_initial/train_whole 20000 data_initial/train_whole_sub3
  else
    (cd data_initial; ln -s train_whole train_whole_sub3 )
  fi

  touch data_initial/train_whole_sub3/.done
fi

if $data_only; then
  echo "Data preparation done !"
  exit 0
fi

if [ ! -f exp/mono_initial/.done ]; then
  echo ---------------------------------------------------------------------
  echo "Starting (small) monophone training in exp/mono_initial on" `date`
  echo ---------------------------------------------------------------------
  steps/train_mono.sh \
    --boost-silence $boost_sil --nj 8 --cmd "$train_cmd" \
    data_initial/train_sub1 data_initial/lang exp/mono_initial
  touch exp/mono_initial/.done
fi

if [ ! -f exp/tri1_initial/.done ]; then
  echo ---------------------------------------------------------------------
  echo "Starting (small) triphone training in exp/tri1_initial on" `date`
  echo ---------------------------------------------------------------------
  steps/align_si.sh \
    --boost-silence $boost_sil --nj 12 --cmd "$train_cmd" \
    data_initial/train_sub2 data_initial/lang exp/mono_initial exp/mono_initial_ali_sub2
  steps/train_deltas.sh \
    --boost-silence $boost_sil --cmd "$train_cmd" $numLeavesTri1 $numGaussTri1 \
    data_initial/train_sub2 data_initial/lang exp/mono_initial_ali_sub2 exp/tri1_initial
  touch exp/tri1_initial/.done
fi

echo ---------------------------------------------------------------------
echo "Starting (medium) triphone training in exp/tri2_initial on" `date`
echo ---------------------------------------------------------------------
if [ ! -f exp/tri2_initial/.done ]; then
  steps/align_si.sh \
    --boost-silence $boost_sil --nj 24 --cmd "$train_cmd" \
    data_initial/train_sub3 data_initial/lang exp/tri1_initial exp/tri1_initial_ali_sub3
  steps/train_deltas.sh \
    --boost-silence $boost_sil --cmd "$train_cmd" $numLeavesTri2 $numGaussTri2 \
    data_initial/train_sub3 data_initial/lang exp/tri1_initial_ali_sub3 exp/tri2_initial
  touch exp/tri2_initial/.done
fi

echo ---------------------------------------------------------------------
echo "Starting (full) triphone training in exp/tri3_initial on" `date`
echo ---------------------------------------------------------------------
if [ ! -f exp/tri3_initial/.done ]; then
  steps/align_si.sh \
    --boost-silence $boost_sil --nj $train_nj --cmd "$train_cmd" \
    data_initial/train data_initial/lang exp/tri2_initial exp/tri2_initial_ali
  steps/train_deltas.sh \
    --boost-silence $boost_sil --cmd "$train_cmd" \
    $numLeavesTri3 $numGaussTri3 data_initial/train data_initial/lang exp/tri2_initial_ali exp/tri3_initial
  touch exp/tri3_initial/.done
fi

echo ---------------------------------------------------------------------
echo "Starting (lda_mllt) triphone training in exp/tri4_initial on" `date`
echo ---------------------------------------------------------------------
if [ ! -f exp/tri4_initial/.done ]; then
  steps/align_si.sh \
    --boost-silence $boost_sil --nj $train_nj --cmd "$train_cmd" \
    data_initial/train data_initial/lang exp/tri3_initial exp/tri3_initial_ali
  steps/train_lda_mllt.sh \
    --boost-silence $boost_sil --cmd "$train_cmd" \
    $numLeavesMLLT $numGaussMLLT data_initial/train data_initial/lang exp/tri3_initial_ali exp/tri4_initial
  touch exp/tri4_initial/.done
fi

echo ---------------------------------------------------------------------
echo "Starting (SAT) triphone training in exp/tri5_initial on" `date`
echo ---------------------------------------------------------------------

if [ ! -f exp/tri5_initial/.done ]; then
  steps/align_si.sh \
    --boost-silence $boost_sil --nj $train_nj --cmd "$train_cmd" \
    data_initial/train data_initial/lang exp/tri4_initial exp/tri4_initial_ali
  steps/train_sat.sh \
    --boost-silence $boost_sil --cmd "$train_cmd" \
    $numLeavesSAT $numGaussSAT data_initial/train data_initial/lang exp/tri4_initial_ali exp/tri5_initial
  touch exp/tri5_initial/.done
fi

if [ ! -f exp/tri5_initial_ali/.done ]; then
  echo ---------------------------------------------------------------------
  echo "Starting exp/tri5_initial_ali on" `date`
  echo ---------------------------------------------------------------------
  steps/align_fmllr.sh \
    --boost-silence $boost_sil --nj $train_nj --cmd "$train_cmd" \
    data_initial/train data_initial/lang exp/tri5_initial exp/tri5_initial_ali
  touch exp/tri5_initial_ali/.done
fi

echo ---------------------------------------------------------------------
echo "Resegment data in data_initial/train.seg on " `date`
echo ---------------------------------------------------------------------

local/run_segmentation_train.sh --train-nj $train_nj --nj $train_nj --initial true data_initial data_initial/lang || exit 1

local/run_segmentation.sh --segmentation_opts "$segmentation_opts" --initial true data_initial/train data_initial/lang || exit 1

#local/run_resegment.sh --train-nj $train_nj --nj $train_nj --type train --data data_initial --segmentation_opts "$segmentation_opts" --initial true || exit 1

####################################################################
##
## Baseline SGMM training. Disabled by default. Only to get models
## without adding artificial fillers
##
####################################################################

if $full_initial; then

  if [ ! -f exp/ubm5_initial/.done ]; then
    echo ---------------------------------------------------------------------
    echo "Starting exp/ubm5_initial on" `date`
    echo ---------------------------------------------------------------------
    steps/train_ubm.sh \
      --cmd "$train_cmd" $numGaussUBM \
      data_initial/train data_initial/lang exp/tri5_initial_ali exp/ubm5_initial
    touch exp/ubm5_initial/.done
  fi

  if [ ! -f exp/sgmm5_initial/.done ]; then
    echo ---------------------------------------------------------------------
    echo "Starting exp/sgmm5_initial on" `date`
    echo ---------------------------------------------------------------------
    steps/train_sgmm2.sh \
      --cmd "$train_cmd" $numLeavesSGMM $numGaussSGMM \
      data_initial/train data_initial/lang exp/tri5_initial_ali exp/ubm5_initial/final.ubm exp/sgmm5_initial
    #steps/train_sgmm2_group.sh \
    #  --cmd "$train_cmd" "${sgmm_group_extra_opts[@]-}" $numLeavesSGMM $numGaussSGMM \
    #  data_initial/train data_initial/lang exp/tri5_initial_ali exp/ubm5_initial/final.ubm exp/sgmm5_initial
    touch exp/sgmm5_initial/.done
  fi

  ################################################################################
  # Ready to start discriminative SGMM training
  ################################################################################

  if [ ! -f exp/sgmm5_initial_ali/.done ]; then
    echo ---------------------------------------------------------------------
    echo "Starting exp/sgmm5_initial_ali on" `date`
    echo ---------------------------------------------------------------------
    steps/align_sgmm2.sh \
      --nj $train_nj --cmd "$train_cmd" --transform-dir exp/tri5_initial_ali \
      --use-graphs true --use-gselect true \
      data_initial/train data_initial/lang exp/sgmm5_initial exp/sgmm5_initial_ali
    touch exp/sgmm5_initial_ali/.done
  fi
  
  if [ ! -f exp/sgmm5_initial_denlats/.done ]; then
    echo ---------------------------------------------------------------------
    echo "Starting exp/sgmm5_initial_denlats on" `date`
    echo ---------------------------------------------------------------------
    steps/make_denlats_sgmm2.sh \
      --nj $train_nj --sub-split $train_nj "${sgmm_denlats_extra_opts[@]}" \
      --beam 10.0 --lattice-beam 6 --cmd "$decode_cmd" --transform-dir exp/tri5_initial_ali \
      data_initial/train data_initial/lang exp/sgmm5_initial_ali exp/sgmm5_initial_denlats
    touch exp/sgmm5_initial_denlats/.done
  fi

  if [ ! -f exp/sgmm5_initial_mmi_b0.1/.done ]; then
    echo ---------------------------------------------------------------------
    echo "Starting exp/sgmm5_initial_mmi_b0.1 on" `date`
    echo ---------------------------------------------------------------------
    steps/train_mmi_sgmm2.sh \
      --cmd "$train_cmd" "${sgmm_mmi_extra_opts[@]}" \
      --drop-frames true --transform-dir exp/tri5_initial_ali --boost 0.1 \
      data_initial/train data_initial/lang exp/sgmm5_initial_ali exp/sgmm5_initial_denlats \
      exp/sgmm5_initial_mmi_b0.1
    touch exp/sgmm5_initial_mmi_b0.1/.done
  fi
fi

datadir=data_initial/train.seg

####################################################################
##
## FMLLR decoding 
##
####################################################################
tri5=tri5_initial
decode=exp/${tri5}/decode_train.seg

if [ ! -f ${decode}/.done ]; then
  echo ---------------------------------------------------------------------
  echo "Spawning decoding with SAT models  on" `date`
  echo ---------------------------------------------------------------------
  utils/mkgraph.sh \
    data_initial/lang exp/$tri5 exp/$tri5/graph |tee exp/$tri5/mkgraph.log

  mkdir -p $decode
  steps/decode_fmllr_extra.sh --skip-scoring false \
    --nj $train_nj --cmd "$decode_cmd" "${decode_extra_opts[@]}"\
    exp/$tri5/graph ${datadir} ${decode} |tee ${decode}/decode.log
  
  touch ${decode}/.done
fi

local/run_kws_stt_task.sh --cer $cer --max-states $max_states \
  --cmd "$decode_cmd" --skip-kws true --skip-stt false --wip $wip \
  --keep-fillers true \
  "${shadow_set_extra_opts[@]}" "${lmwt_plp_extra_opts[@]}" \
  ${datadir} data_initial/lang $decode
  
if $full_initial; then
  ####################################################################
  ## SGMM2 decoding 
  ####################################################################
  sgmm5=sgmm5_initial
  decode=exp/${sgmm5}/decode_fmllr_train.seg

  if [ ! -f $decode/.done ]; then
    echo ---------------------------------------------------------------------
    echo "Spawning $decode on" `date`
    echo ---------------------------------------------------------------------
    utils/mkgraph.sh \
      data_initial/lang exp/$sgmm5 exp/$sgmm5/graph |tee exp/$sgmm5/mkgraph.log

    mkdir -p $decode
    steps/decode_sgmm2.sh --skip-scoring true --use-fmllr true --nj $train_nj \
      --cmd "$decode_cmd" --transform-dir exp/${tri5}/decode_train.seg "${decode_extra_opts[@]}"\
      exp/$sgmm5/graph ${datadir} $decode |tee $decode/decode.log
    touch $decode/.done

    if ! $fast_path ; then
      local/run_kws_stt_task.sh --cer $cer --max-states $max_states \
        --cmd "$decode_cmd" --skip-kws true --skip-stt false --wip $wip \
        --keep-fillers true \
        "${shadow_set_extra_opts[@]}" "${lmwt_plp_extra_opts[@]}" \
        ${datadir} data_initial/lang ${decode}
    fi
  fi

  ####################################################################
  ##
  ## SGMM_MMI rescoring
  ##
  ####################################################################

  for iter in 1 2 3 4; do
    # Decode SGMM+MMI (via rescoring).
    sgmm5_mmi_b0_1=sgmm5_initial_mmi_b0.1
    decode=exp/${sgmm5_mmi_b0_1}/decode_fmllr_train.seg_it${iter}
    if [ ! -f $decode/.done ]; then

      mkdir -p $decode
      steps/decode_sgmm2_rescore.sh  --skip-scoring true \
        --cmd "$decode_cmd" --iter $iter --transform-dir exp/$tri5/decode_train.seg \
        data_initial/lang ${datadir} exp/$sgmm5/decode_fmllr_train.seg $decode | tee ${decode}/decode.log

      touch $decode/.done
    fi
    
    #We are done -- all lattices has been generated. We have to
    #a)Run MBR decoding
    #b)Run KW search
    local/run_kws_stt_task.sh --cer $cer --max-states $max_states \
      --cmd "$decode_cmd" --skip-kws true --skip-stt false --wip $wip \
      --keep-fillers true \
      "${shadow_set_extra_opts[@]}" "${lmwt_plp_extra_opts[@]}" \
      ${datadir} data_initial/lang $decode
      
  done
fi

####################################################################
##
## Data preparation with artificial fillers added
##
####################################################################

if [ -z $train_decode_dir ]; then
  train_decode_dir=`dirname $(for x in exp/*/decode*train*; do [ -d $x ] && grep Sum $x/score_*/*.sys | utils/best_wer.sh; done 2>/dev/null | sort | head -1 | awk '{print $NF}')`
fi

echo "Retranscribe using decode directory $train_decode_dir"

local/run_retranscribe.sh --clean-insertions $clean_insertions --extract-insertions-opts "$extract_insertions_opts" --add-fillers-opts "$add_fillers_opts" --get-whole-transcripts false data_initial $train_decode_dir $train_ali_dir data/train || exit 1
make_plp train data exp/plp
utils/fix_data_dir.sh data/train

local/run_retranscribe.sh --clean-insertions $clean_insertions --extract-insertions-opts "$extract_insertions_opts" --add-fillers-opts "$add_fillers_opts" --get-whole-transcripts true data_initial $train_decode_dir $train_ali_dir data/train_whole || exit 1
make_plp train_whole data exp/plp_whole
utils/fix_data_dir.sh data/train_whole

mkdir -p data/local
cat data/train/text | tr ' ' '\n' | \
  sed -n '/<.*>/p' | sed '/'$oovSymbol'/d' | sed '/<hes>/d' | \
  sort -u > data/local/fillers.list

if [[ ! -f data/local/lexicon.txt || data/local/lexicon.txt -ot "$lexicon_file" ]]; then
  echo ---------------------------------------------------------------------
  echo "Preparing lexicon in data/local on" `date`
  echo ---------------------------------------------------------------------
  local/prepare_lexicon_separate_fillers.pl --nonshared-noise $nonshared_noise --add data/local/fillers.list --phonemap "$phoneme_mapping" \
    $lexiconFlags $lexicon_file data/local
fi

mkdir -p data/lang
if [[ ! -f data/lang/L.fst || data/lang/L.fst -ot data/local/lexicon.txt ]]; then
  echo ---------------------------------------------------------------------
  echo "Creating L.fst etc in data/lang on" `date`
  echo ---------------------------------------------------------------------
  utils/prepare_lang.sh \
    --share-silence-phones $share_silence_phones \
    data/local $oovSymbol data/local/tmp.lang data/lang
fi

# We will simply override the default G.fst by the G.fst generated using SRILM
if [[ ! -f data/srilm/lm.gz || data/srilm/lm.gz -ot data/train/text ]]; then
  echo ---------------------------------------------------------------------
  echo "Training SRILM language models on" `date`
  echo ---------------------------------------------------------------------
  local/train_lms_srilm.sh --dev-text data_initial/dev2h/text \
    --train-text data/train/text data data/srilm 
fi

if [[ ! -f data/lang/G.fst || data/lang/G.fst -ot data/srilm/lm.gz ]]; then
  echo ---------------------------------------------------------------------
  echo "Creating G.fst on " `date`
  echo ---------------------------------------------------------------------
  local/arpa2G.sh data/srilm/lm.gz data/lang data/lang
fi
  
if [ ! -f data/train_sub1/.done ]; then
  echo ---------------------------------------------------------------------
  echo "Subsetting monophone training data in data/train_sub[123] on" `date`
  echo ---------------------------------------------------------------------
  numutt=`cat data/train/feats.scp | wc -l`;
  utils/subset_data_dir.sh data/train  5000 data/train_sub1
  if [ $numutt -gt 10000 ] ; then
    utils/subset_data_dir.sh data/train 10000 data/train_sub2
  else
    (cd data; ln -s train train_sub2 )
  fi
  if [ $numutt -gt 20000 ] ; then
    utils/subset_data_dir.sh data/train 20000 data/train_sub3
  else
    (cd data; ln -s train train_sub3 )
  fi

  touch data/train_sub1/.done
fi

if [ ! -f data/train_whole_sub1/.done ]; then
  echo ---------------------------------------------------------------------
  echo "Subsetting monophone training data in data/train_whole_sub[123] on" `date`
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

  touch data/train_whole_sub1/.done
fi

exit 0
