#!/bin/bash

set -o pipefail
#set -e

. cmd.sh
. lang.conf

nj=16             # nj for training subset of whole
train_nj=32       # nj for aligning full training set
boost_sil=1.0
ext_alidir=       # Use this alignment directory instead for getting new one

# End of configuration

. utils/parse_options.sh

if [ $# -ne 4 ]; then
  echo "Usage: $0 [options] <in-model-dir> <data-dir> <lang-dir> <out-model-dir>"
  echo " Options:"
  echo "    --nj <numjobs>    # Number of parallel jobs for training subset"
  echo "    --train-nj <numjobs>    # Number of parallel jobs for aligning full training set"
  echo "e.g.:"
  echo "$0 exp/tri4 data/train data/lang exp/tri4b_seg"
  exit 1
fi

in_model_dir=$1          # Model used for alignment
train_data_dir=$2
lang=$3
out_model_dir=$4

[ ! -d $train_data_dir ] && echo "$0: Unable to find directory $train_data_dir. Run run-0-fillers.sh or run-1-main.sh first to prepare data directory" && exit 1

# Align train_whole_sub2 using tri4 models and train a LDA + MLLT model
# on it.
alidir=${in_model_dir}_train_seg_ali

if [ ! -z $ext_alidir ] && [ -s $ext_alidir/ali.1.gz ]; then
  alidir=$ext_alidir
elif [ ! -f ${alidir}_sub2/.done ]; then
  steps/align_fmllr.sh --nj $nj --cmd "$train_cmd" --boost-silence $boost_sil \
    ${train_data_dir}_sub2 $lang $in_model_dir ${alidir}_sub2 || exit 1;
  touch ${alidir}_sub2/.done
fi

if [ ! -f $out_model_dir/.done ]; then
  steps/train_lda_mllt.sh --cmd "$train_cmd" --realign-iters "" --boost-silence $boost_sil \
    1000 10000 ${train_data_dir}_sub2 $lang ${alidir}_sub2 $out_model_dir || exit 1;
  touch $out_model_dir/.done
fi
  
if [ ! -f $alidir/.done ]; then
  steps/align_fmllr.sh --nj $nj --cmd "$train_cmd" --boost-silence $boost_sil \
    ${train_data_dir} $lang $out_model_dir ${alidir} || exit 1;
fi

if [ ! -f $out_model_dir/graph.done ]; then
  # Make the phone decoding-graph.
  steps/make_phone_graph.sh $lang $alidir $out_model_dir || exit 1;
  utils/mkgraph.sh $lang $out_model_dir $out_model_dir/graph | tee $out_model_dir/mkgraph.log || exit 1
  touch $out_model_dir/graph.done
fi

