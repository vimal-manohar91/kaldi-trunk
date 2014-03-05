set -u
set -o pipefail

padding=0.15
min_inter_utt_silence_length=0.75
max_segment_length=20
segments_only=false

[ -f ./path.sh ] && . ./path.sh
[ -f ./cmd.sh ]  && . ./cmd.sh
. parse_options.sh || exit 1;

if [ $# -ne 3 ] ; then
  echo "$0: Converts the a base kaldi dir and VAD directory to new kaldi dir"
  echo "Usage:"
  echo "$0 <in-data-dir> <vad-dir> <out-data-dir>"
  echo "    --padding       Pad the VAD segments on either sides by this number of seconds."
  echo "example: $0 data/dev10h.uem vad_dir data/dev10h.uem.filtered"
  echo "Was called with: $*"
  exit 1;
fi

data_in=$1
vad_dir=$2
data_out=$3

mkdir -p $data_out
ls $vad_dir/*.vad | python -c 'import sys
for line in sys.stdin.readlines():
  try:
    file_id = line.strip().split("/")[-1][:-4]
  except IndexError as e:
    repr(e)
    sys.exit(1)

  try:
    file_handle = open(line.strip())
  except IOError as e:
    sys.stderr.write("%s: Unable to open %s\n" % (e, line.strip()))
    sys.exit(1)

  segments = []
  for l in file_handle.readlines():
    if len(l.strip()) == 0:
      continue
    splits = l.strip().split()
    start, end = (float(splits[0])/100.0, float(splits[1])/100.0)
    if segments != [] and start - segments[-1][2] < '$min_inter_utt_silence_length' and end - segments[-1][1] < '$max_segment_length':
      segments[-1] = (segments[-1][0], segments[-1][1], end)
    else:
      segments.append((file_id, start, end))
  max_end_time = end
  i = 0
  for x in segments:
    i += 1
    start = x[1] - '$padding'
    end = x[2] + '$padding'

    if start < 0:
      start = 0
    if end > max_end_time:
      end = max_end_time
    print("%s-%04d %s %.2f %.2f" % (x[0], i, x[0], start, end))' | \
      sort > $data_out/segments || exit 1

if ! $segments_only; then
  for f in wav.scp reco2file_and_channel; do 
    [ -f $data_in/$f ] && cp $data_in/$f $data_out
  done

  cat $data_out/segments | cut -d ' ' -f 1,2 > $data_out/utt2spk || exit 1
  utils/utt2spk_to_spk2utt.pl $data_out/utt2spk > $data_out/spk2utt || exit 1
fi
