#!/bin/bash

# This script prepares the untranscribed data directory in 
# Kaldi format and does the automatic segmenation of the data 
# using the segmentation model passed as an argument
#
# Author: Vimal Manohar

set -e           #Exit on non-zero return code from any command
set -o pipefail  #Exit if any of the commands in the pipeline will
                 #return non-zero return code

. conf/common_vars.sh || exit 1;
. ./lang.conf || exit 1;
. cmd.sh
. path.sh

set -u           #Fail on an undefined variable

segmentation_opts="--isolated-resegmentation --min-inter-utt-silence-length 1.0 --silence-proportion 0.05"
nj=32

#debugging stuff
echo $0 $@

. parse_options.sh || exit 1

if [ $# -ne 2 ]; then
  echo "Usage: $0 [options] <segmenation-model-dir> <out-data-dir>"
  echo " Options:"
  echo "    --segmentation-opts '--opt1 opt1val --opt2 opt2val' # options for segmentation.py"
  echo "    --nj             # Number of parallel jobs"
  echo 
  echo "e.g.:"
  echo "$0 exp/tri4b_seg data/train_unt"
  exit 1
fi

model_dir=$1
datadir=$2

sph2pipe=`which sph2pipe`
if [ $? -ne 0 ] ; then
  echo "Could not find sph2pipe binary. Add it to PATH"  
  exit 1;
fi

sox=`which sox`
if [ $? -ne 0 ] ; then
  echo "Could not find sox binary. Add it to PATH"  
  exit 1;
fi

mkdir -p $datadir
dirid=`basename $datadir`

if [ ! -f $datadir/wav.scp ]; then
  (
  for file in `utils/filter_scp.pl --exclude $train_data_list $(dirname $train_data_list)/train.FullLP.list`; do 
    if [ -f $train_data_dir/audio/${file}.sph ]; then
      echo "$file $sph2pipe -f wav -p -c 1 $train_data_dir/audio/${file}.sph |" 
    elif [ -f $train_data_dir/audio/${file}.wav ]; then
      echo "$file $sox $train_data_dir/audio/${file}.wav -r 8000 -c 1 -b 16 -t wav - downsample |"
    fi
  done
  audiopath=$(dirname $train_data_dir)/untranscribed-training/audio
  for file in `cat $(dirname $train_data_list)/train.untranscribed.list`; do 
    if [ -f $audiopath/${file}.sph ]; then
      echo "$file $sph2pipe -f wav -p -c 1 $audiopath/${file}.sph |" 
    elif [ -f $audiopath/${file}.wav ]; then
      echo "$file $sox $audiopath/${file}.wav -r 8000 -c 1 -b 16 -t wav - downsample |"
    fi
  done 
  ) | sort > $datadir/wav.scp
fi

[ ! -f $model_dir/final.mdl ] && echo "$model_dir/final.mdl not found!" && exit 1

local/resegment/run_segmentation.sh --segmentation_opts "${segmentation_opts}" --nj $nj $datadir data/lang $model_dir exp/tri4b_resegment_${dirid} || exit 1
