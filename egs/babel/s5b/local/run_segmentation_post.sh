#!/bin/bash
# Author: Vimal Manohar

set -o pipefail
set -x 
# set -e

. path.sh
. cmd.sh
. lang.conf

nj=
cmd=$decode_cmd
segmentation_opts="--isolated-resegmentation --min-inter-utt-silence-length 1.0 --silence-proportion 0.05" 
initial=false   # Set to true, if using models without adding 
                # artificial fillers as trained using run-0-fillers.sh
get_text=false  # Get text corresponding to new segments in $data/$type.seg
                # Assuming text is in $data/$type directory.
use_word_lm=false
beam=7.0
max_active=1000
segmentation2=false

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
   steps/make_plp.sh --cmd "$decode_cmd" --nj $my_nj ${data}/${t} exp/make_plp/${t} ${plpdir} || exit 1
  elif [ "$use_pitch" = "true" ] && [ "$use_ffv" = "true" ]; then
    cp -rT ${data}/${t} ${data}/${t}_plp; cp -rT ${data}/${t} ${data}/${t}_pitch; cp -rT ${data}/${t} ${data}/${t}_ffv
    steps/make_plp_pitch.sh --cmd "$decode_cmd" --nj $my_nj ${data}/${t}_plp_pitch exp/make_plp_pitch/${t} plp_tmp_${t} || exit 1
    local/make_ffv.sh --cmd "$decode_cmd"  --nj $my_nj ${data}/${t}_ffv exp/make_ffv/${t} ffv_tmp_${t}
    steps/append_feats.sh --cmd "$decode_cmd" --nj $my_nj ${data}/${t}{_plp_pitch,_ffv,} exp/make_ffv/append_${t}_pitch_ffv ${plpdir} || exit 1
    rm -rf {plp_pitch,ffv}_tmp_${t} ${data}/${t}_{plp_pitch,ffv}
  elif [ "$use_pitch" = "true" ]; then
    steps/make_plp_pitch.sh --cmd "$decode_cmd" --nj $my_nj ${data}/${t} exp/make_plp_pitch/${t} $plpdir || exit 1
  elif [ "$use_ffv" = "true" ]; then
    cp -rT ${data}/${t} ${data}/${t}_plp; cp -rT ${data}/${t} ${data}/${t}_ffv
    steps/make_plp.sh --cmd "$decode_cmd" --nj $my_nj ${data}/${t}_plp exp/make_plp/${t} plp_tmp_${t}
    local/make_ffv.sh --cmd "$decode_cmd" --nj $my_nj ${data}/${t}_ffv exp/make_ffv/${t} ffv_tmp_${t}
    steps/append_feats.sh --cmd "$decode_cmd" --nj $my_nj ${data}/${t}{_plp,_ffv,} exp/make_ffv/append_${t} $plpdir || exit 1
    rm -rf {plp,ffv}_tmp_${t} ${data}/${t}_{plp,ffv}
  fi

  steps/compute_cmvn_stats.sh ${data}/${t} exp/make_plp/${t} $plpdir
  utils/fix_data_dir.sh ${data}/${t}
}

[ ! -d $data/${type} ] && exit 1 
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
  wav-to-duration scp:$data/${dirid}.orig/wav.scp ark,t:$data/${dirid}.orig/durations.scp || exit 1
  utils/durations2segments.py $data/${dirid}.orig/durations.scp | sort > $data/${dirid}.orig/segments || exit 1
  cat $data/${dirid}.orig/segments | cut -d ' ' -f 1,2 > $data/${dirid}.orig/utt2reco || exit 1
  utt2spk_to_spk2utt.pl $data/${dirid}.orig/utt2reco > $data/${dirid}.orig/reco2utt || exit 1
  cp $data/${dirid}.orig/utt2reco $data/${dirid}.orig/utt2spk
  utt2spk_to_spk2utt.pl $data/${dirid}.orig/utt2spk > $data/${dirid}.orig/spk2utt || exit 1

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
temp_dir=exp/${tri4b}_whole_resegment_${type}

mkdir -p $temp_dir

total_time=0
t1=$(date +%s)
if [ ! -f $model_dir/decode_${dirid}.orig/.done ]; then
  [ ! -f $model_dir/final.mdl ] && echo "$model_dir/final.mdl not found" && exit 1
  steps/decode.sh --skip-scoring true \
    --nj $my_nj --cmd "$cmd" "${decode_extra_opts[@]}" --beam $beam --max-active $max_active \
    $model_dir/phone_graph $data/${dirid}.orig $model_dir/decode_${dirid}.orig
  touch $model_dir/decode_${dirid}.orig/.done
fi

if [ ! -f $model_dir/decode_${dirid}.orig/.phone_post.done ]; then
  $cmd JOB=1:$my_nj $model_dir/decode_${dirid}.orig/log/get_phone_post.JOB.log \
    lattice-to-post --acoustic-scale=0.1 \
    "ark:gunzip -c $model_dir/decode_${dirid}.orig/lat.JOB.gz|" ark:- \| \
    post-to-phone-post $model_dir/final.mdl ark:- "ark,t:|gzip -c > $model_dir/decode_${dirid}.orig/phone_post.JOB.gz" || exit 1
  touch $model_dir/decode_${dirid}.orig/.phone_post.done
fi

if [ ! -f $temp_dir/.post_decode.done ]; then
  $cmd JOB=1:$my_nj $model_dir/decode_${dirid}.orig/log/post_decode.JOB.log \
    gunzip -c $model_dir/decode_${dirid}.orig/phone_post.JOB.gz \| \
    python -c "import sys
for line in sys.stdin.readlines():
  splits = line.strip().split()
  sys.stdout.write(splits[0])
  i = 1
  phones = []
  while i < len(splits):
    if splits[i] == \"[\":
      phones = []
      i += 1
      continue
    phones.append(tuple(splits[i:i+2]))
    i += 2
    if splits[i] == \"]\":
      sys.stdout.write(\" \" + max(phones, key=lambda x:float(x[1]))[0])
      i += 1
  sys.stdout.write(\"\n\")" \| \
    utils/int2sym.pl -f 2- $lang/phones.txt \| \
    gzip -c '>' $temp_dir/pred.JOB.gz || exit 1
  
  mkdir -p $temp_dir/pred_temp

  for n in `seq $my_nj`; do gunzip -c $temp_dir/pred.$n.gz; done | \
    python -c "import sys
for l in sys.stdin.readlines():
  splits = l.strip().split()
  file_handle = open(\""$temp_dir"/pred_temp/%s.pred\" % splits[0], 'w')
  file_handle.write(\" \".join(splits[1:]))
  file_handle.write(\"\n\")
  file_handle.close()" || exit 1

  echo $my_nj > $temp_dir/num_jobs
  touch $temp_dir/.post_decode.done
fi

if [ ! -f $temp_dir/.pred.done ]; then
  mkdir -p $temp_dir/pred
  local/merge_pred.py $data/${dirid}.orig/segments $temp_dir/pred_temp $temp_dir/pred || exit 1
  touch $temp_dir/.pred.done
fi

t2=$(date +%s)
total_time=$((total_time + t2 - t1))
echo "SI decoding done in $((t2-t1)) seconds" 

###############################################################################
#
# Resegmenter
#
###############################################################################

if ! [ `cat $lang/phones/optional_silence.txt | wc -w` -eq 1 ]; then
  echo "Error: this script only works if $lang/phones/optional_silence.txt contains exactly one entry.";
  echo "You'd have to modify the script to handle other cases."
  exit 1;
fi

silphone=`cat $lang/phones/optional_silence.txt` 
# silphone will typically be "sil" or "SIL". 

# 3 sets of phones: 0 is silence, 1 is noise, 2 is speech.,
if $rttm_based_map; then
  (
  echo "$silphone 0"
  if ! $noise_oov; then
    grep -v -w $silphone $lang/phones/silence.txt \
      | awk '{print $1, 1;}' \
      | sed 's/SIL\(.*\)1/SIL\10/' \
      | sed 's/<oov>\(.*\)1/<oov>\12/'
  else
    grep -v -w $silphone $lang/phones/silence.txt \
      | awk '{print $1, 1;}' \
      | sed 's/SIL\(.*\)1/SIL\10/'
  fi
  cat $lang/phones/nonsilence.txt | awk '{print $1, 2;}' | sed 's/\(<.*>.*\)2/\11/' | sed 's/<oov>\(.*\)1/<oov>\12/'
  ) > $temp_dir/phone_map.txt
else
  (
  echo "$silphone 0"
  grep -v -w $silphone $lang/phones/silence.txt \
    | awk '{print $1, 1;}'
  cat $lang/phones/nonsilence.txt | awk '{print $1, 2;}'
  ) > $temp_dir/phone_map.txt
fi

mkdir -p $data/$type.seg

if [ ! -s $data/$type.seg/segments ] ; then
  t1=$(date +%s)
  mkdir -p $temp_dir/log
  if $segmentation2; then
    local/segmentation2.py --verbose 2 $segmentation_opts $temp_dir/pred $temp_dir/phone_map.txt \
      2> $temp_dir/log/resegment.log | sort > $data/$type.seg/segments || exit 1
  else 
    local/segmentation.py --verbose 2 $segmentation_opts $temp_dir/pred $temp_dir/phone_map.txt \
      2> $temp_dir/log/resegment.log | sort > $data/$type.seg/segments || exit 1
  fi
  [ ! -f $data/$type.seg/segments ] && exit 1
  cp $data/$type.seg/segments $temp_dir
  
  t2=$(date +%s)
  total_time=$((total_time + t2 - t1))
  echo "Resegment data done in $((t2-t1)) seconds" 

  [ -f ${data}/$type/segments ] && local/evaluate_segmentation.pl ${data}/$type/segments ${data}/$dirid/segments &> $temp_dir/segment_evaluation.log
fi
  
if [ -s $data/$type/reco2file_and_channel ]; then
  cp $data/$type/reco2file_and_channel $data/$type.seg/reco2file_and_channel
fi

if [ -s $data/$type/wav.scp ]; then
  cp $data/$type/wav.scp $data/$type.seg/wav.scp
else
  echo "Expected file $data/$type/wav.scp to exist" # or there is really nothing to copy.
  exit 1
fi

for f in glm stm; do 
  if [ -f $data/$type/$f ]; then
    cp $data/$type/$f $data/$type.seg/$f
  fi
done

# We'll make the speaker-ids be the same as the recording-ids (e.g. conversation
# sides).  This will normally be OK for telephone data.
cat $data/$type.seg/segments | awk '{print $1, $2}' > $data/$type.seg/utt2spk || exit 1
utils/utt2spk_to_spk2utt.pl $data/$type.seg/utt2spk > $data/$type.seg/spk2utt || exit 1

cat $data/$type.seg/segments | awk '{num_secs += $4 - $3;} END{print "Number of hours of data is " (num_secs/3600);}'

plpdir=exp/plp.seg # don't use plp because of the way names are assigned within that
# dir, we'll overwrite the old data.
echo ---------------------------------------------------------------------
echo "Starting plp feature extraction for $data/$type in $plpdir on " `date`
echo ---------------------------------------------------------------------

if [ ! -s $data/${dirid}/feats.scp ]; then
  t1=$(date +%s)
  utils/validate_data_dir.sh --no-feats --no-text $data/${dirid}
  mkdir -p $plpdir

  make_plp $dirid $data $plpdir
  t2=$(date +%s)
  total_time=$((total_time + t2 - t1))
  echo "Feature extraction done in $((t2-t1)) seconds" 
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
    [ ! -s $data/$type/reco2file_and_channel ] && cat $data/$type/segments | awk '{print $2" "$2" "1}' > $data/$type/reco2file_and_channel
    [ ! -s $data/$type.seg/reco2file_and_channel ] && cat $data/$type.seg/segments | awk '{print $2" "$2" "1}' > $data/$type.seg/reco2file_and_channel
    steps/resegment_text.sh --cmd "$cmd" $data/$type $lang \
      exp/${tri4}_whole_ali_$type $data/$type.seg exp/${tri4b}_whole_resegment_$type || exit 1
    [ ! -f $data/$type.seg/text ] && exit 1
    utils/fix_data_dir.sh $data/${dirid}
    utils/validate_data_dir.sh --no-feats --no-text $data/${dirid}
  fi
fi

echo ---------------------------------------------------------------------
echo "Resegment data Finished successfully on" `date`
echo ---------------------------------------------------------------------

exit 0
