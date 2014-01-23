#! /usr/bin/python

import argparse, sys
from argparse import ArgumentParser

def main():
  parser = ArgumentParser(description='Merge prediction of posterior decode')
  parser.add_argument('--verbose', type=int, dest='verbose', default=0, \
      help='Give higher verbose for more logging (default: %(default)s)')
  parser.add_argument('--frame-shift', type=float, default=0.01, \
      help='Frame shift in seconds (default: %(default)s)')
  parser.add_argument('segments_file', \
      help='Segments file')
  parser.add_argument('temp_prediction_dir', \
      help='Directory where the predicted phones (.pred files) corresponding to the orig utt_ids are found')
  parser.add_argument('prediction_dir', \
      help='Directory where the predicted phones (.pred files) corresponding to the reco_id are to be output')
  parser.usage=':'.join(parser.format_usage().split(':')[1:]) \
      + 'e.g. :  %(prog)s data/dev10h.seg.orig/segments exp/tri4b_whole_resegment/pred_temp exp/tri4b_whole_resegment/pred'
  options = parser.parse_args()

  try:
    segments_file_handle = open(options.segments_file)
  except IOError as e:
    sys.stderr.write("%s: ERROR: Unable to open file %s\n%s\n" % (sys.argv[0], options.segments_file, e.errstr))
    sys.exit(1)

  reco_id = None
  prev_reco_id = None
  pred = []
  i = 0
  for line in segments_file_handle.readlines():
    i += 1
    splits = line.split()
    reco_id = splits[1]

    if prev_reco_id != None and reco_id != prev_reco_id:
      out_handle = open("%s/%s.pred" % (options.prediction_dir, prev_reco_id), 'w')
      out_handle.write(' '.join(pred) + "\n")
      out_handle.close()
      pred = []
    # End if

    try:
      pred_handle = open("%s/%s.pred" % (options.temp_prediction_dir, splits[0]))
    except IOError as e:
      sys.stderr.write("%s: ERROR: Unable to open file %s\n%s\n" % (sys.argv[0], "%s/%s.pred" % (options.temp_prediction_dir, splits[0]), e.errstr))
      sys.exit(1)
    # End try catch

    start = int(float(splits[2]) / options.frame_shift)
    pred.extend(["SIL"] * (start - len(pred)))
    assert(start == len(pred))
    pred.extend(pred_handle.readline().strip().split())
    pred_handle.close()

    prev_reco_id = reco_id
  # End for loop over segments file
  assert prev_reco_id != None
  out_handle = open("%s/%s.pred" % (options.prediction_dir, prev_reco_id), 'w')
  out_handle.write(' '.join(pred) + "\n")
  out_handle.close()

if __name__ == '__main__':
  main()

