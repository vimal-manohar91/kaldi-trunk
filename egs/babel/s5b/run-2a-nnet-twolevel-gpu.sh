#!/bin/bash

. conf/common_vars.sh
. ./lang.conf

# This parameter will be used when the training dies at a certain point.
train_stage=-100
twolevel_extra_opts=
limit_rank_iters=""
. ./utils/parse_options.sh

set -e
set -o pipefail
set -u

# Wait till the main run.sh gets to the stage where's it's 
# finished aligning the tri5 model.
echo "Waiting till exp/tri5_ali/.done exists...."
while [ ! -f exp/tri5_ali/.done ]; do sleep 30; done
echo "...done waiting for exp/tri5_ali/.done"

if [ ! -f exp/tri6_nnet2/.done ]; then
  steps/nnet2/train_pnorm2.sh \
    --stage $train_stage \
    --initial-learning-rate $dnn_init_learning_rate \
    --final-learning-rate $dnn_final_learning_rate \
    --num-hidden-layers $dnn_num_hidden_layers \
    --pnorm-input-dim $dnn_input_dim \
    --pnorm-output-dim $dnn_output_dim \
    --cmd "$train_cmd" \
    "${dnn_gpu_parallel_opts[@]}" \
    $twolevel_extra_opts --limit-rank-iters "$limit_rank_iters" \
    5000 data/train data/lang exp/tri5_ali exp/tri6_nnet2 || exit 1

  touch exp/tri6_nnet2/.done
fi
