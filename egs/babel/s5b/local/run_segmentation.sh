#!/bin/bash
# Author: Vimal Manohar

set -o pipefail
#set -e

. lang.conf

nj=
cmd=$decode_cmd
segmentation_opts="--remove-noise-only-segments false --max-length-diff 0.4 --min-inter-utt-silence-length 1.0" 
initial=false   # Set to true, if using models without adding 
                # artificial fillers as trained using run-0-fillers.sh
get_text=false  # Get text corresponding to new segments in $data/$type.seg
                # Assuming text is in $data/$type directory.

#debugging stuff
echo $0 $@

[ -f ./path.sh ] && . ./path.sh
[ -f ./cmd.sh ]  && . ./cmd.sh
. parse_options.sh || exit 1;

if [ $# -ne 2 ]; then
  echo "Usage: $0 [options] <data-dir> <lang-dir>"
  echo " Options:"
  echo "    --cmd (run.pl|queue.pl...)      # specify how to run the sub-processes."
  echo "    --initial (true|false)  # Set to true, if using models without adding 
                                # artificial fillers as trained using run-0-fillers.sh"
  echo "    --nj <numjobs>    # Number of parallel jobs"
  echo "    --segmentation-opts '--opt1 opt1val --opt2 opt2val' # options for segmentation.py"
  echo "e.g.:"
  echo "$0 data/dev10h data/lang"
  exit 1
fi

datadir=$1
lang=$2

type=`basename $datadir`
data=`dirname $datadir`

if [ -z $nj ]; then
  eval my_nj=\$${type}_nj
else
  my_nj=$nj
fi

[ -z $my_nj ] && exit 1

tri4=tri4
tri4b=tri4b

if $initial; then
  tri4=tri4_initial
  tri4b=tri4b_initial
fi

function make_plp {
  t=$1
  data=$2
  plpdir=$3

  if [ "$use_pitch" = "false" ] && [ "$use_ffv" = "false" ]; then
   steps/make_plp.sh --cmd "$cmd" --nj $my_nj ${data}/${t} exp/make_plp/${t} ${plpdir}
  elif [ "$use_pitch" = "true" ] && [ "$use_ffv" = "true" ]; then
    cp -rT ${data}/${t} ${data}/${t}_plp; cp -rT ${data}/${t} ${data}/${t}_pitch; cp -rT ${data}/${t} ${data}/${t}_ffv
    steps/make_plp.sh --cmd "$cmd" --nj $my_nj ${data}/${t}_plp exp/make_plp/${t} plp_tmp_${t}
    local/make_pitch.sh --cmd "$cmd" --nj $my_nj ${data}/${t}_pitch exp/make_pitch/${t} pitch_tmp_${t}
    local/make_ffv.sh --cmd "$cmd"  --nj $my_nj ${data}/${t}_ffv exp/make_ffv/${t} ffv_tmp_${t}
    steps/append_feats.sh --cmd "$cmd" --nj $my_nj ${data}/${t}{_plp,_pitch,_plp_pitch} exp/make_pitch/append_${t}_pitch plp_tmp_${t}
    steps/append_feats.sh --cmd "$cmd" --nj $my_nj ${data}/${t}{_plp_pitch,_ffv,} exp/make_ffv/append_${t}_pitch_ffv ${plpdir}
    rm -rf {plp,pitch,ffv}_tmp_${t} ${data}/${t}_{plp,pitch,plp_pitch}
  elif [ "$use_pitch" = "true" ]; then
    cp -rT ${data}/${t} ${data}/${t}_plp; cp -rT ${data}/${t} ${data}/${t}_pitch
    steps/make_plp.sh --cmd "$cmd" --nj $my_nj ${data}/${t}_plp exp/make_plp/${t} plp_tmp_${t}
    local/make_pitch.sh --cmd "$cmd" --nj $my_nj ${data}/${t}_pitch exp/make_pitch/${t} pitch_tmp_${t}
    steps/append_feats.sh --cmd "$cmd" --nj $my_nj ${data}/${t}{_plp,_pitch,} exp/make_pitch/append_${t} ${plpdir}
    rm -rf {plp,pitch}_tmp_${t} ${data}/${t}_{plp,pitch}
  elif [ "$use_ffv" = "true" ]; then
    cp -rT ${data}/${t} ${data}/${t}_plp; cp -rT ${data}/${t} ${data}/${t}_ffv
    steps/make_plp.sh --cmd "$cmd" --nj $my_nj ${data}/${t}_plp exp/make_plp/${t} plp_tmp_${t}
    local/make_ffv.sh --cmd "$cmd" --nj $my_nj ${data}/${t}_ffv exp/make_ffv/${t} ffv_tmp_${t}
    steps/append_feats.sh --cmd "$cmd" --nj $my_nj ${data}/${t}{_plp,_ffv,} exp/make_ffv/append_${t} ${plpdir}
    rm -rf {plp,ffv}_tmp_${t} ${data}/${t}_{plp,ffv}
  fi
  steps/compute_cmvn_stats.sh ${data}/${t} exp/make_plp/${t} ${plpdir}
  utils/fix_data_dir.sh ${data}/${t}
}

[ ! -d $data/${type} ]; 
dirid=${type}.seg

###############################################################################
#
# Prepare temporary data directory without segments in $data/$dirid.orig
#
###############################################################################

if [ ! -f $data/${dirid}.orig/.done ]; then
  mkdir -p $data/${dirid}.orig
  mkdir -p $data/${dirid}
  cp -rT $data/${type} $data/${dirid}.orig; rm -r $data/${dirid}.orig/split*
  for f in text utt2spk spk2utt feats.scp cmvn.scp segments; do rm $data/${dirid}.orig/$f; done
  cat $data/${dirid}.orig/wav.scp  | awk '{print $1, $1;}' | \
    tee $data/${dirid}.orig/spk2utt > $data/${dirid}.orig/utt2spk
  plpdir=exp/plp.seg.orig # don't use plp because of the way names are assigned within that
  # dir, we'll overwrite the old data.
  mkdir -p $plpdir

  make_plp ${dirid}.orig $data $plpdir || exit 1

  touch $data/${dirid}.orig/.done
fi

###############################################################################
#
# Phone Decoder
#
###############################################################################

model_dir=exp/${tri4b}_whole_seg

total_time=0
if [ ! -f $model_dir/decode_${dirid}.orig/.done ]; then
  t1=$(date +%s)
  steps/decode_nolats.sh --write-words false --write-alignments true \
    --cmd "$cmd" --nj $my_nj --beam 7.0 --max-active 1000 \
    $model_dir/phone_graph $data/${dirid}.orig $model_dir/decode_${dirid}.orig || exit 1
  touch $model_dir/decode_${dirid}.orig/.done
  t2=$(date +%s)
  total_time=$((total_time + t2 - t1))
  echo "Phone decoding done in $((t2-t1)) seconds" 
fi

###############################################################################
#
# Resegmenter
#
###############################################################################

if [ ! -f $data/$type.seg/segments ]; then
  t1=$(date +%s)
  temp_dir=exp/${tri4b}_whole_resegment_${type}

  [ -f $data/$dirid/segments ] && rm $data/$dirid/segments
  steps/resegment_data.sh --segmentation_opts "$segmentation_opts" --cmd "$cmd" $data/${dirid}.orig $lang \
    $model_dir/decode_${dirid}.orig $data/$dirid $temp_dir || exit 1
  [ ! -f $data/$type.seg/segments ] && exit 1
  cp $data/$type.seg/segments $temp_dir
  t2=$(date +%s)
  total_time=$((total_time + t2 - t1))
  echo "Resegment data done in $((t2-t1)) seconds" 

  [ -f ${data}/$type/segments ] && utils/evaluate_segmentation.pl ${data}/$type/segments ${data}/$dirid/segments &> $temp_dir/segment_evaluation.log
fi

plpdir=exp/plp.seg # don't use plp because of the way names are assigned within that
# dir, we'll overwrite the old data.
echo ---------------------------------------------------------------------
echo "Starting plp feature extraction for $data/$type in $plpdir on " `date`
echo ---------------------------------------------------------------------

if [ ! -f $data/${dirid}/.done ]; then
  t1=$(date +%s)
  utils/fix_data_dir.sh $data/${dirid}
  utils/validate_data_dir.sh --no-feats --no-text $data/${dirid}
  mkdir -p $plpdir

  make_plp $dirid $data $plpdir
  t2=$(date +%s)
  total_time=$((total_time + t2 - t1))
  echo "Feature extraction done in $((t2-t1)) seconds" 
  
  touch $data/${dirid}/.done
fi

echo "Resegmentation of $type took $total_time seconds"

if $get_text && [ -f $data/$type/text ]; then
  # We need all the training data to be aligned, in order
  # to get the resegmented "text".
  if [ ! -f exp/${tri4}_whole_ali_$type/.done ]; then
    steps/align_fmllr.sh --nj $my_nj --cmd "$cmd" \
      $data/$type $lang exp/${tri4} exp/${tri4}_whole_ali_$type || exit 1;
    touch exp/${tri4}_whole_ali_$type/.done
  fi
  
  if [ ! -f $data/$type.seg/text ]; then
    # Get the file $data/$type.seg/text
    steps/resegment_text.sh --cmd "$cmd" $data/$type $lang \
      exp/${tri4}_whole_ali_$type $data/$type.seg exp/${tri4b}_whole_resegment_$type
  fi
fi

echo ---------------------------------------------------------------------
echo "Resegment data Finished successfully on" `date`
echo ---------------------------------------------------------------------

exit 0
