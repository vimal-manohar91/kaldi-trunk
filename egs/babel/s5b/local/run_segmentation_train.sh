#!/bin/bash

set -o pipefail
#set -e

. cmd.sh
. lang.conf

nj=16             # nj for training subset of whole
train_nj=32       # nj for aligning full training set
boost_sil=1.0

# End of configuration

. utils/parse_options.sh

if [ $# -ne 3 ]; then
  echo "Usage: $0 [options] <model-dir> <data-dir> <lang-dir>"
  echo " Options:"
  echo "    --nj <numjobs>    # Number of parallel jobs for training subset"
  echo "    --train-nj <numjobs>    # Number of parallel jobs for aligning full training set"
  echo "e.g.:"
  echo "$0 exp/tri4 data data/lang"
  exit 1
fi

model_dir=$1          # Model used for alignment
train_data_dir=$2
lang=$3

[ ! -d $train_data_dir ] && echo "$0: Unable to find directory $train_data_dir. Run run-0-fillers.sh or run-1-main.sh first to prepare data directory" && exit 1

# Align train_whole_sub3 using tri4 models and train a LDA + MLLT model
# on it.

if [ ! -f ${model_dir}_train_seg_ali/.done ]; then
  steps/align_fmllr.sh --nj $nj --cmd "$train_cmd" --boost-silence $boost_sil \
    $train_data_dir $lang $model_dir ${model_dir}_train_seg_ali || exit 1;
  touch ${model_dir}_train_seg_ali/.done
fi

if [ ! -f ${model_dir}b_seg/.done ]; then
  steps/train_lda_mllt.sh --cmd "$train_cmd" --realign-iters "" --boost-silence $boost_sil \
    1000 10000 $train_data_dir $lang ${model_dir}_train_seg_ali ${model_dir}b_seg || exit 1;
  touch ${model_dir}b_seg/.done
fi

if [ ! -f ${model_dir}b_seg/graph.done ]; then
  # Make the phone decoding-graph.
  steps/make_phone_graph.sh $lang ${model_dir}_train_seg_ali ${model_dir}b_seg || exit 1;
  utils/mkgraph.sh $lang ${model_dir}b_seg ${model_dir}b_seg/graph | tee ${model_dir}b_seg/mkgraph.log || exit 1
  touch ${model_dir}b_seg/graph.done
fi
