#!/bin/bash 
set -e
set -o pipefail

. conf/common_vars.sh || exit 1;
. ./lang.conf || exit 1;

tri5_only=false
type=dev10h
dev2shadow=dev10h
eval2shadow=eval
data_only=false
fast_path=true
skip_kws=false
skip_stt=false
max_states=150000
wip=0.5
fmllr_beam=10
fmllr_latbeam=4
my_nj=32

. utils/parse_options.sh

if $tri5_only; then
  fast_path=false
fi

if [ $# -ne 1 ]; then
  echo "Usage: $(basename $0) --type (dev10h|dev2h|eval|shadow) <data-dir>"
  exit 1
fi

if [[ "$type" != "dev10h" && "$type" != "dev2h" && "$type" != "eval" && "$type" != "shadow" ]] ; then
  echo "Warning: invalid variable type=${type}, valid values are dev10h|dev2h|eval"
  echo "Hope you know what your ar doing!"
fi

datadir=$1
dirid=`basename $1`

function make_plp {
  t=$1
  if $use_pitch; then
    steps/make_plp_pitch.sh --cmd "$decode_cmd" --nj $my_nj data/${t} exp/make_plp_pitch/${t} plp
  else
    steps/make_plp.sh --cmd "$decode_cmd" --nj $my_nj data/${t} exp/make_plp/${t} plp
  fi
  utils/fix_data_dir.sh data/${t}
  steps/compute_cmvn_stats.sh data/${t} exp/make_plp/${t} plp
  utils/fix_data_dir.sh data/${t}
}

####################################################################
##
## FMLLR decoding 
##
####################################################################
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
  steps/decode_fmllr_extra.sh --skip-scoring true --beam $fmllr_beam --lattice-beam $fmllr_latbeam\
    --nj $my_nj --cmd "$decode_cmd" "${decode_extra_opts[@]}"\
    exp/tri5/graph ${datadir} ${decode} |tee ${decode}/decode.log
  touch ${decode}/.done
fi

if ! $fast_path ; then
  local/run_kws_stt_task.sh --cer $cer --max-states $max_states \
    --cmd "$decode_cmd" --skip-kws $skip_kws --skip-stt $skip_stt --wip $wip \
    "${shadow_set_extra_opts[@]}" "${lmwt_plp_extra_opts[@]}" \
    ${datadir} data/lang ${decode}

  local/run_kws_stt_task.sh --cer $cer --max-states $max_states \
    --cmd "$decode_cmd" --skip-kws $skip_kws --skip-stt $skip_stt --wip $wip \
    "${shadow_set_extra_opts[@]}" "${lmwt_plp_extra_opts[@]}" \
    ${datadir} data/lang ${decode}.si
fi

if $tri5_only; then
  exit 0
fi

####################################################################
## SGMM2 decoding 
####################################################################
decode=exp/sgmm5/decode_fmllr_${dirid}
if [ -f `dirname $decode`/.done ] && [ ! -f $decode/.done ]; then
  echo ---------------------------------------------------------------------
  echo "Spawning $decode on" `date`
  echo ---------------------------------------------------------------------
  utils/mkgraph.sh \
    data/lang exp/sgmm5 exp/sgmm5/graph |tee exp/sgmm5/mkgraph.log

  mkdir -p $decode
  steps/decode_sgmm2.sh --skip-scoring true --use-fmllr true --nj $my_nj \
    --cmd "$decode_cmd" --transform-dir exp/tri5/decode_${dirid} "${decode_extra_opts[@]}"\
    exp/sgmm5/graph ${datadir} $decode |tee $decode/decode.log
  touch $decode/.done

  if ! $fast_path ; then
    local/run_kws_stt_task.sh --cer $cer --max-states $max_states \
      --cmd "$decode_cmd" --skip-kws $skip_kws --skip-stt $skip_stt --wip $wip \
      "${shadow_set_extra_opts[@]}" "${lmwt_plp_extra_opts[@]}" \
      ${datadir} data/lang  exp/sgmm5/decode_fmllr_${dirid}
  fi
fi

####################################################################
##
## SGMM_MMI rescoring
##
####################################################################

for iter in 1 2 3 4; do
    # Decode SGMM+MMI (via rescoring).
  decode=exp/sgmm5_mmi_b0.1/decode_fmllr_${dirid}_it$iter
  if [ ! -f $decode/.done ]; then

    mkdir -p $decode
    steps/decode_sgmm2_rescore.sh  --skip-scoring true \
      --cmd "$decode_cmd" --iter $iter --transform-dir exp/tri5/decode_${dirid} \
      data/lang ${datadir} exp/sgmm5/decode_fmllr_${dirid} $decode | tee ${decode}/decode.log

    touch $decode/.done
  fi
done

if ! $skip_kws || ! $skip_stt; then
  #We are done -- all lattices has been generated. We have to
  #a)Run MBR decoding
  #b)Run KW search
  for iter in 1 2 3 4; do
    # Decode SGMM+MMI (via rescoring).
    decode=exp/sgmm5_mmi_b0.1/decode_fmllr_${dirid}_it$iter
    local/run_kws_stt_task.sh --cer $cer --max-states $max_states \
      --cmd "$decode_cmd" --skip-kws $skip_kws --skip-stt $skip_stt --wip $wip \
      "${shadow_set_extra_opts[@]}" "${lmwt_plp_extra_opts[@]}" \
      ${datadir} data/lang $decode
  done
fi


####################################################################
##
## DNN ("compatibility") decoding -- also, just decode the "default" net
##
####################################################################
decode=exp/tri6_nnet/decode_${dirid}
if [ -f exp/tri6_nnet/.done ]; then
  if [ ! -f $decode/.done ]; then
    mkdir -p $decode
    steps/nnet2/decode.sh --cmd "$decode_cmd" --nj $my_nj \
      --beam $dnn_beam --lat-beam $dnn_lat_beam \
      --skip-scoring true "${decode_extra_opts[@]}" \
      --transform-dir exp/tri5/decode_${dirid} \
      exp/tri5/graph ${datadir} $decode | tee $decode/decode.log

    touch $decode/.done
  fi

  if ! $skip_kws || ! $skip_stt; then
    local/run_kws_stt_task.sh --cer $cer --max-states $max_states \
      --cmd "$decode_cmd" --skip-kws $skip_kws --skip-stt $skip_stt --wip $wip \
      "${shadow_set_extra_opts[@]}" "${lmwt_dnn_extra_opts[@]}" \
      ${datadir} data/lang $decode
  fi 
fi

####################################################################
##
## DNN (nextgen DNN) decoding
##
####################################################################
if [ -f exp/tri6a_nnet/.done ]; then
  decode=exp/tri6a_nnet/decode_${dirid}
  if [ ! -f $decode/.done ]; then
    mkdir -p $decode
    steps/nnet2/decode.sh --cmd "$decode_cmd" --nj $my_nj \
      --beam $dnn_beam --lat-beam $dnn_lat_beam \
      --skip-scoring true "${decode_extra_opts[@]}" \
      --transform-dir exp/tri5/decode_${dirid} \
      exp/tri5/graph ${datadir} $decode | tee $decode/decode.log

    touch $decode/.done
  fi

  local/run_kws_stt_task.sh --cer $cer --max-states $max_states \
    --cmd "$decode_cmd" --skip-kws $skip_kws --skip-stt $skip_stt --wip $wip \
    "${shadow_set_extra_opts[@]}" "${lmwt_dnn_extra_opts[@]}" \
    ${datadir} data/lang $decode
fi

####################################################################
##
## DNN (ensemble) decoding
##
####################################################################
if [ -f exp/tri6b_nnet/.done ]; then
  decode=exp/tri6b_nnet/decode_${dirid}
  if [ ! -f $decode/.done ]; then
    mkdir -p $decode
    steps/nnet2/decode.sh --cmd "$decode_cmd" --nj $my_nj \
      --beam $dnn_beam --lat-beam $dnn_lat_beam \
      --skip-scoring true "${decode_extra_opts[@]}" \
      --transform-dir exp/tri5/decode_${dirid} \
      exp/tri5/graph ${datadir} $decode | tee $decode/decode.log

    touch $decode/.done
  fi

  local/run_kws_stt_task.sh --cer $cer --max-states $max_states \
    --cmd "$decode_cmd" --skip-kws $skip_kws --skip-stt $skip_stt --wip $wip \
    "${shadow_set_extra_opts[@]}" "${lmwt_dnn_extra_opts[@]}" \
    ${datadir} data/lang $decode
fi
if [ -f exp/tri6_nnet_semi_supervised/.done ]; then
  decode=exp/tri6_nnet_semi_supervised/decode_${dirid}
  if [ ! -f $decode/.done ]; then
    mkdir -p $decode
    steps/nnet2/decode.sh --cmd "$decode_cmd" --nj $my_nj \
      --beam $dnn_beam --lat-beam $dnn_lat_beam \
      --skip-scoring true "${decode_extra_opts[@]}" \
      --transform-dir exp/tri5/decode_${dirid} \
      exp/tri5/graph ${datadir} $decode | tee $decode/decode.log

    touch $decode/.done
  fi

  local/run_kws_stt_task.sh --cer $cer --max-states $max_states \
    --cmd "$decode_cmd" --skip-kws $skip_kws --skip-stt $skip_stt --wip $wip \
    "${shadow_set_extra_opts[@]}" "${lmwt_dnn_extra_opts[@]}" \
    ${datadir} data/lang $decode
fi

if [ -f exp/tri6_nnet_supervised_tuning/.done ]; then
  decode=exp/tri6_nnet_supervised_tuning/decode_${dirid}
  if [ ! -f $decode/.done ]; then
    mkdir -p $decode
    steps/nnet2/decode.sh --cmd "$decode_cmd" --nj $my_nj \
      --beam $dnn_beam --lat-beam $dnn_lat_beam \
      --skip-scoring true "${decode_extra_opts[@]}" \
      --transform-dir exp/tri5/decode_${dirid} \
      exp/tri5/graph ${datadir} $decode | tee $decode/decode.log

    touch $decode/.done
  fi

  local/run_kws_stt_task.sh --cer $cer --max-states $max_states \
    --cmd "$decode_cmd" --skip-kws $skip_kws --skip-stt $skip_stt --wip $wip \
    "${shadow_set_extra_opts[@]}" "${lmwt_dnn_extra_opts[@]}" \
    ${datadir} data/lang $decode
fi
####################################################################
##
## DNN_MPE decoding
##
####################################################################
if [ -f exp/tri6_nnet_mpe/.done ]; then
  for epoch in 1 2 3 4; do
    decode=exp/tri6_nnet_mpe/decode_${dirid}_epoch$epoch
    if [ ! -f $decode/.done ]; then
      mkdir -p $decode
      steps/nnet2/decode.sh \
        --cmd "$decode_cmd" --nj $my_nj --iter epoch$epoch \
        --beam $dnn_beam --lat-beam $dnn_lat_beam \
        --skip-scoring true "${decode_extra_opts[@]}" \
        --transform-dir exp/tri5/decode_${dirid} \
        exp/tri5/graph ${datadir} $decode | tee $decode/decode.log

      touch $decode/.done
    fi

    local/run_kws_stt_task.sh --cer $cer --max-states $max_states \
      --cmd "$decode_cmd" --skip-kws $skip_kws --skip-stt $skip_stt --wip $wip \
      "${shadow_set_extra_opts[@]}" "${lmwt_dnn_extra_opts[@]}" \
      ${datadir} data/lang $decode
  done
fi

echo "Everything looking good...." 
exit 0
