#!/bin/bash
# Author: Vimal Manohar

set -o pipefail
# set -e

. path.sh
. cmd.sh
. lang.conf

nj=
cmd=$decode_cmd
segmentation_opts="--isolated-resegmentation --min-inter-utt-silence-length 1.0 --silence-proportion 0.05" 
get_text=false  # Get text corresponding to new segments in $data/$type.seg
                # Assuming text is in $data/$type directory.
beam=7.0
max_active=1000
boost_silence=1.0
noise_oov=false
vad_boost=0.1
vad_threshold=1.5   # If P(speech) / P(sil) > threshold, then call it speech
use_post_decode=true

#debugging stuff
echo $0 $@

[ -f ./path.sh ] && . ./path.sh
[ -f ./cmd.sh ]  && . ./cmd.sh
. parse_options.sh || exit 1;

if [ $# -ne 5 ]; then
  echo "Usage: $0 [options] <data-dir> <lang-dir> <vad-dir> <model-dir> <temp-dir>"
  echo " Options:"
  echo "    --cmd (run.pl|queue.pl...)      # specify how to run the sub-processes."
  echo "    --nj <numjobs>    # Number of parallel jobs"
  echo "    --segmentation-opts '--opt1 opt1val --opt2 opt2val' # options for segmentation.py"
  echo "e.g.:"
  echo "$0 data/dev10h data/lang"
  exit 1
fi

datadir=$1
lang=$2
vad_dir=$3
model_dir=$4
temp_dir=$5

type=`basename $datadir`
data=`dirname $datadir`

if [ -z $nj ]; then
  eval my_nj=\$${type}_nj
else
  my_nj=$nj
fi

[ -z $my_nj ] && exit 1
nj=$my_nj

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

if [ ! -f $data/${dirid}.whole/.done ]; then
  mkdir -p $data/${dirid}.whole

  cp -rT $data/${type} $data/${dirid}.whole; rm -r $data/${dirid}.whole/split*
  for f in text utt2spk spk2utt feats.scp cmvn.scp segments; do rm $data/${dirid}.whole/$f; done

  cat $data/${dirid}.whole/wav.scp | awk '{print $1" "$1}' > $data/$dirid.whole/utt2spk
  cat $data/${dirid}.whole/wav.scp | awk '{print $1" "$1}' > $data/$dirid.whole/spk2utt
  
  plpdir=exp/plp.seg.whole # don't use plp because of the way names are assigned within that
  # dir, we'll overwrite the old data.
  mkdir -p $plpdir
  make_plp ${dirid}.whole $data $plpdir || exit 1
  
  touch $data/${dirid}.whole/.done
fi

[ ! -s $data/${dirid}.whole/feats.scp ] && echo "$data/${dirid}.whole/feats.scp not found or empty!" && exit 1

mkdir -p $data/${dirid}.orig
cp $data/${dirid}.whole/wav.scp $data/$dirid.orig || exit 1

if [ ! -f $vad_dir/decode_$dirid.whole/.done ]; then
  if ! $use_post_decode; then
    steps/decode_nolats.sh --write-words false --write-alignments true \
      --cmd "$cmd" --nj $nj --beam 7.0 --max-active 1000 \
      --acwt 100 --boost-silence $vad_boost --silence-phones-list 1 \
      $vad_dir/graph $data/${dirid}.whole $vad_dir/decode_${dirid}.whole || exit 1
  else
    steps/decode.sh --skip-scoring true \
      --nj $my_nj --cmd "$cmd" "${decode_extra_opts[@]}" \
      --beam $beam --max-active $max_active --allow-partial false \
      $vad_dir/graph $data/${dirid}.whole $vad_dir/decode_${dirid}.whole || exit 1
    [ ! -s $vad_dir/decode_${dirid}.whole/lat.1.gz ]  && echo "$vad_dir/decode_${dirid}.whole/lat.*.gz not found" && exit 1
    "$decode_cmd" JOB=1:$my_nj $vad_dir/decode_${dirid}.whole/log/post_decode.JOB.log \
      lattice-to-post --acoustic-scale=100 \
      "ark:gunzip -c $vad_dir/decode_${dirid}.whole/lat.JOB.gz|" ark:- \| \
      weight-silence-post $vad_threshold 1 $vad_dir/final.mdl ark:- ark:- \| \
      post-decode ark:- "ark:|gzip -c > $vad_dir/decode_${dirid}.whole/ali.JOB.gz" || exit 1

  fi
  touch $vad_dir/decode_$dirid.whole/.done
fi

[ ! -s $vad_dir/decode_${dirid}.whole/ali.1.gz ] && echo "$vad_dir/decode_${dirid}.whole/ali.1.gz not found or empty!" && exit 1

if [ ! -s $data/${dirid}.orig/feats.scp ]; then

  mkdir -p $vad_dir/resegment_$dirid

  $cmd JOB=1:$my_nj $vad_dir/log/predict.JOB.log ali-to-phones --per-frame=true $vad_dir/final.mdl \
    "ark:gunzip -c $vad_dir/decode_${dirid}.whole/ali.JOB.gz|" \
    "ark,t:| gzip -c > $vad_dir/resegment_${dirid}/pred.JOB.gz" || exit 1
  
  echo "1 0
2 2" > $vad_dir/resegment_$dirid/phone_map.txt 

  [ ! -s $vad_dir/resegment_${dirid}/pred.1.gz ] && echo "$vad_dir/resegment_${dirid}/pred.1.gz is empty!" && exit 1

  $cmd JOB=1:$my_nj $vad_dir/log/segment.JOB.log gunzip -c $vad_dir/resegment_$dirid/pred.JOB.gz \| \
    local/segmentation_parallel.py --silence-proportion 0.1 \
    --min-inter-utt-silence-length 1.0 --max-segment-length 30.0 - $vad_dir/resegment_$dirid/phone_map.txt - \| \
    gzip -c '>' $vad_dir/resegment_$dirid/segments.JOB.gz || exit 1

  [ ! -s $vad_dir/resegment_${dirid}/segments.1.gz ] && echo "$vad_dir/resegment_${dirid}/segments.1.gz is empty!" && exit 1

  for n in `seq 1 $my_nj`; do gunzip -c $vad_dir/resegment_$dirid/segments.$n.gz; done | sort > $data/${dirid}.orig/segments

  [ ! -s $data/${dirid}.orig/segments ] && echo "$data/${dirid}.orig/segments is empty!" && exit 1

  cat $data/${dirid}.orig/segments | cut -d ' ' -f 1,2 > $data/${dirid}.orig/utt2reco || exit 1
  utt2spk_to_spk2utt.pl $data/${dirid}.orig/utt2reco > $data/${dirid}.orig/reco2utt || exit 1
  cp $data/${dirid}.orig/utt2reco $data/${dirid}.orig/utt2spk
  utt2spk_to_spk2utt.pl $data/${dirid}.orig/utt2spk > $data/${dirid}.orig/spk2utt || exit 1

  plpdir=exp/plp.seg.orig # don't use plp because of the way names are assigned within that
  # dir, we'll overwrite the old data.
  mkdir -p $plpdir
  make_plp ${dirid}.orig $data $plpdir || exit 1
fi

[ ! -s $data/${dirid}.orig/feats.scp ] && echo "$data/${dirid}.orig/feats.scp is empty!" && exit 1

###############################################################################
#
# Phone Decoder
#
###############################################################################

mkdir -p $temp_dir

total_time=0
t1=$(date +%s)
if [ ! -f $model_dir/decode_${dirid}.orig/.done ]; then
  [ ! -f $model_dir/final.mdl ] && echo "$model_dir/final.mdl not found" && exit 1
  steps/decode_nolats.sh --write-words false --write-alignments true \
    --cmd "$cmd" --nj $my_nj --beam $beam --max-active $max_active \
    --boost-silence $boost_silence --silence-phones-list `cat $lang/phones/optional_silence.csl` \
    $model_dir/phone_graph $data/${dirid}.orig $model_dir/decode_${dirid}.orig || exit 1
  
  touch $model_dir/decode_${dirid}.orig/.done
fi

[ ! -s $model_dir/decode_${dirid}.orig/ali.1.gz ] && echo "$model_dir/decode_${dirid}.orig/ali.1.gz not found or empty!" && exit 1

if [ ! -s $temp_dir/pred.1.gz ]; then
  $cmd JOB=1:$my_nj $model_dir/decode_${dirid}.orig/log/predict.JOB.log \
    gunzip -c $model_dir/decode_${dirid}.orig/ali.JOB.gz \| \
    ali-to-phones --per-frame=true $model_dir/final.mdl ark:- ark,t:- \| \
    utils/int2sym.pl -f 2- $lang/phones.txt \| \
    gzip -c '>' $temp_dir/pred.JOB.gz || exit 1
fi
  
[ ! -s $temp_dir/pred.1.gz ] && echo "$temp_dir/pred.1.gz is empty!" && exit 1

if [ -s $data/${dirid}.orig/segments ]; then
  mkdir -p $temp_dir/pred_temp
  
  for n in `seq $my_nj`; do gunzip -c $temp_dir/pred.$n.gz; done | \
    python -c "import sys
for l in sys.stdin.readlines():
  splits = l.strip().split()
  file_handle = open(\""$temp_dir"/pred_temp/%s.pred\" % splits[0], 'w')
  file_handle.write(\" \".join(splits[1:]))
  file_handle.write(\"\n\")
  file_handle.close()" || exit 1
  
  if [ ! -f $temp_dir/.pred.done ]; then
    mkdir -p $temp_dir/pred
    local/merge_pred.py $data/${dirid}.orig/segments $temp_dir/pred_temp $temp_dir/pred || exit 1
    touch $temp_dir/.pred.done
  fi

fi
  
count=0
for f in $temp_dir/pred/*.pred; do 
  count=$((count+1))
  [ ! -s $f ] && echo "$f is not found or empty!" && exit 1
done

if [ $count -lt "$(wc -l $data/$dirid.orig/wav.scp | cut -d ' ' -f 1)" ]; then
  echo "Found only $count predictions vs $(wc -l $data/$dirid.orig/wav.scp | cut -d ' ' -f 1) files" 
  exit 1
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
{
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
} > $temp_dir/phone_map.txt

mkdir -p $data/$type.seg

ls $temp_dir/pred/*.pred &> /dev/null

[ $? -eq "0" ] || exit 1

if [ ! -s $data/$type.seg/segments ] ; then
  t1=$(date +%s)
  mkdir -p $temp_dir/log
  local/segmentation.py --verbose 2 $segmentation_opts $temp_dir/pred $temp_dir/phone_map.txt \
    2> $temp_dir/log/resegment.log | sort > $data/$type.seg/segments || exit 1
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
  if [ ! -f exp/${tri4}_ali_$type/.done ]; then
    steps/align_fmllr.sh --nj $my_nj --cmd "$cmd" \
      $data/$type $lang exp/${tri4} exp/${tri4}_ali_$type || exit 1;
    touch exp/${tri4}_ali_$type/.done
  fi
  
  if [ ! -f $data/$type.seg/text ]; then
    # Get the file $data/$type.seg/text
    [ ! -s $data/$type/reco2file_and_channel ] && cat $data/$type/segments | awk '{print $2" "$2" "1}' > $data/$type/reco2file_and_channel
    [ ! -s $data/$type.seg/reco2file_and_channel ] && cat $data/$type.seg/segments | awk '{print $2" "$2" "1}' > $data/$type.seg/reco2file_and_channel
    steps/resegment_text.sh --cmd "$cmd" $data/$type $lang \
      exp/${tri4}_ali_$type $data/$type.seg exp/${tri4b}_resegment_$type || exit 1
    [ ! -f $data/$type.seg/text ] && exit 1
    utils/fix_data_dir.sh $data/${dirid}
    utils/validate_data_dir.sh --no-feats --no-text $data/${dirid}
  fi
fi

echo ---------------------------------------------------------------------
echo "Resegment data Finished successfully on" `date`
echo ---------------------------------------------------------------------

exit 0
