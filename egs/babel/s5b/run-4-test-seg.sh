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

data=data                 # Base data directory 
type=dev10h               # Will look for data in $data/$type. The directory
                          # must be prepared completely with wav.scp, 
                          # reco2file_and_channel, kws and stm (if present)
segmentation_opts="--isolated-resegmentation --min-inter-utt-silence-length 1.0 --silence-proportion 0.05"

. utils/parse_options.sh
. ./path.sh
. ./cmd.sh

if [[ "$type" == "dev10h" || "$type" == "dev2h" ]] ; then
  eval reference_rttm=\$${type}_rttm_file
  [ -f $reference_rttm ] && segmentation_opts="$segmentation_opts --reference-rttm $reference_rttm"
fi

datadir=$data/$type
dirid=${type}.seg

echo ---------------------------------------------------------------------
echo "Resegment data in ${data}/${dirid} on " `date`
echo ---------------------------------------------------------------------

if [ ! -s ${data}/${dirid}/feats.scp ]; then
  local/resegment/run_segmentation.sh \
    --noise_oov false \
    --segmentation_opts "$segmentation_opts" \
    $datadir $data/lang exp/tri4b_seg \
    exp/tri4b_resegment_$type || exit 1
fi

echo ---------------------------------------------------------------------
echo "Finished successfully on" `date`
echo ---------------------------------------------------------------------

exit 0
