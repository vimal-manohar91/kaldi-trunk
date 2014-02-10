#!/bin/bash
# Copyright 2012  Johns Hopkins University (Author: Daniel Povey).  Apache 2.0.

# This trains two GMMs, one for speech and one for silence, by clustering
# the Gaussians from a trained HMM/GMM system and then doing a few
# iterations of EM training like for the UBM
# We mostly use this for Voice Activity Detection (VAD)

# Begin configuration section.
nj=4
cmd=run.pl
stage=-10
num_iters=3
no_fmllr=false
silphonelist=
speechphonelist=
# End configuration section.

echo "$0 $@"  # Print the command line for logging

if [ -f path.sh ]; then . ./path.sh; fi
. parse_options.sh || exit 1;

if [ $# != 6 ]; then
  echo "Usage: steps/train_vad_gmm.sh <speech-num-gauss> <silence-num-gauss> <data> <lang> <ali-dir> <exp>"
  echo " e.g.: steps/train_vad_gmm.sh 400 100 data/train data/lang exp/tri4_ali exp/gmm_vad4"
  echo "main options (for others, see top of script file)"
  echo "  --config <config-file>                           # config containing options"
  echo "  --cmd (utils/run.pl|utils/queue.pl <queue opts>) # how to run jobs."
  echo "  --silence-weight <sil-weight>                    # weight for silence (e.g. 0.5 or 0.0)"
  echo "  --num-iters <#iters>                             # Number of iterations of E-M"\
  echo "  --no-fmllr (true|false)                          # ignore speaker matrices even if present"
  echo "  --use-full-cov (true|false)           use full covariance Gaussians"
  exit 1;
fi

speech_num_gauss=$1
silence_num_gauss=$2
data=$3
lang=$4
alidir=$5
dir=$6

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

if [ $stage -le -3 ]; then
  $cmd JOB=1:$nj $dir/log/acc.JOB.log \
    ali-to-post "ark:gunzip -c $alidir/ali.JOB.gz|" ark:-  \| \
    gmm-acc-stats $alidir/final.mdl "$feats" ark:- $dir/JOB.acc
  
  [ `ls $dir/*.acc | wc -w` -ne "$nj" ] && echo "$0: Wrong #accs" && exit 1;

  echo "$0: clustering model $alidir/final.mdl to get initial speech GMMs"
  $cmd $dir/log/cluster_speech.log \
    merge-gaussians-to-gmm --binary=false --intermediate-num-gauss=$((speech_num_gauss*4)) --gmm-num-gauss=$speech_num_gauss \
    --verbose=2 --fullcov-gmm=false $alidir/final.mdl \
    "gmm-sum-accs - $dir/*.acc |" $speechphonelist $dir/speech.0.mdl || exit 1;

  echo "$0: clustering model $alidir/final.mdl to get initial silence GMMs"
  $cmd $dir/log/cluster_silence.log \
    merge-gaussians-to-gmm --binary=false --intermediate-num-gauss=$((silence_num_gauss*4)) --gmm-num-gauss=$silence_num_gauss \
    --verbose=2 --fullcov-gmm=false --reduce-state-factor=1.0 $alidir/final.mdl \
    "gmm-sum-accs - $dir/*.acc |" $silphonelist $dir/silence.0.mdl || exit 1;
fi

rm $dir/*.acc

mkdir -p $dir/lang
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

utils/prepare_lang.sh --num-sil-states 1 --num-nonsil-states 1 \
  --position-dependent-phones false \
  $dir/local/dict 2 $dir/local/lang $dir/lang

if [ $stage -le -2 ]; then
  echo "<Topology> 
<TopologyEntry> 
<ForPhones>
1 2
</ForPhones> 
<State> 0 <PdfClass> 0 <Transition> 1 1.0 </State> 
<State> 1 </State>
</TopologyEntry> 
</Topology>" > $dir/lang/topo

  {
    feat_dim=`gmm-info $alidir/final.mdl | grep "feature dimension" | cut -d ' ' -f 3`
    gmm-init-mono --binary=false $dir/lang/topo $feat_dim - $dir/tree | \
      copy-transition-model --binary=false - -
    echo "<DIMENSION> $feat_dim <NUMPDFS> 2"
    cat $dir/silence.0.mdl
    cat $dir/speech.0.mdl 
  } > $dir/0.mdl || exit 1

  gmm-copy $dir/0.mdl $dir/1.mdl || exit 1
fi

echo $nj > $dir/num_jobs
mkdir -p $dir/data

{
  echo $silphonelist | tr ':' '\n' | awk '{print $1" 1"}'
  echo $speechphonelist | tr ':' '\n' | awk '{print $1" 2"}' 
} | sort -k 1 -n > $dir/phone_map.txt

if [ $stage -le -1 ]; then
  ali-to-phones --per-frame=true \
    $alidir/final.mdl "ark:gunzip -c $alidir/ali.*.gz|" ark,t:- | \
    utils/apply_map.pl -f 2- $dir/phone_map.txt | sort > $dir/data/text || exit 1

  cat $dir/data/text | cut -d ' ' -f 1 --complement > $dir/local/train_text || exit 1
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

for f in wav.scp utt2spk spk2utt segments feats.scp; do
  cp $data/$f $dir/data
done

utils/fix_data_dir.sh $dir/data || exit 1

sdata=$dir/data/split$nj;
split_data.sh $dir/data $nj || exit 1;

if [ $stage -le 0 ]; then
  echo "$0: compiling graphs of transcripts"
  $cmd JOB=1:$nj $dir/log/compile_graphs.JOB.log \
    compile-train-graphs $dir/tree $dir/1.mdl  $dir/lang/L.fst  \
    "ark:utils/sym2int.pl -f 2- $dir/lang/words.txt < $dir/data/split$nj/JOB/text |" \
    "ark:|gzip -c >$dir/fsts.JOB.gz" || exit 1;
fi

#echo "$0: copying alignments and converting into required form for GMM VAD"
#$cmd JOB=1:$nj $dir/log/copy_align.JOB.log \
#  gunzip -c $alidir/ali.JOB.gz \| \
#  utils/apply_map.pl -f 2- data/local/lexicon.txt \| \
#  gzip -c $dir/ali.JOB.gz

x=1
while [ $x -lt $num_iters ]; do
  echo "$0: training pass $x"
  if [ $stage -le $x ]; then
    if [ "$x" -eq "1" ]; then
      echo "$0: aligning data"
      mdl=$dir/$x.mdl
      $cmd JOB=1:$nj $dir/log/align.$x.JOB.log \
        gmm-align-compiled "$mdl" \
         "ark:gunzip -c $dir/fsts.JOB.gz|" "$feats" \
         "ark:|gzip -c >$dir/ali.JOB.gz" || exit 1;
    fi
    $cmd JOB=1:$nj $dir/log/acc.$x.JOB.log \
      gmm-acc-stats-ali  $dir/$x.mdl "$feats" \
       "ark,s,cs:gunzip -c $dir/ali.JOB.gz|" $dir/$x.JOB.acc || exit 1;
    $cmd $dir/log/update.$x.log \
      gmm-est --power=0.25 $dir/$x.mdl \
       "gmm-sum-accs - $dir/$x.*.acc |" $dir/$[$x+1].mdl || exit 1;
    rm $dir/$x.mdl $dir/$x.*.acc
  fi
  x=$[$x+1];
done

rm $dir/final.mdl 2>/dev/null
ln -s $x.mdl $dir/final.mdl

utils/mkgraph.sh --mono $dir/lang $dir $dir/graph || exit 1

# Summarize warning messages...
utils/summarize_warnings.pl  $dir/log
