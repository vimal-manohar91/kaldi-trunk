set -e           #Exit on non-zero return code from any command
set -o pipefail  #Exit if any of the commands in the pipeline will 
                 #return non-zero return code

[ ! -f ./lang.conf ] && echo "Language configuration does not exist! Use the configurations in conf/lang/* as a startup" && exit 1
[ ! -f ./conf/common_vars.sh ] && echo "the file conf/common_vars.sh does not exist!" && exit 1

. conf/common_vars.sh || exit 1;
. ./lang.conf || exit 1;

nj=10
cmd=run.pl

[ -f local.conf ] && . ./local.conf

echo "$0 $@"  # Print the command line for logging

[ -f path.sh ] && . ./path.sh # source the path.
. parse_options.sh || exit 1;

if [ $# != 4 ]; then
   echo "usage: steps/force_align_sgmm2.sh <data-dir> <lang-dir> <transform-dir> <model-dir>"
   echo "e.g.:  steps/force_align_sgmm2.sh data/dev10h data/lang exp/tri5 exp/sgmm5_mmi_b0.1"
   echo "main options (for others, see top of script file)"
   echo "  --nj <nj>                                        # number of parallel jobs"
   echo "  --cmd (utils/run.pl|utils/queue.pl <queue opts>) # how to run jobs."
   exit 1;
fi

data=$1
lang=$2
transform_dir=$3
model_dir=$4

d=${data##*/}

[ -d $lang ] || exit 1
[ -d $data ] || exit 1
[ -f $transform_dir/final.mdl ] || exit 1
[ -f $model_dir/final.mdl ] || exit 1

if [ ! -f $transform_dir/align_${d}/.done ]; then 
  mkdir -p $transform_dir/align_${d}
  steps/align_fmllr.sh \
    --boost-silence $boost_sil --nj $nj --cmd "$cmd" \
    $data $lang $transform_dir $transform_dir/align_${d}
  touch $transform_dir/align_${d}/.done
fi

if [ ! -f $model_dir/align_fmllr_${d}/.done ]; then 
  mkdir -p $model_dir/align_fmllr_${d}
  steps/align_sgmm2.sh --nj $nj --cmd "$cmd" \
    --transform-dir $transform_dir/align_${d} \
    $data $lang $model_dir $model_dir/align_fmllr_${d}
  touch $model_dir/align_fmllr_${d}/.done
fi


