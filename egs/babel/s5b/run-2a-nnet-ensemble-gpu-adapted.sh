#!/bin/bash

. conf/common_vars.sh
. ./lang.conf

set -e
set -o pipefail
set -u

dnn_num_hidden_layers=4
dnn_pnorm_input_dim=4000
dnn_pnorm_output_dim=400
dnn_init_learning_rate=0.004
dnn_final_learning_rate=0.001
train_stage=-3
temp_dir=`pwd`/nnet_gpu_egs
ensemble_size=4
dir=exp/tri6b_nnet_adapted
egs_dir=

# Wait till the main run.sh gets to the stage where's it's 
# finished aligning the tri5 model.
echo "Waiting till exp/tri5_ali/.done exists...."
while [ ! -f exp/tri5_ali/.done ]; do sleep 30; done
echo "...done waiting for exp/tri5_ali/.done"

if [ ! -f $dir/.done ]; then
  steps/nnet2/train_pnorm_adapted.sh \
    --stage $train_stage --mix-up $dnn_mixup --egs-dir "$egs_dir" \
    --initial-learning-rate $dnn_init_learning_rate \
    --final-learning-rate $dnn_final_learning_rate \
    --num-hidden-layers $dnn_num_hidden_layers \
    --pnorm-input-dim $dnn_pnorm_input_dim \
    --pnorm-output-dim $dnn_pnorm_output_dim \
    --cmd "$train_cmd" \
    "${dnn_gpu_parallel_opts[@]}" \
    --ensemble-size $ensemble_size --oldmdl-dir "exp/tri6b_nnet" \
    data/train data/lang exp/tri5_ali $dir || exit 1
  touch $dir/.done
fi

