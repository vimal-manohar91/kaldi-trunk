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
alpha=4.0
max_change=40.0
initial_learning_rate=0.008
final_learning_rate=0.0008
nnet_stage=-100

# End configuration section.

echo "$0 $@"  # Print the command line for logging

if [ -f path.sh ]; then . ./path.sh; fi
. parse_options.sh || exit 1;

if [ $# != 4 ]; then
  echo "Usage: steps/train_vad_nnet.sh  <data> <lang> <ali-dir> <exp-dir>"
  echo " e.g.: steps/train_vad_nnet.sh data/train data/lang exp/tri5_ali exp/tri6_vad_nnet"
  echo "main options (for others, see top of script file)"
  echo "  --config <config-file>                           # config containing options"
  echo "  --cmd (utils/run.pl|utils/queue.pl <queue opts>) # how to run jobs."
  echo "  --silence-weight <sil-weight>                    # weight for silence (e.g. 0.5 or 0.0)"
  echo "  --num-iters <#iters>                             # Number of iterations of E-M"
  exit 1;
fi

data=$1
lang=$2
alidir=$3
dir=$4

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
norm_vars=`cat $alidir/norm_vars 2>/dev/null` || norm_vars=false # cmn/cmvn option, default false.

## Set up features.
feat_type=delta
echo "$0: feature type is $feat_type"

feats="ark,s,cs:apply-cmvn --norm-vars=$norm_vars --utt2spk=ark:$sdata/JOB/utt2spk scp:$sdata/JOB/cmvn.scp scp:$sdata/JOB/feats.scp ark:- | add-deltas ark:- ark:- |"

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
  cp $alidir/ali.*.gz $dir/ali 2> /dev/null
  cp $alidir/norm_vars $dir/ali
  echo $nj > $dir/ali/num_jobs

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
  
  feat_dim=`feat-to-dim "ark:head -1 $data/feats.scp | add-deltas scp:- ark:- |" ark,t:- | head -1 | cut -d ' ' -f 2`

  gmm-init-mono $dir/lang/topo $feat_dim \
    $dir/ali/final.mdl $dir/ali/tree || exit 1
fi

if [ $stage -le 1 ]; then
  . conf/common.limitedLP || exit 1

  steps/nnet2/train_pnorm.sh \
    --stage $nnet_stage \
    --initial-learning-rate $initial_learning_rate \
    --final-learning-rate $final_learning_rate \
    --num-hidden-layers 2 \
    --pnorm-input-dim 500 \
    --pnorm-output-dim 50\
    --cmd "$train_cmd" \
    --num-epochs 5 --num-epochs-extra 2 --num-iters-final 10 \
    "${dnn_gpu_parallel_opts[@]}" \
    $data $dir/lang $dir/ali $dir || exit 1
fi

if [ $stage -le 2 ]; then
  utils/mkgraph.sh --mono $dir/lang $dir $dir/graph || exit 1
fi

# Summarize warning messages...
utils/summarize_warnings.pl  $dir/log

