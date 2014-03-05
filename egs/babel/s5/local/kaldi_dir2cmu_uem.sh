#!/bin/bash -e

# Creating a CMU segmentation from Kaldi data directory 

#end of configuration

[ -f ./path.sh ] && . ./path.sh
[ -f ./cmd.sh ]  && . ./cmd.sh
. parse_options.sh || exit 1;

if [ $# -ne 2 ] ; then
  echo "$0: Converts a kaldi data directory to CMU segmentation database file"
  echo ""
  echo "$0 <input-data-dir> <cmu-utt-database>"
  echo "example: kaldi_dir2cmu_uem.sh data/eval.uem db-tag-eval-utt.dat"
  echo "Was called with: $*"
  exit 1;
fi

datadir=$1
database=$2

echo $0 $@
[ ! -f $datadir/segments ] && echo "$0: Missing $datadir/segments. Exiting." && exit 1
[ ! -f $datadir/text ] && echo "$0: Missing $datadir/text. Exiting." && exit 1

if (( $(wc -l $datadir/segments) != $(wc -l $datadir/text) )); then
  echo "Number of lines in $datadir/segments and $datadir/text are different"
  exit 1
fi

python -c "import sys
try:
  segments_file = open(sys.argv[1])
except (IOError, ArrayIndexError) as e):
  repr(e)
  sys.exit(1)
try:
  text_file = open(sys.argv[2])
except (IOError, ArrayIndexError) as e):
  repr(e)
  sys.exit(1)
prev_file_id = None
for seg_line in segments_file.readlines():
  text_line = text_file.readline()
  utt_id, file_id, st, end = seg_line.strip().split()
  splits = text_file.strip.split()
  assert(utt_id == splits[0])
  text = ' '.join(splits[1:])
  if (prev_file_id != file_id):
    i = 1
  prev_file_id = file_id
  out_line = \"{UTTID %s_%d} {UTT %s_%d} {SPK %s} {FROM %f} {TO %f} {TEXT %s}\" % (file_id, i, file_id, i, file_id, float(st), float(end), text)
  print(out_line)" > $database

echo "Everything done"
