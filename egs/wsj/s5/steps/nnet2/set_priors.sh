#!/bin/bash

# Copyright 2012 Johns Hopkins University (Author: Daniel Povey).  Apache 2.0.
# Copyright 2014 Vimal Manohar
# This script, which will generally be called from other neural-net training
# scripts, extracts the training examples used to train the neural net (and also
# the validation examples used for diagnostics), and puts them in separate archives.

# Begin configuration section.
cmd=run.pl
feat_type=
num_utts_subset=-1   # number of utterances to use in setting priors
transform_dir=      
stage=0
splice_width=4 # meaning +- 4 frames on each side for second LDA

echo "$0 $@"  # Print the command line for logging

if [ -f path.sh ]; then . ./path.sh; fi
. parse_options.sh || exit 1;


if [ $# != 2 ]; then
  echo "Usage: steps/nnet2/set_priors.sh [opts] <data> <exp-dir>"
  echo " e.g.: steps/nnet2/set_priors.sh data/train exp/tri4_nnet"
  echo ""
  echo "Main options (for others, see top of script file)"
  echo "  --cmd (utils/run.pl|utils/queue.pl <queue opts>) # how to run jobs."
  echo "                                                   # the middle."
  echo "  --stage <0>     # Run from a stage"
  
  exit 1;
fi

data=$1
dir=$2

# Check some files.
for f in $data/feats.scp; do
  [ ! -f $f ] && echo "$0: no such file $f" && exit 1;
done

nj=`cat $dir/num_jobs` || exit 1;  # number of jobs
# in this dir we'll have just one job.
sdata=$data/split$nj
utils/split_data.sh $data $nj

if [ $num_utts_subset -le 0 ]; then
  awk '{print $1}' $data/utt2spk > $dir/set_priors_uttlist
else
  awk '{print $1}' $data/utt2spk | utils/filter_scp.pl --exclude $dir/valid_uttlist | \
       head -$num_utts_subset > $dir/set_priors_uttlist || exit 1;
fi

norm_vars=`cat $dir/norm_vars 2>/dev/null` || norm_vars=false # cmn/cmvn option, default false.

## Set up features. 
if [ -z $feat_type ]; then
  if [ -f $dir/final.mat ] && [ ! -f $transform_dir/raw_trans.1 ]; then feat_type=lda; else feat_type=raw; fi
fi
echo "$0: feature type is $feat_type"

case $feat_type in
  raw) feats="ark,s,cs:utils/filter_scp.pl $dir/set_priors_uttlist $sdata/JOB/feats.scp | apply-cmvn --norm-vars=$norm_vars --utt2spk=ark:$sdata/JOB/utt2spk scp:$sdata/JOB/cmvn.scp scp:- ark:- |"
   ;;
  lda) 
    splice_opts=`cat $dir/splice_opts 2>/dev/null`
    feats="ark,s,cs:utils/filter_scp.pl $dir/set_priors_uttlist $sdata/JOB/feats.scp | apply-cmvn --norm-vars=$norm_vars --utt2spk=ark:$sdata/JOB/utt2spk scp:$sdata/JOB/cmvn.scp scp:- ark:- | splice-feats $splice_opts ark:- ark:- | transform-feats $dir/final.mat ark:- ark:- |"
    ;;
  *) echo "$0: invalid feature type $feat_type" && exit 1;
esac

if [ -f $transform_dir/trans.1 ] && [ $feat_type != "raw" ]; then
  echo "$0: using transforms from $transform_dir"
  feats="$feats transform-feats --utt2spk=ark:$sdata/JOB/utt2spk ark:$transform_dir/trans.JOB ark:- ark:- |"
fi
if [ -f $transform_dir/raw_trans.1 ] && [ $feat_type == "raw" ]; then
  echo "$0: using raw-fMLLR transforms from $transform_dir"
  feats="$feats transform-feats --utt2spk=ark:$sdata/JOB/utt2spk ark:$transform_dir/raw_trans.JOB ark:- ark:- |"
fi

mkdir -p $dir/temp

cp $dir/final.mdl $dir/temp/final.mdl

if [ $stage -le 0 ]; then
$cmd JOB=1:$nj $dir/log/forward_post.JOB.log \
  nnet-logprob2 $dir/temp/final.mdl "$feats" ark:- ark:/dev/null \| \
  prob-to-post ark:- "ark:| gzip -c > $dir/temp/post.JOB.gz" || exit 1
fi

if [ $stage -le 1 ]; then
  $cmd $dir/log/set_priors.log \
    post-to-counts "ark:gunzip -c $dir/temp/post.*.gz |" - \| \
    nnet-am-set-priors $dir/temp/final.mdl - $dir/final.mdl || exit 1
fi
