#!/bin/bash


#Run decoding of the
#DEVTRAIN
#UNTRANSCRIBED
#This yields approx 70 hours of data

set -e           #Exit on non-zero return code from any command
set -o pipefail  #Exit if any of the commands in the pipeline will
                 #return non-zero return code

. conf/common_vars.sh || exit 1;
. ./lang.conf || exit 1;
. cmd.sh
. path.sh
. conf/common.semisupervised.limitedLP

set -u           #Fail on an undefined variable

segmentation_opts=( --isolated-resegmentation --min-inter-utt-silence-length 1.0 --silence-proportion 0.05 )
nj=32
train_stage=-100
. ./utils/parse_options.sh

if [ ! -f exp/tri6_nnet_supervised_tuning/.done ]; then
  steps/nnet2/update_pnorm.sh \
    --stage $train_stage --mix-up $dnn_mixup \
    --learning-rates "0:0:0:0.0008" \
    --max-change $dnn_max_change \
    --cmd "$train_cmd" \
    "${dnn_gpu_parallel_opts[@]}" \
    --transform-dir exp/tri5_ali \
    data/train \
    data/lang exp/tri6_nnet_ali exp/tri6_nnet_semi_supervised exp/tri6_nnet_supervised_tuning || exit 1

  #steps/nnet2/train_pnorm_semi_supervised.sh \
  #  --stage $train_stage --mix-up $dnn_mixup \
  #  --initial-learning-rate $dnn_init_learning_rate \
  #  --final-learning-rate $dnn_final_learning_rate \
  #  --num-hidden-layers $dnn_num_hidden_layers \
  #  --pnorm-input-dim $dnn_input_dim \
  #  --pnorm-output-dim $dnn_output_dim \
  #  --max-change $dnn_max_change \
  #  --cmd "$train_cmd" \
  #  "${dnn_cpu_parallel_opts[@]}" \
  #  --transform-dir-sup exp/tri5_ali --transform-dir-unsup exp/tri5/decode_${dirid} \
  #  data/train data/${dirid} \
  #  data/lang exp/tri6_nnet_ali $decode exp/tri6_nnet_semi_supervised || exit 1

  touch exp/tri6_nnet_supervised_tuning/.done
fi
