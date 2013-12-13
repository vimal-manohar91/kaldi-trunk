#!/bin/bash
set -o pipefail

. cmd.sh
[ -f local.conf ] && . ./local.conf
get_whole_transcripts=false
add_fillers_opts="--num-fillers 10 --count-threshold 20"
extract_insertions_opts=""

. utils/parse_options.sh

[ -f ./path.sh ] && . ./path.sh

if [ $# -ne 3 ]; then
  echo "Usage: $0 [options] <train-decode-dir> <train-ali-dir> <out-data-dir>"
  echo " Options:"
  echo "    --get-whole-transcripts (true|false) If true, all segments including the empty ones are kept."
  echo "    --extract-insertions-opts. Give --segments data/train/segments if you want to add insertions only outside the human segments"
  echo "e.g.:"
  echo "$0 exp/sgmm5_mmi_b0.1/decode_fmllr_train_it4_reseg/score_8 exp/sgmm5_ali data_augmented/train"
  exit 1;
fi

train_decode_dir=$1
train_ali_dir=$2
data_out=$3

human_ctm=data/train/ctm
human_segments_file=data/train/segments

[ ! -d $train_decode_dir ] && exit 1
[ ! -f $train_decode_dir/train.ctm ] && exit 1
[ ! -f $train_decode_dir/train.ctm.sgml ] && exit 1
[ ! -f $human_segments_file ] && exit 1

if [ ! -f $human_ctm ]; then
  steps/get_train_ctm.sh --cmd "$train_cmd" --use-segments true data/train data/lang $train_ali_dir || exit 1
  [ ! -f $train_ali_dir/ctm ] && exit 1
  mv $train_ali_dir/ctm $human_ctm || exit 1
fi

mkdir -p $data_out

data=train

[ -d data/train_whole ] || exit 1

mkdir -p exp/tri4b_augment_train

if [ ! -f $data_out/.done ]; then
  utils/extract_insertions.py $extract_insertions_opts $train_decode_dir/train.ctm.sgml > $data_out/insertions.txt 2> exp/tri4b_augment_train/extract_insertions.log || exit 1
  
  utils/add_fillers_to_transcription.py $add_fillers_opts $human_ctm $train_decode_dir/train.ctm $data_out/insertions.txt $human_segments_file > $data_out/ctm.augmented 2> exp/tri4b_augment_train/add_fillers.log || exit 1

  for f in data/train_whole/{*.scp,reco2file_and_channel,segments,spk2utt,utt2spk,stm}; do 
    [ ! -f $f ] && exit 1
    cp $f $data_out || exit 1
  done
  steps/retranscribe.sh --get-whole-transcripts $get_whole_transcripts \
    --cmd "$train_cmd" data/train_whole data/lang \
    $data_out/ctm.augmented $data_out exp/tri4b_augment_train || exit 1
  utils/fix_data_dir.sh $data_out || exit 1

  touch $data_out/.done
fi

echo ---------------------------------------------------------------------
echo "Retranscribe data Finished successfully on" `date`
echo ---------------------------------------------------------------------

exit 0
