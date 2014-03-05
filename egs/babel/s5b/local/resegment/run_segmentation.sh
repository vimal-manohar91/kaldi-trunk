#!/bin/bash
# Author: Vimal Manohar

set -o pipefail
# set -x 
# set -e

. path.sh
. cmd.sh
. lang.conf

nj=
cmd=$decode_cmd
segmentation_opts="--isolated-resegmentation --min-inter-utt-silence-length 1.0 --silence-proportion 0.05"
reference_rttm=
get_text=false  # Get text corresponding to new segments in $data/$type.seg
                # Assuming text is in $data/$type directory.
                # Does not work very well because the data does not get aligned to many training transcriptions.
noise_oov=false     # Treat <oov> as noise instead of speech
beam=7.0
max_active=1000

#debugging stuff
echo $0 $@

[ -f ./path.sh ] && . ./path.sh
[ -f ./cmd.sh ]  && . ./cmd.sh
. parse_options.sh || exit 1;

if [ $# -ne 4 ]; then
  echo "Usage: $0 [options] <data-dir> <lang-dir> <model-dir> <temp-dir>"
  echo " Options:"
  echo "    --cmd (run.pl|queue.pl...)      # specify how to run the sub-processes."
  echo "    --nj <numjobs>          # Number of parallel jobs. "
  echo "                              For the standard data directories of dev10h, dev2h and eval"
  echo "                              this is taken from the lang.conf file"
  echo "    --segmentation-opts '--opt1 opt1val --opt2 opt2val' # options for segmentation.py"
  echo "    --reference-rttm        # Reference RTTM file that will be used for analysis of the segmentation"
  echo "                              For the standard data directories of dev10h, dev2h and eval"
  echo "                              this is taken from the lang.conf file"
  echo "    --get-text (true|false) # Convert text from base data directory to correspond to the new segments"
  echo "    --boost-silence         # Boost probability of optional silence during decoding (default: 1.5)"
  echo 
  echo "e.g.:"
  echo "$0 data/dev10h data/lang exp/tri4b_seg exp/tri4b_resegment_dev10h"
  exit 1
fi

datadir=$1      # The base data directory that contains at least the files wav.scp and reco2file_and_channel
lang=$2         
model_dir=$3    # Segmentation model directory created using local/resegment/run_segmentation_train.sh
temp_dir=$4     # Temporary directory to store some intermediate files during segmentation

type=`basename $datadir`
data=`dirname $datadir`

eval my_rttm_file=\$${type}_rttm_file
[ -z $reference_rttm ] && [ ! -z $my_rttm_file ] && reference_rttm=$my_rttm_file

[ ! -z $reference_rttm ] && segmentation_opts="$segmentation_opts --reference-rttm $reference_rttm"

if [ -z $nj ]; then
  eval my_nj=\$${type}_nj
else
  my_nj=$nj
fi

[ -z $my_nj ] && exit 1

function make_plp {
  t=$1
  data=$2
  plpdir=$3

  if [ "$use_pitch" = "true" ]; then
    steps/make_plp_pitch.sh --cmd "$decode_cmd" --nj $my_nj ${data}/${t} exp/make_plp_pitch/${t} $plpdir || exit 1
  else
    steps/make_plp.sh --cmd "$decode_cmd" --nj $my_nj ${data}/${t} exp/make_plp/${t} ${plpdir} || exit 1
  fi

  utils/fix_data_dir.sh ${data}/${t}
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
  cp -rT $data/${type} $data/${dirid}; rm -r $data/${dirid}/split*

  for f in text utt2spk spk2utt feats.scp cmvn.scp segments; do 
    [ -f $data/${dirid}.orig/$f ] && rm $data/${dirid}.orig/$f
    [ -f $data/${dirid}/$f ] && rm $data/${dirid}/$f
  done

  cat $data/${dirid}.orig/wav.scp  | awk '{print $1, $1;}' | \
    tee $data/${dirid}.orig/spk2utt > $data/${dirid}.orig/utt2spk

  echo "$0: Extracting features for $data/${dirid}.orig"
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

mkdir -p $temp_dir

total_time=0
t1=$(date +%s)
if [ ! -f $model_dir/decode_${dirid}.orig/.done ]; then
  steps/decode_nolats.sh --write-words false --write-alignments true \
    --cmd "$cmd" --nj $my_nj --beam $beam --max-active $max_active \
    $model_dir/phone_graph $data/${dirid}.orig $model_dir/decode_${dirid}.orig || exit 1
  touch $model_dir/decode_${dirid}.orig/.done
fi

if [ ! -s $temp_dir/pred.1.gz ]; then
  $cmd JOB=1:$my_nj $model_dir/decode_${dirid}.orig/log/predict.JOB.log \
    gunzip -c $model_dir/decode_${dirid}.orig/ali.JOB.gz \| \
    ali-to-phones --per-frame=true $model_dir/final.mdl ark:- ark,t:- \| \
    utils/int2sym.pl -f 2- $lang/phones.txt \| \
    gzip -c '>' $temp_dir/pred.JOB.gz || exit 1
fi

if [ ! -f $temp_dir/.pred.done ]; then
  mkdir -p $temp_dir/pred
  for n in `seq $my_nj`; do gunzip -c $temp_dir/pred.$n.gz; done | \
    python -c "import sys
for l in sys.stdin.readlines():
  splits = l.strip().split()
  file_handle = open(\""$temp_dir"/pred/%s.pred\" % splits[0], 'w')
  file_handle.write(l)
  file_handle.close()" || exit 1
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

mkdir -p $data/$type.seg

if [ ! -s $data/$type.seg/segments ] ; then
  t1=$(date +%s)
  mkdir -p $temp_dir/log
  local/resegment/segmentation.py --verbose 2 $segmentation_opts $temp_dir/pred $temp_dir/phone_map.txt \
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
  if [ ! -f exp/tri4_ali_$type/.done ]; then
    steps/align_fmllr.sh --nj $my_nj --cmd "$cmd" \
      $data/$type $lang exp/tri4 exp/tri4_ali_$type || exit 1;
    touch exp/tri4_ali_$type/.done
  fi
  
  if [ ! -f $data/${dirid}/text ]; then
    # Get the file $data/$type.seg/text
    [ ! -s $data/$type/reco2file_and_channel ] && cat $data/$type/segments | awk '{print $2" "$2" "1}' > $data/$type/reco2file_and_channel
    [ ! -s $data/$type.seg/reco2file_and_channel ] && cat $data/$type.seg/segments | awk '{print $2" "$2" "1}' > $data/$type.seg/reco2file_and_channel
    steps/resegment_text.sh --cmd "$cmd" $data/$type $lang \
      exp/tri4_ali_$type $data/$type.seg $temp_dir || exit 1
    [ ! -f $data/$type.seg/text ] && exit 1
    utils/fix_data_dir.sh $data/${dirid}
    utils/validate_data_dir.sh --no-feats --no-text $data/${dirid}
  fi
fi

touch $data/$dirid/.done

echo ---------------------------------------------------------------------
echo "Resegment data Finished successfully on" `date`
echo ---------------------------------------------------------------------

exit 0
