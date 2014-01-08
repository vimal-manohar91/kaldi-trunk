#!/bin/bash
set -o pipefail

. cmd.sh
[ -f local.conf ] && . ./local.conf
get_whole_transcripts=false
add_fillers_opts="--num-fillers 5 --count-threshold 30"
extract_insertions_opts="" 
clean_insertions=false

. utils/parse_options.sh

[ -f ./path.sh ] && . ./path.sh

if [ $# -ne 4 ]; then
  echo "Usage: $0 [options] <in-data-dir> <train-decode-dir> <train-ali-dir> <out-data-dir>"
  echo " Options:"
  echo "    --get-whole-transcripts (true|false) If true, all segments including the empty ones are kept."
  echo "    --extract-insertions-opts. Give --segments data/train/segments if you want to add insertions only outside the human segments"
  echo "e.g.:"
  echo "$0 data exp/sgmm5_mmi_b0.1/decode_fmllr_train_it4_reseg/score_8 exp/sgmm5_ali data_augmented/train"
  exit 1;
fi

data_in=$1
train_decode_dir=$2
train_ali_dir=$3
data_out=$4

human_ctm=exp/tri4b_augment_train/human_ctm
human_segments_file=$data_in/train/segments

[ ! -d $train_decode_dir ] && exit 1
[ ! -f $train_decode_dir/train.ctm ] && [ ! -f $train_decode_dir/train.seg.ctm ] && exit 1
[ ! -f $train_decode_dir/train.ctm.sgml ] && [ ! -f $train_decode_dir/train.seg.ctm.sgml ] && exit 1
[ ! -f $human_segments_file ] && exit 1

mkdir -p exp/tri4b_augment_train
mkdir -p exp/tri4b_augment_train/log

if [ ! -f $human_ctm ]; then
  steps/get_train_ctm.sh --cmd "$train_cmd" --use-segments true $data_in/train $data_in/lang $train_ali_dir || exit 1
  [ ! -f $train_ali_dir/ctm ] && exit 1
  mv $train_ali_dir/ctm $human_ctm || exit 1
fi

mkdir -p $data_out

data=train

[ -d $data_in/train_whole ] || exit 1

decode_ctm=$train_decode_dir/train.ctm
[ ! -f $decode_ctm ] && decode_ctm=$train_decode_dir/train.seg.ctm
[ ! -f $decode_ctm ] && exit 1

if [ ! -f $data_out/.done ]; then
  utils/extract_insertions.py $extract_insertions_opts $decode_ctm.sgml > exp/tri4b_augment_train/insertions.txt 2> exp/tri4b_augment_train/log/extract_insertions.log || exit 1
  
  utils/add_fillers_to_transcription.py $add_fillers_opts $human_ctm $decode_ctm exp/tri4b_augment_train/insertions.txt $human_segments_file > exp/tri4b_augment_train/ctm.augmented 2> exp/tri4b_augment_train/log/add_fillers.log || exit 1

  for f in $data_in/train_whole/{wav.scp,reco2file_and_channel,segments}; do 
    [ ! -f $f ] && exit 1
    cp $f $data_out || exit 1
  done
  steps/retranscribe.sh --clean-insertions $clean_insertions --get-whole-transcripts $get_whole_transcripts \
    exp/tri4b_augment_train/ctm.augmented $data_out exp/tri4b_augment_train || exit 1
  touch $data_out/.done
fi

echo ---------------------------------------------------------------------
echo "Retranscribe data Finished successfully on" `date`
echo ---------------------------------------------------------------------

exit 0
