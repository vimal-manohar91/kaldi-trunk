#!/bin/bash

# This is not necessarily the top-level run.sh as it is in other directories.   see README.txt first.

[ ! -f ./lang.conf ] && echo "Language configuration does not exist! Use the configurations in conf/lang/* as a startup" && exit 1
[ ! -f ./conf/common_vars.sh ] && echo "the file conf/common_vars.sh does not exist!" && exit 1

. conf/common_vars.sh || exit 1;
. ./lang.conf || exit 1;

[ -f local.conf ] && . ./local.conf

set -e           #Exit on non-zero return code from any command
set -o pipefail  #Exit if any of the commands in the pipeline will 
                 #return non-zero return code
#set -u           #Fail on an undefined variable

data=data
type=dev10h
dev2shadow=dev10h.seg
eval2shadow=eval.seg
data_only=false
fast_path=true
skip_kws=false
skip_stt=false
max_states=150000
wip=0.5
segmentation_opts="--isolated-resegmentation --min-inter-utt-silence-length 1.0 --silence-proportion 0.05"
tri5_only=false
use_word_lm=false
train_mpe=false
posterior_decode=false
penalize_long_phones=false
dm_scale=0.1
beam=7.0
max_active=1000
segment_length=60.0
use_viterbi_decode=false
allow_partial=true

use_vad=false
vad_boost=0.1
vad_threshold=1.5

. utils/parse_options.sh
. ./path.sh
. ./cmd.sh

if $tri5_only; then
  fast_path=false
fi

if [[ "$type" == "dev10h" || "$type" == "dev2h" ]] ; then
  eval reference_rttm=\$${type}_rttm_file
  [ -f $reference_rttm ] && segmentation_opts="$segmentation_opts --reference-rttm $reference_rttm"
fi

if [ $# -ne 0 ]; then
  echo "Usage: $(basename $0) --type (dev10h|dev2h|eval|shadow)"
  exit 1
fi

if [[ "$type" != "dev10h" && "$type" != "dev2h" && "$type" != "eval" && "$type" != "shadow" ]] ; then
  echo "Warning: invalid variable type=${type}, valid values are dev10h|dev2h|eval"
  echo "Hope you know what your ar doing!"
fi

if [ $type == shadow ] ; then
  shadow_set_extra_opts=(--dev2shadow ${data}/${dev2shadow} --eval2shadow ${data}/${eval2shadow} )
else
  shadow_set_extra_opts=()
fi

function make_plp {
  t=$1
  data=$2
  plpdir=$3

  if [ "$use_pitch" = "false" ] && [ "$use_ffv" = "false" ]; then
   steps/make_plp.sh --cmd "$decode_cmd" --nj $my_nj ${data}/${t} exp/make_plp/${t} ${plpdir}
  elif [ "$use_pitch" = "true" ] && [ "$use_ffv" = "true" ]; then
    cp -rT ${data}/${t} ${data}/${t}_plp; cp -rT ${data}/${t} ${data}/${t}_pitch; cp -rT ${data}/${t} ${data}/${t}_ffv
    steps/make_plp_pitch.sh --cmd "$decode_cmd" --nj $my_nj ${data}/${t}_plp_pitch exp/make_plp_pitch/${t} plp_tmp_${t}
    local/make_ffv.sh --cmd "$decode_cmd"  --nj $my_nj ${data}/${t}_ffv exp/make_ffv/${t} ffv_tmp_${t}
    steps/append_feats.sh --cmd "$decode_cmd" --nj $my_nj ${data}/${t}{_plp_pitch,_ffv,} exp/make_ffv/append_${t}_pitch_ffv ${plpdir}
    rm -rf {plp_pitch,ffv}_tmp_${t} ${data}/${t}_{plp_pitch,ffv}
  elif [ "$use_pitch" = "true" ]; then
    steps/make_plp_pitch.sh --cmd "$decode_cmd" --nj $my_nj ${data}/${t} exp/make_plp_pitch/${t} $plpdir
  elif [ "$use_ffv" = "true" ]; then
    cp -rT ${data}/${t} ${data}/${t}_plp; cp -rT ${data}/${t} ${data}/${t}_ffv
    steps/make_plp.sh --cmd "$decode_cmd" --nj $my_nj ${data}/${t}_plp exp/make_plp/${t} plp_tmp_${t}
    local/make_ffv.sh --cmd "$decode_cmd" --nj $my_nj ${data}/${t}_ffv exp/make_ffv/${t} ffv_tmp_${t}
    steps/append_feats.sh --cmd "$decode_cmd" --nj $my_nj ${data}/${t}{_plp,_ffv,} exp/make_ffv/append_${t} $plpdir
    rm -rf {plp,ffv}_tmp_${t} ${data}/${t}_{plp,ffv}
  fi

  utils/fix_data_dir.sh ${data}/${t}
  steps/compute_cmvn_stats.sh ${data}/${t} exp/make_plp/${t} $plpdir
  utils/fix_data_dir.sh ${data}/${t}
}

if [ ${type} == shadow ] ; then
  mandatory_variables=""
  optional_variables=""
else
  mandatory_variables="${type}_data_dir ${type}_data_list ${type}_stm_file \
    ${type}_ecf_file ${type}_kwlist_file ${type}_rttm_file ${type}_nj"
  optional_variables="${type}_subset_ecf "
fi

eval my_data_dir=\$${type}_data_dir
eval my_data_list=\$${type}_data_list
eval my_stm_file=\$${type}_stm_file


eval my_ecf_file=\$${type}_ecf_file 
eval my_subset_ecf=\$${type}_subset_ecf 
eval my_kwlist_file=\$${type}_kwlist_file 
eval my_rttm_file=\$${type}_rttm_file
eval my_nj=\$${type}_nj  #for shadow, this will be re-set when appropriate

for variable in $mandatory_variables ; do
  eval my_variable=\$${variable}
  if [ $type == "dev10h" ] || [ $type == "dev2h" ] || [ $type == "eval" ]; then
    if [ -z $my_variable ] ; then
      echo "Mandatory variable $variable is not set! " \
        "You should probably set the variable in the config file "
      exit 1
    else
      echo "$variable=$my_variable"
    fi
  fi
done

for variable in $option_variables ; do
  eval my_variable=\$${variable}
  echo "$variable=$my_variable"
done

datadir=${data}/${type}
dirid=${type}

if [[ $type == shadow ]] ; then
  if [ ! -f ${datadir}/shadow.done ]; then
    # we expect that the ${dev2shadow} as well as ${eval2shadow} already exist
    if [ ! -f ${data}/${dev2shadow}/.done ]; then
      echo "Error: ${data}/${dev2shadow}/.done does not exist."
      echo "Create the directory ${data}/${dev2shadow} first, by calling $0 --type $dev2shadow --dataonly"
      exit 1
    fi
    if [ ! -f ${data}/${eval2shadow}/.done ]; then
      echo "Error: ${data}/${eval2shadow}/.done does not exist."
      echo "Create the directory ${data}/${eval2shadow} first, by calling $0 --type $eval2shadow --dataonly"
      exit 1
    fi

    local/create_shadow_dataset.sh ${datadir} ${data}/${dev2shadow} ${data}/${eval2shadow}
    utils/fix_data_dir.sh ${datadir}
    touch ${datadir}/shadow.done
  fi
  my_nj=$eval_nj
else
  if [ ! -d ${data}/raw_${type}_data ]; then
    echo ---------------------------------------------------------------------
    echo "Subsetting the ${type} set"
    echo ---------------------------------------------------------------------
    
    local/make_corpus_subset.sh "$my_data_dir" "$my_data_list" ./${data}/raw_${type}_data
  fi
  my_data_dir=`readlink -f ./${data}/raw_${type}_data`

  nj_max=`cat $my_data_list | wc -l`
  if [[ "$nj_max" -lt "$my_nj" ]] ; then
    echo "The maximum reasonable number of jobs is $nj_max -- you have $my_nj! (The training and decoding process has file-granularity)"
    exit 1
    my_nj=$nj_max
  fi
  
  if [ ! -f ${datadir}/.done ]; then
    mkdir -p ${datadir}
    
    if [[ ! -f ${datadir}/wav.scp || ${datadir}/wav.scp -ot "$my_data_dir" ]]; then
      echo ---------------------------------------------------------------------
      echo "Preparing ${type} data lists in ${datadir} on" `date`
      echo ---------------------------------------------------------------------
      local/prepare_acoustic_training_data_separate_fillers.pl --fragmentMarkers \-\*\~  \
        $my_data_dir ${datadir} > ${datadir}/skipped_utts.log || exit 1
      mv $datadir/text $datadir/text_orig
      cat $datadir/text_orig | sed 's/<silence>\ //g' | sed 's/\ <silence>//g' | awk '{if (NF > 1) {print $0}}' > $datadir/text
    fi

    echo ---------------------------------------------------------------------
    echo "Preparing ${type} stm files in ${datadir} on" `date`
    echo ---------------------------------------------------------------------
    if [ ! -z $my_stm_file ] ; then
      local/augment_original_stm.pl $my_stm_file ${datadir}
    elif [[ $type == shadow || $type == eval ]]; then
      echo "Not doing anything for the STM file!"
    else
      local/prepare_stm.pl --fragmentMarkers \-\*\~ ${datadir}
    fi
  fi
fi

echo ---------------------------------------------------------------------
echo "Resegment data in ${data}/$type.seg on " `date`
echo ---------------------------------------------------------------------

if [ ! -s ${data}/${type}.seg/feats.scp ]; then
  if $use_vad; then
    rm -rf exp/tri4b_seg
    [ ! -f exp/tri4b_seg/final.mdl ] && local/run_segmentation_train.sh exp/tri4 data/train data/lang
    steps/train_vad_gmm.sh 400 100 data/train data/lang exp/tri4_ali exp/gmm_vad4 || exit 1
    local/run_vad_segmentation.sh --segmentation-opts "$segmentation_opts" \
      --beam $beam --max-active $max_active --vad-boost $vad_boost --vad-threshold $vad_threshold \
      $datadir $data/lang exp/gmm_vad4 \
      exp/tri4b_seg exp/tri4b_resegment_$type || exit 1
  else
    if $posterior_decode; then
      local/run_segmentation_post.sh --segmentation_opts "$segmentation_opts" --initial false --penalize_long_phones $penalize_long_phones --dm-scale $dm_scale --beam $beam --max-active $max_active --segment-length $segment_length --use-viterbi-decode $use_viterbi_decode --allow-partial $allow_partial --use-word-lm $use_word_lm $datadir $data/lang || exit 1
    else
      local/run_segmentation.sh --noise_oov false --use-word-lm $use_word_lm \
        --segmentation_opts "$segmentation_opts" \
        $datadir $data/lang exp/tri4b_seg \
        exp/tri4b_resegment_$type || exit 1
    fi
  fi
fi

datadir=${data}/${type}.seg
dirid=${type}.seg

#####################################################################
#
# data directory preparation
#
#####################################################################
echo ---------------------------------------------------------------------
echo "Preparing ${type} kws data files in ${datadir} on" `date`
echo ---------------------------------------------------------------------
if ! $skip_kws  && [ ! -f ${datadir}/kws/.done ] ; then
  if [[ $type == shadow ]]; then
    
    # we expect that the ${dev2shadow} as well as ${eval2shadow} already exist
    if [ ! -f ${data}/${dev2shadow}/kws/.done ]; then
      echo "Error: ${data}/${dev2shadow}/kws/.done does not exist."
      echo "Create the directory ${data}/${dev2shadow} first, by calling $0 --type $dev2shadow --dataonly"
      exit 1
    fi
    if [ ! -f ${data}/${eval2shadow}/kws/.done ]; then
      echo "Error: ${data}/${eval2shadow}/kws/.done does not exist."
      echo "Create the directory ${data}/${eval2shadow} first, by calling $0 --type $eval2shadow --dataonly"
      exit 1
    fi


    local/kws_data_prep.sh --case_insensitive $case_insensitive \
      "${icu_opt[@]}" \
      ${data}/lang ${datadir} ${datadir}/kws
    utils/fix_data_dir.sh ${datadir}

    touch ${datadir}/kws/.done
  else
    kws_flags=()
    if [ ! -z $my_rttm_file ] ; then
      kws_flags+=(--rttm-file $my_rttm_file )
    fi
    if [ $my_subset_ecf ] ; then
      kws_flags+=(--subset-ecf $my_data_list)
    fi
    
    local/kws_setup.sh --case_insensitive $case_insensitive \
      "${kws_flags[@]}" "${icu_opt[@]}" \
      $my_ecf_file $my_kwlist_file ${data}/lang ${datadir}

    touch ${datadir}/kws/.done
  fi
fi

if $data_only ; then
  echo "Exiting, as data-only was requested..."
  exit 0;
fi

####################################################################
##
## FMLLR decoding 
##
####################################################################
tri5=tri5
decode=exp/${tri5}/decode_${dirid}

if [ ! -f ${decode}/.done ]; then
  echo ---------------------------------------------------------------------
  echo "Spawning decoding with SAT models  on" `date`
  echo ---------------------------------------------------------------------
  utils/mkgraph.sh \
    ${data}/lang exp/$tri5 exp/$tri5/graph |tee exp/$tri5/mkgraph.log

  mkdir -p $decode
  #By default, we do not care about the lattices for this step -- we just want the transforms
  #Therefore, we will reduce the beam sizes, to reduce the decoding times
  steps/decode_fmllr_extra.sh --skip-scoring true --beam 10 --lattice-beam 4\
    --nj $my_nj --cmd "$decode_cmd" "${decode_extra_opts[@]}"\
    exp/$tri5/graph ${datadir} ${decode} |tee ${decode}/decode.log
  touch ${decode}/.done
fi

if ! $fast_path ; then
  local/run_kws_stt_task.sh --cer $cer --max-states $max_states \
    --cmd "$decode_cmd" --skip-kws $skip_kws --skip-stt $skip_stt --wip $wip \
    "${shadow_set_extra_opts[@]}" "${lmwt_plp_extra_opts[@]}" \
    ${datadir} ${data}/lang ${decode}

  if $tri5_only; then
    exit 0
  fi

  local/run_kws_stt_task.sh --cer $cer --max-states $max_states \
    --cmd "$decode_cmd" --skip-kws $skip_kws --skip-stt $skip_stt --wip $wip \
    "${shadow_set_extra_opts[@]}" "${lmwt_plp_extra_opts[@]}" \
    ${datadir} ${data}/lang ${decode}.si
fi
  
if $tri5_only; then
  exit 0
fi

####################################################################
## SGMM2 decoding 
####################################################################
sgmm5=sgmm5
decode=exp/${sgmm5}/decode_fmllr_${dirid}

if [ ! -f $decode/.done ]; then
  echo ---------------------------------------------------------------------
  echo "Spawning $decode on" `date`
  echo ---------------------------------------------------------------------
  utils/mkgraph.sh \
    ${data}/lang exp/$sgmm5 exp/$sgmm5/graph |tee exp/$sgmm5/mkgraph.log

  mkdir -p $decode
  steps/decode_sgmm2.sh --skip-scoring true --use-fmllr true --nj $my_nj \
    --cmd "$decode_cmd" --transform-dir exp/${tri5}/decode_${dirid} "${decode_extra_opts[@]}"\
    exp/$sgmm5/graph ${datadir} $decode |tee $decode/decode.log
  touch $decode/.done

  if ! $fast_path ; then
    local/run_kws_stt_task.sh --cer $cer --max-states $max_states \
      --cmd "$decode_cmd" --skip-kws $skip_kws --skip-stt $skip_stt --wip $wip \
      "${shadow_set_extra_opts[@]}" "${lmwt_plp_extra_opts[@]}" \
      ${datadir} ${data}/lang ${decode}
  fi
fi

####################################################################
##
## SGMM_MMI rescoring
##
####################################################################

for iter in 1 2 3 4; do
  # Decode SGMM+MMI (via rescoring).
  sgmm5_mmi_b0_1=sgmm5_mmi_b0.1
  decode=exp/${sgmm5_mmi_b0_1}/decode_fmllr_${dirid}_it${iter}
  if [ ! -f $decode/.done ]; then
    mkdir -p $decode
    steps/decode_sgmm2_rescore.sh  --skip-scoring true \
      --cmd "$decode_cmd" --iter $iter --transform-dir exp/$tri5/decode_${dirid} \
      ${data}/lang ${datadir} exp/$sgmm5/decode_fmllr_${dirid} $decode | tee ${decode}/decode.log

    touch $decode/.done
  fi
  
  #We are done -- all lattices has been generated. We have to
  #a)Run MBR decoding
  #b)Run KW search
  local/run_kws_stt_task.sh --cer $cer --max-states $max_states \
    --cmd "$decode_cmd" --skip-kws $skip_kws --skip-stt $skip_stt --wip $wip \
    "${shadow_set_extra_opts[@]}" "${lmwt_plp_extra_opts[@]}" \
    ${datadir} ${data}/lang $decode
    
done

exit 0

####################################################################
##
## DNN decoding
##
####################################################################
tri6_nnet=tri6_nnet
decode=exp/$tri6_nnet/decode_${dirid}

if [ -f $decode/.done ]; then
  steps/decode_nnet_cpu.sh --cmd "$decode_cmd" --nj $my_nj \
    --skip-scoring true "${decode_extra_opts[@]}" \
    --transform-dir exp/$tri6_nnet/decode_${dirid} \
    exp/$tri6_nnet/graph ${datadir} $decode |tee $decode/decode.log
  touch $decode/.done

  local/run_kws_stt_task.sh --cer $cer --max-states $max_states \
    --cmd "$decode_cmd" --skip-kws $skip_kws --skip-stt $skip_stt --wip $wip \
    "${shadow_set_extra_opts[@]}" "${lmwt_plp_extra_opts[@]}" \
    ${datadir} ${data}/lang $decode
fi

echo "Everything looking good...." 

echo ---------------------------------------------------------------------
echo "Finished successfully on" `date`
echo ---------------------------------------------------------------------

exit 0
