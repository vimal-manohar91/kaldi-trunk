set -o pipefail
set -e

. lang.conf
. path.sh
. cmd.sh

. parse_options.sh

version=$1
dest=$2

[ -z $version ] && exit 1
[ -z $dest ] && exit 1

prefix=`echo $train_data_list | sed 's/.*\([0-9][0-9][0-9]\).*/\1/g'`
[ ! -z $prefix ]

mkdir -p $dest

if [ -f data/dev10h.seg/.done ]; then
  if [ ! -s $dest/db-$prefix-dev-$version-utt.dat ]; then
    local/kaldi_dir2uem.py --prefix $prefix-dev-$version data/dev10h.seg $dest/
  fi
fi

if [ -f data/shadow.seg/.done ]; then
  if [ ! -s $dest/db-$prefix-shadow-$version-utt.dat ]; then
    local/kaldi_dir2uem.py --prefix $prefix-shadow-$version data/shadow.seg $dest/
  fi
fi

if [ -f data/eval.seg/.done ]; then
  if [ ! -s $dest/db-$prefix-eval-$version-utt.dat ]; then
    local/kaldi_dir2uem.py --prefix $prefix-dev-$version data/eval.seg $dest/
  fi
fi

if [ -f data/unsup.seg/.done ]; then
  if [ ! -s $dest/db-$prefix-unsup-$version-utt.dat ]; then
    local/kaldi_dir2uem.py --prefix $prefix-unsup-$version data/unsup.seg $dest/
  fi
fi
