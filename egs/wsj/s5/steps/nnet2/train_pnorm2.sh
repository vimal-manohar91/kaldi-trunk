#!/bin/bash

# Copyright 2012  Johns Hopkins University (Author: Daniel Povey). 
#           2013  Xiaohui Zhang
#           2013  Guoguo Chen
#           2014  Vimal Manohar
# Apache 2.0.

set -u
set -e
set -o pipefail

# This script trains neural network with pnorm nonlinearities. 
# The difference with train_tanh.sh is that, instead of setting 
# hidden_layer_size, you should set pnorm_input_dim and pnorm_output_dim.
# Also the P value (the order of the p-norm) should be set.

# Begin configuration section.
cmd=run.pl
num_epochs=15      # Number of epochs during which we reduce
                   # the learning rate; number of iteration is worked out from this.
num_epochs_extra=5 # Number of epochs after we stop reducing
                   # the learning rate.
num_iters_final=20 # Maximum number of final iterations to give to the
                   # optimization over the validation set.
initial_learning_rate=0.04
final_learning_rate=0.004
bias_stddev=0.5
softmax_learning_rate_factor=1.0 # In the default setting keep the same learning rate.

combine_regularizer=1.0e-14 # Small regularizer so that parameters won't go crazy.
pnorm_input_dim=3000 
pnorm_output_dim=300
p=2
minibatch_size=128 # by default use a smallish minibatch size for neural net
                   # training; this controls instability which would otherwise
                   # be a problem with multi-threaded update.  Note: it also
                   # interacts with the "preconditioned" update which generally
                   # works better with larger minibatch size, so it's not
                   # completely cost free.

samples_per_iter=200000 # each iteration of training, see this many samples
                        # per job.  This option is passed to get_egs.sh
num_jobs_nnet=16   # Number of neural net jobs to run in parallel.  This option
                   # is passed to get_egs.sh.
get_egs_stage=0
spk_vecs_dir=

shuffle_buffer_size=5000 # This "buffer_size" variable controls randomization of the samples
                # on each iter.  You could set it to 0 or to a large value for complete
                # randomization, but this would both consume memory and cause spikes in
                # disk I/O.  Smaller is easier on disk and memory but less random.  It's
                # not a huge deal though, as samples are anyway randomized right at the start.

add_layers_period=2 # by default, add new layers every 2 iterations.
num_hidden_layers=3
stage=-5

io_opts="-tc 5" # for jobs with a lot of I/O, limits the number running at one time.   These don't
splice_width=4 # meaning +- 4 frames on each side for second LDA
randprune=4.0 # speeds up LDA.
alpha=4.0
max_change=10.0
num_threads=16
parallel_opts="-pe smp 16 -l ram_free=1G,mem_free=1G" # by default we use 16 threads; this lets the queue know.
  # note: parallel_opts doesn't automatically get adjusted if you adjust num-threads.
cleanup=true
egs_dir=
lda_opts=
lda_dim=
egs_opts=
transform_dir=     # If supplied, overrides alidir
context_opts= # e.g. set it to "--context-width=5 --central-position=2"  for a
# quinphone system.
leaves_per_group=5 # Relates to the SCTM (state-clustered tied-mixture) aspect:
                   # average number of pdfs in a "group" of pdfs.
sv_proportion=0.5  # Retain only this proportion of singular values in last layer
limit_rank_iters=""
# End configuration section.


echo "$0 $@"  # Print the command line for logging

if [ -f path.sh ]; then . ./path.sh; fi
. parse_options.sh || exit 1;

if [ $# != 5 ]; then
  echo "Usage: $0 [opts] <num_leaves> <data> <lang> <ali-dir> <exp-dir>"
  echo " e.g.: $0 5000 data/train data/lang exp/tri3_ali exp/tri4_nnet"
  echo ""
  echo "Main options (for others, see top of script file)"
  echo "  --config <config-file>                           # config file containing options"
  echo "  --cmd (utils/run.pl|utils/queue.pl <queue opts>) # how to run jobs."
  echo "  --num-epochs <#epochs|15>                        # Number of epochs of main training"
  echo "                                                   # while reducing learning rate (determines #iterations, together"
  echo "                                                   # with --samples-per-iter and --num-jobs-nnet)"
  echo "  --num-epochs-extra <#epochs-extra|5>             # Number of extra epochs of training"
  echo "                                                   # after learning rate fully reduced"
  echo "  --initial-learning-rate <initial-learning-rate|0.02> # Learning rate at start of training, e.g. 0.02 for small"
  echo "                                                       # data, 0.01 for large data"
  echo "  --final-learning-rate  <final-learning-rate|0.004>   # Learning rate at end of training, e.g. 0.004 for small"
  echo "                                                   # data, 0.001 for large data"
  echo "  --num-hidden-layers <#hidden-layers|2>           # Number of hidden layers, e.g. 2 for 3 hours of data, 4 for 100hrs"
  echo "  --add-layers-period <#iters|2>                   # Number of iterations between adding hidden layers"
  echo "  --mix-up <#pseudo-gaussians|0>                   # Can be used to have multiple targets in final output layer,"
  echo "                                                   # per context-dependent state.  Try a number several times #states."
  echo "  --num-jobs-nnet <num-jobs|8>                     # Number of parallel jobs to use for main neural net"
  echo "                                                   # training (will affect results as well as speed; try 8, 16)"
  echo "                                                   # Note: if you increase this, you may want to also increase"
  echo "                                                   # the learning rate."
  echo "  --num-threads <num-threads|16>                   # Number of parallel threads per job (will affect results"
  echo "                                                   # as well as speed; may interact with batch size; if you increase"
  echo "                                                   # this, you may want to decrease the batch size."
  echo "  --parallel-opts <opts|\"-pe smp 16 -l ram_free=1G,mem_free=1G\">      # extra options to pass to e.g. queue.pl for processes that"
  echo "                                                   # use multiple threads... note, you might have to reduce mem_free,ram_free"
  echo "                                                   # versus your defaults, because it gets multiplied by the -pe smp argument."
  echo "  --io-opts <opts|\"-tc 10\">                      # Options given to e.g. queue.pl for jobs that do a lot of I/O."
  echo "  --minibatch-size <minibatch-size|128>            # Size of minibatch to process (note: product with --num-threads"
  echo "                                                   # should not get too large, e.g. >2k)."
  echo "  --samples-per-iter <#samples|400000>             # Number of samples of data to process per iteration, per"
  echo "                                                   # process."
  echo "  --splice-width <width|4>                         # Number of frames on each side to append for feature input"
  echo "                                                   # (note: we splice processed, typically 40-dimensional frames"
  echo "  --lda-dim <dim|250>                              # Dimension to reduce spliced features to with LDA"
  echo "  --num-iters-final <#iters|10>                    # Number of final iterations to give to nnet-combine-fast to "
  echo "                                                   # interpolate parameters (the weights are learned with a validation set)"
  echo "  --num-utts-subset <#utts|300>                    # Number of utterances in subsets used for validation and diagnostics"
  echo "                                                   # (the validation subset is held out from training)"
  echo "  --num-frames-diagnostic <#frames|4000>           # Number of frames used in computing (train,valid) diagnostics"
  echo "  --num-valid-frames-combine <#frames|10000>       # Number of frames used in getting combination weights at the"
  echo "                                                   # very end."
  echo "  --stage <stage|-9>                               # Used to run a partially-completed training process from somewhere in"
  echo "                                                   # the middle."
  
  exit 1;
fi

num_leaves=$1   # Must be larger than usual since using two-level tree 
data=$2
lang=$3
alidir=$4
dir=$5

# Check some files.
for f in $data/feats.scp $lang/L.fst $alidir/ali.1.gz $alidir/final.mdl $alidir/tree; do
  [ ! -f $f ] && echo "$0: no such file $f" && exit 1;
done

num_groups=$[$num_leaves/$leaves_per_group]
ciphonelist=`cat $lang/phones/context_indep.csl` || exit 1;
nj=`cat $alidir/num_jobs` || exit 1;  # number of jobs in alignment dir...
mkdir -p $dir/log
echo $nj > $dir/num_jobs

sdata=$data/split$nj
split_data.sh $data $nj

splice_opts=`cat $alidir/splice_opts 2>/dev/null`
cp $alidir/splice_opts $dir 2>/dev/null

[ -z "$transform_dir" ] && transform_dir=$alidir
norm_vars=`cat $alidir/norm_vars 2>/dev/null` || norm_vars=false # cmn/cmvn option, default false.
cp $alidir/norm_vars $dir 2>/dev/null

## Set up features. 
if [ -f $alidir/final.mat ] && [ ! -f $transform_dir/raw_trans.1 ]; then feat_type=lda; else feat_type=raw; fi

echo "$0: feature type is $feat_type"

case $feat_type in
  raw) feats="ark,s,cs:cat $sdata/JOB/feats.scp | apply-cmvn --norm-vars=$norm_vars --utt2spk=ark:$sdata/JOB/utt2spk scp:$sdata/JOB/cmvn.scp scp:- ark:- |"
   ;;
  lda) 
    splice_opts=`cat $alidir/splice_opts 2>/dev/null`
    cp $alidir/splice_opts $dir 2>/dev/null
    cp $alidir/final.mat $dir    
    feats="ark,s,cs:cat $sdata/JOB/feats.scp | apply-cmvn --norm-vars=$norm_vars --utt2spk=ark:$sdata/JOB/utt2spk scp:$sdata/JOB/cmvn.scp scp:- ark:- | splice-feats $splice_opts ark:- ark:- | transform-feats $dir/final.mat ark:- ark:- |"
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

if [ $stage -le -7 ]; then
  echo "$0: accumulating tree stats"
  $cmd JOB=1:$nj $dir/log/acc_tree.JOB.log \
    acc-tree-stats $context_opts --ci-phones=$ciphonelist $alidir/final.mdl "$feats" \
    "ark:gunzip -c $alidir/ali.JOB.gz|" $dir/JOB.treeacc || exit 1;
  [ "`ls $dir/*.treeacc | wc -w`" -ne "$nj" ] && echo "$0: Wrong #tree-stats" && exit 1;
  sum-tree-stats $dir/treeacc $dir/*.treeacc 2>$dir/log/sum_tree_acc.log || exit 1;
  rm $dir/*.treeacc
fi

if [ $stage -le -6 ]; then
  echo "$0: Getting questions for tree clustering."
  # preparing questions, roots file...
  cluster-phones $context_opts $dir/treeacc $lang/phones/sets.int $dir/questions.int 2> $dir/log/questions.log || exit 1;
  cat $lang/phones/extra_questions.int >> $dir/questions.int
  compile-questions $context_opts $lang/topo $dir/questions.int $dir/questions.qst 2>$dir/log/compile_questions.log || exit 1;
  
  echo "$0: Building the tree"
  $cmd $dir/log/build_tree.log \
    build-tree-two-level $context_opts --binary=false --verbose=1 --max-leaves-first=$num_groups \
     --max-leaves-second=$num_leaves $dir/treeacc $lang/phones/roots.int \
     $dir/questions.qst $lang/topo $dir/tree $dir/pdf2group.map || exit 1;
fi

num_leaves=`tree-info $dir/tree 2>/dev/null | awk '{print $2}'` || exit 1;
[ -z $num_leaves ] && echo "\$num_leaves is unset" && exit 1
[ "$num_leaves" -eq "0" ] && echo "\$num_leaves is 0" && exit 1

if [ $stage -le -5 ]; then
  echo "$0: converting alignments" 
  gmm-init-model  --write-occs=$dir/1.occs  \
    $dir/tree $dir/treeacc $lang/topo $dir/temp.mdl 2> $dir/log/init_model.log || exit 1;
  $cmd JOB=1:$nj $dir/log/convert_ali.JOB.log \
    convert-ali $alidir/final.mdl $dir/temp.mdl $dir/tree "ark:gunzip -c $alidir/ali.JOB.gz|" \
    "ark:|gzip -c >$dir/ali.JOB.gz" || exit 1;
fi

if [ $stage -le -4 ]; then
  # LDA is computed using the older alignments
  echo "$0: calling get_lda.sh using alignments from $dir"
  steps/nnet2/get_lda.sh $lda_opts --splice-width $splice_width --cmd "$cmd" --transform-dir $transform_dir --model $dir/temp.mdl $data $lang $dir $dir || exit 1;
fi

# these files will have been written by get_lda.sh
feat_dim=`cat $dir/feat_dim` || exit 1;
lda_dim=`cat $dir/lda_dim` || exit 1;

if [ $stage -le -3 ] && [ -z "$egs_dir" ]; then
  echo "$0: calling get_egs.sh using alignments from $dir"
  spk_vecs_opt=
  [ ! -z $spk_vecs_dir ] && spk_vecs_opt="--spk-vecs-dir $spk_vecs_dir";
  steps/nnet2/get_egs.sh $spk_vecs_opt --samples-per-iter $samples_per_iter --num-jobs-nnet $num_jobs_nnet \
      --splice-width $splice_width --stage $get_egs_stage --cmd "$cmd" $egs_opts --io-opts "$io_opts" --transform-dir $transform_dir \
      --model $dir/temp.mdl \
      $data $lang $dir $dir || exit 1;
fi

[ -e $dir/temp.mdl ] && rm $dir/temp.mdl

echo $egs_dir
if [ -z $egs_dir ]; then
  egs_dir=$dir/egs
fi

echo $egs_dir
iters_per_epoch=`cat $egs_dir/iters_per_epoch`  || exit 1;
! [ $num_jobs_nnet -eq `cat $egs_dir/num_jobs_nnet` ] && \
  echo "$0: Warning: using --num-jobs-nnet=`cat $egs_dir/num_jobs_nnet` from $egs_dir"
num_jobs_nnet=`cat $egs_dir/num_jobs_nnet` || exit 1;


if ! [ $num_hidden_layers -ge 1 ]; then
  echo "Invalid num-hidden-layers $num_hidden_layers"
  exit 1
fi

if [ $stage -le -2 ]; then
  echo "$0: initializing neural net";

  # Get spk-vec dim (in case we're using them).
  if [ ! -z "$spk_vecs_dir" ]; then
    spk_vec_dim=$[$(copy-vector --print-args=false "ark:cat $spk_vecs_dir/vecs.1|" ark,t:- | head -n 1 | wc -w) - 3];
    ! [ $spk_vec_dim -gt 0 ] && echo "Error getting spk-vec dim" && exit 1;
    ext_lda_dim=$[$lda_dim + $spk_vec_dim]
    extend-transform-dim --new-dimension=$ext_lda_dim $dir/lda.mat $dir/lda_ext.mat || exit 1;
    lda_mat=$dir/lda_ext.mat
    ext_feat_dim=$[$feat_dim + $spk_vec_dim]
  else
    spk_vec_dim=0
    lda_mat=$dir/lda.mat
    ext_lda_dim=$lda_dim
    ext_feat_dim=$feat_dim
  fi

  stddev=`perl -e "print 1.0/sqrt($pnorm_input_dim);"`
  cat >$dir/nnet.config <<EOF
SpliceComponent input-dim=$ext_feat_dim left-context=$splice_width right-context=$splice_width const-component-dim=$spk_vec_dim
FixedAffineComponent matrix=$lda_mat
AffineComponentPreconditioned input-dim=$ext_lda_dim output-dim=$pnorm_input_dim alpha=$alpha max-change=$max_change learning-rate=$initial_learning_rate param-stddev=$stddev bias-stddev=$bias_stddev
PnormComponent input-dim=$pnorm_input_dim output-dim=$pnorm_output_dim p=$p
NormalizeComponent dim=$pnorm_output_dim
AffineComponentPreconditioned input-dim=$pnorm_output_dim output-dim=$num_leaves alpha=$alpha max-change=$max_change learning-rate=$initial_learning_rate param-stddev=0 bias-stddev=0
SoftmaxComponent dim=$num_leaves
EOF

  # to hidden.config it will write the part of the config corresponding to a
  # single hidden layer; we need this to add new layers. 
  cat >$dir/hidden.config <<EOF
AffineComponentPreconditioned input-dim=$pnorm_output_dim output-dim=$pnorm_input_dim alpha=$alpha max-change=$max_change learning-rate=$initial_learning_rate param-stddev=$stddev bias-stddev=$bias_stddev
PnormComponent input-dim=$pnorm_input_dim output-dim=$pnorm_output_dim p=$p
NormalizeComponent dim=$pnorm_output_dim
EOF

  $cmd $dir/log/nnet_init.log \
    nnet-am-init $dir/tree $lang/topo "nnet-init $dir/nnet.config -|" \
    $dir/0.mdl || exit 1;
fi

if [ $stage -le -1 ]; then
  echo "Training transition probabilities and setting priors"
  $cmd $dir/log/train_trans.log \
    nnet-train-transitions $dir/0.mdl "ark:gunzip -c $dir/ali.*.gz|" $dir/0.mdl \
    || exit 1;
fi

num_iters_reduce=$[$num_epochs * $iters_per_epoch];
num_iters_extra=$[$num_epochs_extra * $iters_per_epoch];
num_iters=$[$num_iters_reduce+$num_iters_extra]

echo "$0: Will train for $num_epochs + $num_epochs_extra epochs, equalling "
echo "$0: $num_iters_reduce + $num_iters_extra = $num_iters iterations, "
echo "$0: (while reducing learning rate) + (with constant learning rate)."

# This is when we decide to mix up from: halfway between when we've finished
# adding the hidden layers and the end of training.
finish_add_layers_iter=$[$num_hidden_layers * $add_layers_period]

if [ $num_threads -eq 1 ]; then
  train_suffix="-simple" # this enables us to use GPU code if
                         # we have just one thread.
else
  train_suffix="-parallel --num-threads=$num_threads"
fi

x=0

while [ $x -lt $num_iters ]; do
  if [ $x -ge 0 ] && [ $stage -le $x ]; then
    # Set off jobs doing some diagnostics, in the background.
    $cmd $dir/log/compute_prob_valid.$x.log \
      nnet-compute-prob $dir/$x.mdl ark:$egs_dir/valid_diagnostic.egs &
    $cmd $dir/log/compute_prob_train.$x.log \
      nnet-compute-prob $dir/$x.mdl ark:$egs_dir/train_diagnostic.egs &
    if [ $x -gt 0 ]; then
      $cmd $dir/log/progress.$x.log \
        nnet-show-progress --use-gpu=no $dir/$[$x-1].mdl $dir/$x.mdl ark:$egs_dir/train_diagnostic.egs &
    fi
    
    echo "Training neural net (pass $x)"
    if [ $x -gt 0 ] && \
      [ $x -le $[($num_hidden_layers-1)*$add_layers_period] ] && \
      [ $[($x-1) % $add_layers_period] -eq 0 ]; then
      mdl="nnet-init --srand=$x $dir/hidden.config - | nnet-insert $dir/$x.mdl - - |"
    else
      mdl=$dir/$x.mdl
    fi


    $cmd $parallel_opts JOB=1:$num_jobs_nnet $dir/log/train.$x.JOB.log \
      nnet-shuffle-egs --buffer-size=$shuffle_buffer_size --srand=$x \
      ark:$egs_dir/egs.JOB.$[$x%$iters_per_epoch].ark ark:- \| \
      nnet-train$train_suffix \
         --minibatch-size=$minibatch_size --srand=$x "$mdl" \
        ark:- $dir/$[$x+1].JOB.mdl \
      || exit 1;

    nnets_list=
    for n in `seq 1 $num_jobs_nnet`; do
      nnets_list="$nnets_list $dir/$[$x+1].$n.mdl"
    done

    learning_rate=`perl -e '($x,$n,$i,$f)=@ARGV; print ($x >= $n ? $f : $i*exp($x*log($f/$i)/$n));' $[$x+1] $num_iters_reduce $initial_learning_rate $final_learning_rate`;
    softmax_learning_rate=`perl -e "print $learning_rate * $softmax_learning_rate_factor;"`;
    nnet-am-info $dir/$[$x+1].1.mdl > $dir/foo  2>/dev/null || exit 1
    nu=`cat $dir/foo | grep num-updatable-components | awk '{print $2}'`
    na=`cat $dir/foo | grep -v Fixed | grep AffineComponent | wc -l` 
    # na is number of last updatable AffineComponent layer [one-based, counting only
    # updatable components.]
    lr_string="$learning_rate"
    for n in `seq 2 $nu`; do 
      if [ $n -eq $na ] || [ $n -eq $[$na-1] ]; then lr=$softmax_learning_rate;
      else lr=$learning_rate; fi
      lr_string="$lr_string:$lr"
    done
    
    $cmd $dir/log/average.$x.log \
      nnet-am-average $nnets_list - \| \
      nnet-am-copy --learning-rates=$lr_string - $dir/$[$x+1].mdl || exit 1;
    
    #if echo $limit_rank_iters | grep -w $x >/dev/null && [ $stage -le $x ] && [ $x -le $[$num_iters-$num_iters_final] ]; then
    if echo $limit_rank_iters | grep -w $x >/dev/null && [ $stage -le $x ]; then
      echo Limiting rank of last affine layer
      $cmd $dir/log/limit_rank.log \
        nnet-am-limit-rank-final --pdf-map=$dir/pdf2group.map \
        --sv-proportion=$sv_proportion \
        $dir/$[$x+1].mdl $dir/$[$x+1].mdl
    fi

    rm $nnets_list
  fi
  x=$[$x+1]
done

# Now do combination.
# At the end, final.mdl will be a combination of the last e.g. 10 models.
nnets_list=()
if [ $num_iters_final -gt $num_iters_extra ]; then
  echo "Setting num_iters_final=$num_iters_extra"
fi
start=$[$num_iters-$num_iters_final+1]
for x in `seq $start $num_iters`; do
  idx=$[$x-$start]
  nnets_list[$idx]=$dir/$x.mdl # "nnet-am-copy --remove-dropout=true $dir/$x.mdl - |"
done

if [ $stage -le $num_iters ]; then
  # Below, use --use-gpu=no to disable nnet-combine-fast from using a GPU, as
  # if there are many models it can give out-of-memory error; set num-threads to 8
  # to speed it up (this isn't ideal...)
  this_num_threads=$num_threads
  [ $this_num_threads -lt 8 ] && this_num_threads=8
  num_egs=`nnet-copy-egs ark:$egs_dir/combine.egs ark:/dev/null 2>&1 | tail -n 1 | awk '{print $NF}'`
  mb=$[($num_egs+$this_num_threads-1)/$this_num_threads]
  [ $mb -gt 512 ] && mb=512
  # Setting --initial-model to a large value makes it initialize the combination
  # with the average of all the models.  It's important not to start with a
  # single model, or, due to the invariance to scaling that these nonlinearities
  # give us, we get zero diagonal entries in the fisher matrix that
  # nnet-combine-fast uses for scaling, which after flooring and inversion, has
  # the effect that the initial model chosen gets much higher learning rates
  # than the others.  This prevents the optimization from working well.
  $cmd $parallel_opts $dir/log/combine.log \
    nnet-combine-fast --initial-model=100000 --num-lbfgs-iters=40 --use-gpu=no \
      --num-threads=$this_num_threads --regularizer=$combine_regularizer \
      --verbose=3 --minibatch-size=$mb "${nnets_list[@]}" ark:$egs_dir/combine.egs \
      $dir/final.mdl || exit 1;

  # Normalize stddev for affine or block affine layers that are followed by a
  # pnorm layer and then a normalize layer.
  $cmd $parallel_opts $dir/log/normalize.log \
    nnet-normalize-stddev $dir/final.mdl $dir/final_normalized.mdl || exit 1
  cp $dir/final_normalized.mdl $dir/final.mdl || exit 1 
fi

if [ -z "$limit_rank_iters" ] && [ $stage -le $[$num_iters+1] ]; then
  # Limit rank of last affine layer
  $cmd $dir/log/limit_rank.log \
    nnet-am-limit-rank-final --pdf-map=$dir/pdf2group.map \
    --sv-proportion=$sv_proportion \
    $dir/final.mdl $dir/final.mdl
fi

# Compute the probability of the final, combined model with
# the same subset we used for the previous compute_probs, as the
# different subsets will lead to different probs.
if [ $stage -le $[$num_iters+2] ]; then
  $cmd $dir/log/compute_prob_valid.final.log \
    nnet-compute-prob $dir/final.mdl ark:$egs_dir/valid_diagnostic.egs &
  $cmd $dir/log/compute_prob_train.final.log \
    nnet-compute-prob $dir/final.mdl ark:$egs_dir/train_diagnostic.egs &
fi

if [ $stage -le $[$num_iters+3] ]; then
  $cmd $dir/log/set_prior.log \
    nnet-compute-from-egs "nnet-to-raw-nnet $dir/final.mdl - |" \
    ark:$egs_dir/combine.egs ark:- \| \
    prob-to-post ark:- ark:- \| post-to-counts ark:- - \| \
    nnet-am-set-priors $dir/final.mdl - $dir/final.mdl || exit 1
fi

sleep 2

echo Done

if $cleanup; then
  echo Cleaning up data
  if [ $egs_dir == "$dir/egs" ]; then
    echo Removing training examples
    rm $dir/egs/egs*
  fi
  echo Removing most of the models
  for x in `seq 0 $num_iters`; do
    if [ $[$x%10] -ne 0 ] && [ $x -lt $[$num_iters-$num_iters_final+1] ]; then 
       # delete all but every 10th model; don't delete the ones which combine to form the final model.
      rm $dir/$x.mdl
    fi
  done
fi
