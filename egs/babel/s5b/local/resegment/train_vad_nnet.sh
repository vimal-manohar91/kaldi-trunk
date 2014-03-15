#!/bin/bash
# Copyright 2014  Vimal Manohar
# Apache 2.0.

# We mostly use this for Voice Activity Detection (VAD)

# Begin configuration section.
cmd=run.pl
stage=-10
num_iters=3
no_fmllr=false
silphonelist=
speechphonelist=
transform_dir=
alpha=4.0
max_change=40.0
initial_learning_rate=0.008

# End configuration section.

echo "$0 $@"  # Print the command line for logging

if [ -f path.sh ]; then . ./path.sh; fi
. parse_options.sh || exit 1;

if [ $# != 5 ]; then
  echo "Usage: steps/train_vad_nnet.sh <model-dir> <data> <lang> <ali-dir> <exp-dir>"
  echo " e.g.: steps/train_vad_nnet.sh exp/tri6_nnet data/train data/lang exp/tri5_ali exp/tri6_vad_nnet"
  echo "main options (for others, see top of script file)"
  echo "  --config <config-file>                           # config containing options"
  echo "  --cmd (utils/run.pl|utils/queue.pl <queue opts>) # how to run jobs."
  echo "  --silence-weight <sil-weight>                    # weight for silence (e.g. 0.5 or 0.0)"
  echo "  --num-iters <#iters>                             # Number of iterations of E-M"
  echo "  --transform-dir                                  # Overrides alidir if present"
  exit 1;
fi

model_dir=$1
data=$2
lang=$3
alidir=$4
dir=$5

for f in $data/feats.scp $lang/L.fst $alidir/ali.1.gz $alidir/final.mdl; do
  [ ! -f $f ] && echo "No such file $f" && exit 1;
done

# Set various variables.

# silphonelist must typically include silence phones and noise phones
# other than <oov>
if [ -z $silphonelist ]; then
  silphonelist=`cat $lang/phones/silence.csl` || exit 1;
fi

# speechphonelist must typically include speech phones and <oov>
if [ -z $speechphonelist ]; then
  speechphonelist=`cat $lang/phones/nonsilence.csl` || exit 1;
fi

nj=`cat $alidir/num_jobs` || exit 1;

mkdir -p $dir/log
echo $nj > $dir/num_jobs

sdata=$data/split$nj;
[[ -d $sdata && $data/feats.scp -ot $sdata ]] || split_data.sh $data $nj || exit 1;
splice_opts=`cat $alidir/splice_opts 2>/dev/null` # frame-splicing options.
norm_vars=`cat $alidir/norm_vars 2>/dev/null` || norm_vars=false # cmn/cmvn option, default false.

## Set up features.
if [ -f $alidir/final.mat ]; then feat_type=lda; else feat_type=delta; fi
echo "$0: feature type is $feat_type"

case $feat_type in
  delta) feats="ark,s,cs:apply-cmvn --norm-vars=$norm_vars --utt2spk=ark:$sdata/JOB/utt2spk scp:$sdata/JOB/cmvn.scp scp:$sdata/JOB/feats.scp ark:- | add-deltas ark:- ark:- |";;
  lda) feats="ark,s,cs:apply-cmvn --norm-vars=$norm_vars --utt2spk=ark:$sdata/JOB/utt2spk scp:$sdata/JOB/cmvn.scp scp:$sdata/JOB/feats.scp ark:- | splice-feats $splice_opts ark:- ark:- | transform-feats $alidir/final.mat ark:- ark:- |"
    cp $alidir/final.mat $dir    
    ;;
  *) echo "$0: invalid feature type $feat_type" && exit 1;
esac

[ -z $transform_dir ] && transform_dir=$alidir
if [ -f $transform_dir/trans.1 ]; then
  feats="$feats transform-feats --utt2spk $sdata/JOB/utt2spk $transform_dir/trans.JOB ark:- ark:- |"
fi

mkdir -p $dir/local
mkdir -p $dir/local/dict

echo "1" > $dir/local/dict/silence_phones.txt
echo "1" > $dir/local/dict/optional_silence.txt
echo "2" > $dir/local/dict/nonsilence_phones.txt
echo "1 1
2 2" > $dir/local/dict/lexicon.txt
echo "1
2
1 2" > $dir/local/dict/extra_questions.txt

if [ $stage -le -3 ]; then
  mkdir -p $dir/lang
  utils/prepare_lang.sh --num-sil-states 1 --num-nonsil-states 1 \
    --position-dependent-phones false \
    $dir/local/dict 2 $dir/local/lang $dir/lang
fi 

{
  echo $silphonelist | tr ':' '\n' | awk '{print $1" 1"}'
  echo $speechphonelist | tr ':' '\n' | awk '{print $1" 2"}' 
} | sort -k 1 -n > $dir/local/phone_map.txt

if [ $stage -le -2 ]; then
  $cmd JOB=1:$nj $dir/log/get_text.JOB.log ali-to-phones --per-frame=true \
    $alidir/final.mdl "ark:gunzip -c $alidir/ali.JOB.gz|" ark,t:- \| \
    utils/apply_map.pl -f 2- $dir/local/phone_map.txt '>' $dir/local/text.JOB
  for n in `seq 1 $nj`; do cat $dir/local/text.$n; done | sort > $dir/local/text || exit 1
  rm $dir/local/text.*

  cat $dir/local/text | cut -d ' ' -f 1 --complement > $dir/local/train_text || exit 1
  ngram-count -text $dir/local/train_text -order 3 -addsmooth1 1 -lm $dir/local/arpa.gz || exit 1

  gunzip -c $dir/local/arpa.gz | \
    awk '/\\1-grams/{state=1;} /\\2-grams:/{ state=2; }
  {if(state == 1 && NF == 3) { printf("-99\t%s\t-99\n", $2); } else {print;}}' | \
    arpa2fst - - | fstprint | \
    utils/eps2disambig.pl | utils/s2eps.pl | \
    awk '{if (NF < 5 || $5 < 100.0) { print; }}' | \
    fstcompile --isymbols=$dir/lang/phones.txt --osymbols=$dir/lang/phones.txt \
    --keep_isymbols=false --keep_osymbols=false | \
    fstconnect | \
    fstrmepsilon > $dir/lang/G.fst || exit 1
  fstisstochastic $dir/lang/G.fst  || echo "[info]: G not stochastic."
fi

if [ $stage -le -1 ]; then
  echo "$0: copying alignments from $alidir and converting into required form for VAD"
  mkdir -p $dir/ali
  mkdir -p $dir/ali/log
  cp -r $alidir/* $dir/ali 2> /dev/null
  $cmd JOB=1:$nj $dir/ali/log/convert_align.JOB.log \
    ali-to-phones --per-frame=true $alidir/final.mdl "ark:gunzip -c $alidir/ali.JOB.gz |" ark,t:- \| \
    utils/apply_map.pl -f 2- $dir/local/phone_map.txt \| \
    copy-int-vector ark,t:- "ark:| gzip -c > $dir/ali/ali.JOB.gz" || exit 1
fi

if [ $stage -le 0 ]; then
  cat >$dir/lang/topo <<EOF
<Topology> 
<TopologyEntry> 
<ForPhones>
1 2
</ForPhones> 
<State> 0 <PdfClass> 0 <Transition> 1 1.0 </State> 
<State> 1 </State>
</TopologyEntry> 
</Topology>
EOF

  num_units=`nnet-am-info $model_dir/final.mdl 2> /dev/null | grep "SoftmaxComponent" | tail -1 | sed 's/.*output-dim=\([0-9]*\)$/\1/g'`
  [ -z $num_units ] && exit 1

  cat >$dir/seg.config <<EOF
AffineComponentPreconditioned input-dim=$num_units output-dim=2 alpha=$alpha max-change=$max_change learning-rate=$initial_learning_rate param-stddev=0 bias-stddev=0
SoftmaxComponent dim=2
EOF

  feat_dim=`gmm-info $alidir/final.mdl | grep "feature dimension" | cut -d ' ' -f 3`

  mkdir -p $dir/temp

  $cmd $dir/log/nnet_init.log \
    nnet-am-init $dir/tree $dir/lang/topo \
    "nnet-init $dir/seg.config - |" - \| \
    nnet-insert --insert-at=0 --randomize-next-component=false \
    - "nnet-am-copy --copy-tm=false $model_dir/final.mdl - | nnet-remove-components --remove-last-layers=1 - - |" - \| \
    nnet-train-transitions - "ark:gunzip -c $dir/ali/ali.*.gz |" $dir/temp/final.mdl || exit 1

fi

cp $dir/temp/final.mdl $dir/ali/final.mdl
cp $dir/tree $dir/ali/tree

if [ $stage -le 1 ]; then
  learning_rates="0"
  for i in `seq 1 $[$(nnet-am-info $dir/temp/final.mdl 2>/dev/null | grep "num-updatable-components" | cut -d ' ' -f 2)-2]`; do
    learning_rates="$learning_rates:0"
  done
  learning_rates="$learning_rates:0.0008"

  . conf/common.semisupervised.limitedLP

  steps/nnet2/update_nnet.sh \
    --learning-rates $learning_rates \
    "${dnn_update_gpu_parallel_opts[@]}" \
    --num-epochs 5 --num-iters-final 10 \
    --transform-dir $transform_dir \
    $data $dir/lang $dir/ali $dir/temp $dir || exit 1
fi

rm -rf $dir/temp 2>/dev/null

if [ $stage -le 2 ]; then
  utils/mkgraph.sh --mono $dir/lang $dir $dir/graph || exit 1
fi

# Summarize warning messages...
utils/summarize_warnings.pl  $dir/log

