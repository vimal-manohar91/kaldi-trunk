data=data/train
denlats_dir=exp/sgmm5_denlats
threshold=15

[ -f ./path.sh ] && . ./path.sh
. parse_options.sh || exit 1;

set -e           #Exit on non-zero return code from any command
set -o pipefail  #Exit if any of the commands in the pipeline will 

mkdir -p ${data}_filtered

cp -rT ${data} ${data}_filtered 
rm -r ${data}_filtered/split*
for f in text utt2spk spk2utt feats.scp cmvn.scp segments; do rm data/${data}_filtered/$f; done

nj=`cat $denlats_dir/num_jobs`
$cmd JOB=1:$nj ${data}_filtered/log/cleanup.JOB.log \
  gunzip -c $denlats_dir/lat.JOB.gz \
  \| lattice-oracle ark:- "ark:utils/sym2int.pl -f 2- data/lang/words.txt data/train/text|" \
  ark:/dev/null 3\>&1 2\>&3 1\>&2 \
  \| awk '/Lattice/{utt_id=$2} /WER/{if ($4 > '$threshold') print utt_id}' \
  \| awk -F'_' '{print $0" "$1"_"$2}' '>' ${data}_filtered/log/utt2spk.JOB

cat ${data}_filtered/log/utt2spk.* | sort > ${data}_filtered/utt2spk
utils/fix_data_dir.sh ${data}_filtered || exit 1
