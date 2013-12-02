#!/bin/bash
set -o pipefail

. cmd.sh
[ -f local.conf ] && . ./local.conf

train_nj=30
get_whole_transcripts=false
add_fillers_options="--num-fillers 10 --count-threshold 20"
extract_insertions_options="--segments data/train/segments"

. utils/parse_options.sh

[ -f ./path.sh ] && . ./path.sh

if [ $# -ne 3 ]; then
  echo "Usage: $0 [options] <train-decode-dir> <human-ctm> <out-data-dir>"
  echo " Options:"
  echo "    --get-whole-transcripts (true|false) If true, all segments including the empty ones are kept."
  echo "e.g.:"
  echo "$0 exp/sgmm5_mmi_b0.1/decode_fmllr_train_it4_reseg data/train/ctm data_augmented/train"
  exit 1;
fi

train_decode_dir=$1
human_ctm=$2
data_out=$3

[ ! -d $train_decode_dir ] && exit 1
[ ! -f $human_ctm ] && exit 1

[ ! -f $train_decode_dir/train.ctm ] && exit 1
[ ! -f $train_decode_dir/train.ctm.sgml ] && exit 1

mkdir -p $data_out

data=train
my_nj=$train_nj

[ -d data/train_whole ] || exit 1

if [ ! -f $data_out/.done ]; then
  utils/extract_insertions.py $extract_insertions_options $train_decode_dir/train.ctm.sgml > $data_out/insertions.txt || exit 1
  
  utils/add_fillers_to_transcription.py $add_fillers_options $human_ctm $train_decode_dir/train.ctm $data_out/insertions.txt > $data_out/ctm.augmented || exit 1

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
