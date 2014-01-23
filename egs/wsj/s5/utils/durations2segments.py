#! /usr/bin/python

import argparse, sys
from argparse import ArgumentParser

def main():
  parser = ArgumentParser(description='Convert durations file into segments by dividing the entire file into segments of around 1min each')
  parser.add_argument('--verbose', type=int, \
      dest='verbose', default=0, \
      help='Give higher verbose for more logging (default: %(default)s)')
  parser.add_argument('--segment-length', type=float, default=60.0, \
      help="Size of each segment in seconds (default: %(default)s)")
  parser.add_argument('--first-separator', type=str, \
      dest='first_separator', default="-", \
      help="Separator between recording-id and segment-index (default: %(default)s)")
  parser.add_argument('--second-separator', type=str, \
      dest='second_separator', default="-", \
      help="Separator between segment-index and num-segments (default: %(default)s)")
  parser.add_argument('--third-separator', type=str, \
      dest='third_separator', default="-", \
      help="Separator between segment-index and num-segments (default: %(default)s)")
  parser.add_argument('durations_scp_file', \
      help='Durations SCP file')
  parser.usage=':'.join(parser.format_usage().split(':')[1:]) \
      + 'e.g. :  %(prog)s data/dev10h.seg.orig/durations.scp > data/dev10h.seg.orig/segments'
  options = parser.parse_args()

  try:
    durations_file_handle = open(options.durations_scp_file)
  except IOError as e:
    sys.stderr.write("%s: ERROR: Unable to open file %s\n%s\n" % (sys.argv[0], options.durations_scp_file, e.errstr))
    sys.exit(1)

  durations = {}
  for line in durations_file_handle.readlines():
    splits = line.strip().split()
    durations[splits[0]] = float(splits[1])

  max_end_time = max([x[1] for x in durations.items()]) * 100.0
  # we'll be printing the times out in hundredths of a second (regardless of the
  # value of frame shift), and first need to know how many digits we need
  # we'll be printing with "%05d" or similar, for zero-padding
  num_digits = 1
  i = 1

  while i < max_end_time:
    i *= 10
    num_digits += 1
  format_str = r"%0" + "%d" % num_digits + "d" # e.g. "%05d"

  for reco_id, duration in durations.items():
    start = 0.0
    while start < duration:
      end = min(start + options.segment_length, duration)
      if duration - start < 1.5*options.segment_length:
        end = duration
      start_str = format_str % (start * 100.0)
      end_str = format_str % (end * 100.0 + 1)
      total_str = format_str % ((duration) * 100.0)
      utt_id = "%s%s%s%s%s%s%s" % (reco_id, options.first_separator, start_str, options.second_separator, end_str, options.third_separator, total_str)
      if end != duration:
        sys.stdout.write("%s %s %.2f %.2f\n" % (utt_id, reco_id, start, end+0.01))
      else:
        sys.stdout.write("%s %s %.2f -1\n" % (utt_id, reco_id, start))
      start = end

if __name__ == '__main__':
  main()
