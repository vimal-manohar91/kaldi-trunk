#!/bin/bash
set -o pipefail

. cmd.sh
[ -f local.conf ] && . ./local.conf

get_whole_transcripts=false
add_fillers_options="--num-fillers 4 --count-threshold 20"

. utils/parse_options.sh

[ -f ./path.sh ] && . ./path.sh

if [ $# -ne 5 ]; then
  echo "Usage: $0 [options] <train-decode-dir> <train-ali-dir> <out-data-dir>"
  echo " Options:"
  echo "    --get-whole-transcripts (true|false) If true, all segments including the empty ones are kept."
  echo "e.g.:"
  echo "$0 exp/sgmm5_mmi_b0.1/decode_fmllr_train_it4_reseg/score_8 exp/sgmm5_ali data_augmented/train"
  exit 1;
fi

train_decode_dir=$1
train_ali_dir=$2
data_out=$3

[ ! -f $train_decode_dir/train.ctm ] && exit 1
[ ! -f $train_decode_dir/train.ctm.sgml ] && exit 1
[ ! -f $train_ali_dir/ali.1.gz ] && exit 1

if [ ! -f data/train/ctm ]; then
  steps/get_train_ctm.sh --cmd "$train_cmd" --use-segments true data/train data/lang $train_ali_dir || exit 1
fi

mkdir -p $data_out

data=train

[ -d data/train_whole ] || exit 1

if [ ! -f $data_out/.done ]; then
  utils/extract_insertions.py $train_decode_dir/train.ctm.sgml > $data_out/insertions.txt || exit 1
  
  utils/add_fillers_to_transcription.py "$add_fillers_options" data/train/ctm $train_decode_dir/train.ctm $data_out/insertions.txt > $data_out/ctm.augmented $human_segments || exit 1

  for f in data/train_whole/{*.scp,reco2file_and_channel,segments,spk2utt,utt2spk,stm}; do 
    [ ! -f $f ] && exit 1
    cp $f $data_out || exit 1
  done
  steps/retranscribe.sh --get-whole-transcripts $get_whole_transcripts \
    --cmd "$train_cmd" data/train_whole data/lang \
    $data_out/ctm.augmented $data_out exp/tri4b_augment_train || exit 1

  touch $data_out/.done
fi

echo ---------------------------------------------------------------------
echo "Retranscribe data Finished successfully on" `date`
echo ---------------------------------------------------------------------

exit 0
