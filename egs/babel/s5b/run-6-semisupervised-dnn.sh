#!/bin/bash

# Copyright 2014  Vimal Manohar
# Apache 2.0

# Run DNN training on untranscribed data
# This uses approx 70 hours of untranscribed data

set -e           #Exit on non-zero return code from any command
set -o pipefail  #Exit if any of the commands in the pipeline will
                 #return non-zero return code

. conf/common_vars.sh || exit 1;
. ./lang.conf || exit 1;
. cmd.sh
. path.sh

# Can provide different neural net structure than for supervised data
[ -f conf/common.semisupervised.limitedLP ] && . conf/common.semisupervised.limitedLP    

#debugging stuff
echo $0 $@

train_stage=-100
nj=32
weight_threshold=0.7

. parse_options.sh || exit 1

if [ $# -ne 1 ]; then
  echo "Usage: $0 [options] <untranscribed-data-dir> <ali-dir> [<decode-dir1>[:weight] <decode-dir2>[:weight] ...] <out-decode-dir>" 
  echo 
  echo "--nj  <num_jobs>      # Number of parallel jobs for decoding untranscribed data"
  echo "e.g.: "
  echo "$0 data/train_unt.seg exp/tri6_nnet_ali exp/tri6_nnet/decode_train_unt.seg:1.0 exp/sgmm5_mmi_b0.1/decode_fmllr_train_unt.seg_it2:1.0"
  exit 1
fi

untranscribed_datadir=$1
ali_dir=$2
dir=${@: -1}  # last argument to the script
shift 2;
decode_dirs=( $@ )  # read the remaining arguments into an array
unset decode_dirs[${#decode_dirs[@]}-1]  # 'pop' the last argument which is odir
num_sys=${#decode_dirs[@]}  # number of systems to combine

###############################################################################
#
# Supervised data alignment
#
###############################################################################

if [ ! -f $ali_dir/.done ]; then
  # If ali_dir is not done yet, the make new alignment directory
  # in exp/tri6_nnet_ali
  ali_dir=exp/tri6_nnet_ali
  if [ ! -f $ali_dir/.done ]; then
    echo "$0: Aligning supervised training data in $ali_dir"
    [ ! -f exp/tri6_nnet/final.mdl ] && echo "exp/tri6_nnet/final.mdl not found!\nRun run-6-nnet.sh first!" && exit 1
    if [ ! -f exp/tri6_nnet_ali/.done ]; then
      steps/nnet2/align.sh  --cmd "$decode_cmd" \
        --use-gpu no --transform-dir exp/tri5_ali --nj $train_nj \
        data/train data/lang exp/tri6_nnet exp/tri6_nnet_ali || exit 1
      touch exp/tri6_nnet_ali/.done
    fi
  fi
else
  echo "$0: Using supervised data alignments from $ali_dir"
fi

###############################################################################
#
# Unsupervised data decoding
#
###############################################################################

if [ ! -f $dir/.done ]; then
  if [ $num_sys -eq 0 ]; then
    local/combine_posteriors.sh --cmd "$decode_cmd" $untranscribed_datadir data/lang \
      $dir $dir || exit 1
  else
    local/combine_posteriors.sh --cmd "$decode_cmd" $untranscribed_datadir data/lang \
      ${decode_dirs[@]} $dir || exit 1
  fi
fi

if [ -z $decode_dir ] ; then
  [ ! -z $untranscribed_datadir ] && echo "Both --decode-dir and --untranscribed-datadir not specified!" && exit 1
  
  echo "$0: Decoding unsupervised data from $untranscribed_datadir using exp/tri6_nnet models"
  
  [ ! -f exp/tri6_nnet/final.mdl ] && echo "exp/tri6_nnet/final.mdl not found!\nRun run-6-nnet.sh first!" && exit 1

  datadir=$untranscribed_datadir
  dirid=`basename $datadir`

  decode=exp/tri5/decode_${dirid}
  if [ ! -f ${decode}/.done ]; then
    echo ---------------------------------------------------------------------
    echo "Spawning decoding with SAT models  on" `date`
    echo ---------------------------------------------------------------------
    utils/mkgraph.sh \
      data/lang exp/tri5 exp/tri5/graph |tee exp/tri5/mkgraph.log

    mkdir -p $decode
    #By default, we do not care about the lattices for this step -- we just want the transforms
    #Therefore, we will reduce the beam sizes, to reduce the decoding times
    steps/decode_fmllr_extra.sh --skip-scoring true --beam 10 --lattice-beam 4\
      --nj $nj --cmd "$decode_cmd" "${decode_extra_opts[@]}"\
      exp/tri5/graph ${datadir} ${decode} |tee ${decode}/decode.log
    touch ${decode}/.done
  fi

  decode=exp/tri6_nnet/decode_${dirid}
  if [ ! -f $decode/.done ]; then
    mkdir -p $decode
    steps/nnet2/decode.sh --cmd "$decode_cmd" --nj $nj \
      --beam $dnn_beam --lat-beam $dnn_lat_beam \
      --skip-scoring true "${decode_extra_opts[@]}" \
      --transform-dir exp/tri5/decode_${dirid} \
      exp/tri5/graph ${datadir} $decode | tee $decode/decode.log

    touch $decode/.done
  fi
else
  echo "$0: Using unsupervised data lattices from $decode_dir"
  decode=$decode_dir
fi

echo "$0: Getting frame posteriors for unsupervised data"
# Get per-frame weights (posteriors) by best path
if [ ! -f $decode/.best_path.done ]; then

  $decode_cmd JOB=1:$nj $decode/log/best_path_post.JOB.log \
    lattice-best-path-post --acoustic-scale=0.1 \
    "ark,s,cs:gunzip -c $decode/lat.JOB.gz |" \
    "ark:| gzip -c > $decode/best_path_ali.JOB.gz" \
    "ark:| gzip -c > $decode/weights.JOB.gz" || exit 1
  touch $decode/.best_path.done
fi

###############################################################################
#
# Semi-supervised DNN training
#
###############################################################################

if [ ! -f exp/tri6_nnet_semi_supervised/.done ]; then
  local/nnet2/train_pnorm_semi_supervised.sh \
    --stage $train_stage --mix-up $dnn_mixup \
    --initial-learning-rate $dnn_init_learning_rate \
    --final-learning-rate $dnn_final_learning_rate \
    --num-hidden-layers $dnn_num_hidden_layers \
    --pnorm-input-dim $dnn_input_dim \
    --pnorm-output-dim $dnn_output_dim \
    --max-change $dnn_max_change \
    --num-epochs $num_epochs \
    --num-epochs-extra $num_epochs_extra \
    --num-iters-final $num_iters_final \
    --cmd "$train_cmd" \
    "${dnn_gpu_parallel_opts[@]}" \
    --transform-dir-sup exp/tri5_ali --transform-dir-unsup exp/tri5/decode_${dirid} --weight_threshold $weight_threshold \
    data/train $untranscribed_datadir \
    data/lang $ali_dir $decode exp/tri6_nnet_semi_supervised || exit 1

  touch exp/tri6_nnet_semi_supervised/.done
fi

if [ ! -f exp/tri6_nnet_supervised_tuning/.done ]; then
  steps/nnet2/update_pnorm.sh \
    --stage $train_stage --mix-up $dnn_mixup \
    --learning-rates "0:0:0:0.0008" \
    --max-change $dnn_max_change \
    --cmd "$train_cmd" \
    "${dnn_gpu_parallel_opts[@]}" \
    --num-epochs 2 --num-iters-final 5 \
    --transform-dir exp/tri5_ali \
    data/train \
    data/lang $ali_dir exp/tri6_nnet_semi_supervised exp/tri6_nnet_supervised_tuning || exit 1

  touch exp/tri6_nnet_supervised_tuning/.done
fi
