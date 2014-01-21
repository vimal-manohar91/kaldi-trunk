#!/bin/bash

set -o pipefail
#set -e

. cmd.sh
. lang.conf

nj=10             # nj for training subset of whole
train_nj=30       # nj for aligning full training set
initial=false   # Set to true, if using models without adding 
                # artificial fillers as trained using run-0-fillers.sh
use_full_train_set=true # Use full train set rather than subset for training HMM-GMM model
train_mpe=false
use_word_lm=false

# End of configuration

. utils/parse_options.sh

if [ $# -ne 2 ]; then
  echo "Usage: $0 [options] <data-dir> <lang-dir>"
  echo " Options:"
  echo "    --initial (true|false)  # Set to true, if using models without adding 
                # artificial fillers as trained using run-0-fillers.sh"
  echo "    --nj <numjobs>    # Number of parallel jobs for training subset"
  echo "    --train-nj <numjobs>    # Number of parallel jobs for aligning full training set"
  echo "e.g.:"
  echo "$0 data data/lang"
  exit 1
fi

data=$1
lang=$2

tri4=tri4
tri4b=tri4b

if $initial; then
  tri4=tri4_initial
  tri4b=tri4b_initial
fi

[ ! -d $data/train_whole ] && echo "$0: Unable to find directory $data/train_whole. Run run-0-fillers.sh or run-1-main.sh first to prepare data directory" && exit 1

# Align train_whole_sub3 using tri4 models and train a LDA + MLLT model
# on it.

if $use_full_train_set; then
  if [ ! -f exp/${tri4}_whole_ali/.done ]; then
    steps/align_fmllr.sh --nj $nj --cmd "$train_cmd" \
      $data/train_whole $lang exp/$tri4 exp/${tri4}_whole_ali || exit 1;
    touch exp/${tri4}_whole_ali/.done
  fi

  if [ ! -f exp/${tri4b}_whole_seg/.done ]; then
    steps/train_lda_mllt.sh --cmd "$train_cmd" --realign-iters "" \
      1000 10000 $data/train_whole $lang exp/${tri4}_whole_ali exp/${tri4b}_whole_seg || exit 1;
    touch exp/${tri4b}_whole_seg/.done
  fi

  if $train_mpe; then
    if [ ! -f exp/${tri4b}_whole_denlats/.done ]; then
      steps/make_denlats.sh --cmd "$train_cmd" "${decode_extra_opts[@]}" --nj $nj \
        $data/train_whole $lang exp/${tri4b}_whole_seg \
        exp/${tri4b}_whole_denlats || exit 1
      touch exp/${tri4b}_whole_denlats/.done
    fi
    if [ ! -f exp/${tri4b}_whole_mpe_seg/.done ]; then
      steps/train_mpe.sh --cmd "$train_cmd" "${decode_extra_opts[@]}" \
        --boost 0.1 --cancel true \
        $data/train_whole $lang exp/${tri4}_whole_ali exp/${tri4b}_whole_denlats \
        exp/${tri4b}_whole_mpe_seg || exit 1
      touch exp/${tri4b}_whole_mpe_seg/.done
    fi
  fi

  (cd exp; ln -s ${tri4}_whole_ali ${tri4}_whole_ali_all)
else
  if [ ! -f exp/${tri4}_whole_ali_sub3/.done ]; then
    steps/align_fmllr.sh --nj $nj --cmd "$train_cmd" \
      $data/train_whole_sub3 $lang exp/$tri4 exp/${tri4}_whole_ali_sub3 || exit 1;
    touch exp/${tri4}_whole_ali_sub3/.done
  fi

  if [ ! -f exp/${tri4b}_whole_seg/.done ]; then
    steps/train_lda_mllt.sh --cmd "$train_cmd" --realign-iters "" \
      1000 10000 $data/train_whole_sub3 $lang exp/${tri4}_whole_ali_sub3 exp/${tri4b}_whole_seg || exit 1;
    touch exp/${tri4b}_whole_seg/.done
  fi

  # Align train_whole using tri4 models to get alignment for 
  # training phone language model
  if [ ! -f exp/${tri4}_whole_ali_all/.done ]; then
    steps/align_fmllr.sh --nj $train_nj --cmd "$train_cmd" \
      $data/train_whole $lang exp/${tri4} exp/${tri4}_whole_ali_all || exit 1;
    touch exp/${tri4}_whole_ali_all/.done
  fi
fi

if $train_mpe; then
  if [ ! -f exp/${tri4b}_whole_mpe_seg/graph.done ]; then
    # Make the phone decoding-graph.
    steps/make_phone_graph.sh $lang exp/${tri4}_whole_ali_all exp/${tri4b}_whole_mpe_seg || exit 1;
    touch exp/${tri4b}_whole_mpe_seg/graph.done
  fi
else
  if [ ! -f exp/${tri4b}_whole_seg/graph.done ]; then
    # Make the phone decoding-graph.
    steps/make_phone_graph.sh $lang exp/${tri4}_whole_ali_all exp/${tri4b}_whole_seg || exit 1;
    touch exp/${tri4b}_whole_seg/graph.done
  fi
fi

if $use_word_lm; then
  utils/mkgraph.sh $lang exp/${tri4b}_whole_seg exp/${tri4b}_whole_seg/graph | tee exp/${tri4b}_whole_seg/mkgraph.log || exit 1
fi
