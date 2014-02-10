#!/bin/bash

# Run decoding of the untranscribed data
# This yields approx 70 hours of data

set -e           #Exit on non-zero return code from any command
set -o pipefail  #Exit if any of the commands in the pipeline will
                 #return non-zero return code

. conf/common_vars.sh || exit 1;
. ./lang.conf || exit 1;
. cmd.sh
. path.sh

# Can provide different neural net structure than for supervised data
. conf/common.semisupervised.limitedLP    

#debugging stuff
echo $0 $@

target=.
train_stage=-100

. parse_options.sh || exit 1

if [ $# -ne 1 ]; then
  echo "Usage: $0 [options] <untranscribed-data-dir>"
  echo 
  echo "e.g.:"
  echo "$0 data/train_unt.seg"
  exit 1
fi

untranscribed_datadir=$1

[ ! -f exp/tri6_nnet/final.mdl ] && [ ! -f exp/tri6_nnet_supervised/final.mdl ] && echo "exp/tri6_nnet/final.mdl not found!\nRun run-6-nnet.sh first!" && exit 1

if [ `readlink -f $target` != `readlink -f .` ]; then
  if [ ! -d $target ]; then
    echo ---------------------------------------------------------------------
    echo "Creating directory $target for the semi-supervised trained system"
    echo ---------------------------------------------------------------------
    mkdir -p $target
    for x in steps utils local conf lang.conf *.sh; do
      [ ! -s $x ] && echo "No such file or directory $x" && exit 1;
      if [ -L $x ]; then # if these are links
        cp -d $x $target # copy the link over.
      else # create a link to here.
        ln -s ../`basename $PWD`/$x $target
      fi
    done
  fi

  if [ ! -d $target/exp/ ]; then
    cp -r data $target/data
    [ -L expts ] && cp -d expts $target
    if [ -d $target/expts/ ]; then
      (
      cd $target
      name=exp_semi_supervised.$$
      mkdir -p $target/expts/$name
      [ -L exp ] && rm exp
      ln -s $target/expts/$name exp
      )
    else
      mkdir -p $target/exp
    fi
  fi
else
  echo "$target cannot be the current directory!" && exit 1
fi

( 
  old=`pwd`

  cd $target
  [ ! -d exp/ ] && echo "$target/exp: No such file or directory!" && exit 1

  (
  cd exp
  [ -L tri5 ] && rm tri5
  [ -L tri6_nnet_supervised ] && rm tri6_nnet_supervised
  [ -L tri6_nnet_supervised_ali ] && rm tri6_nnet_supervised_ali

  ln -s $old/exp/tri5 .
  ln -s $old/exp/tri6_nnet tri6_nnet_supervised
  [ -d $old/exp/tri6_nnet_ali ] && ln -s $old/exp/tri6_nnet_ali tri6_nnet_supervised_ali
  )
  ###############################################################################
  #
  # Supervised data alignment
  #
  ###############################################################################

  if [ ! -f exp/tri6_nnet_supervised_ali/.done ]; then
    steps/nnet2/align.sh  --cmd "$decode_cmd" \
      --use-gpu no --transform-dir exp/tri5_ali --nj $train_nj \
      data/train data/lang exp/tri6_nnet_supervised exp/tri6_nnet_supervised_ali || exit 1
    touch exp/tri6_nnet_supervised_ali/.done
  fi

  ###############################################################################
  #
  # Unsupervised data decoding
  #
  ###############################################################################

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

  decode=exp/tri6_nnet_supervised/decode_${dirid}
  if [ ! -f $decode/.done ]; then
    mkdir -p $decode
    steps/nnet2/decode.sh --cmd "$decode_cmd" --nj $nj \
      --beam $dnn_beam --lat-beam $dnn_lat_beam \
      --skip-scoring true "${decode_extra_opts[@]}" \
      --transform-dir exp/tri5/decode_${dirid} \
      exp/tri5/graph ${datadir} $decode | tee $decode/decode.log

    touch $decode/.done
  fi

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
    steps/nnet2/train_pnorm_semi_supervised.sh \
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
      --transform-dir-sup exp/tri5_ali --transform-dir-unsup exp/tri5/decode_${dirid} \
      data/train data/${dirid} \
      data/lang exp/tri6_nnet_supervised_ali $decode exp/tri6_nnet_semi_supervised || exit 1

    touch exp/tri6_nnet_semi_supervised/.done
  fi

  if [ ! -f exp/tri6_nnet/.done ]; then
    steps/nnet2/update_pnorm.sh \
      --stage $train_stage --mix-up $dnn_mixup \
      --learning-rates "0:0:0:0:0.0008" \
      --max-change $dnn_max_change \
      --cmd "$train_cmd" \
      "${dnn_gpu_parallel_opts[@]}" \
      --transform-dir exp/tri5_ali \
      data/train \
      data/lang exp/tri6_nnet_supervised_ali exp/tri6_nnet_semi_supervised exp/tri6_nnet || exit 1

    touch exp/tri6_nnet/.done
  fi
)
