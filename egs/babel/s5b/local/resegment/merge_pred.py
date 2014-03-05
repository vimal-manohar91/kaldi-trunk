#! /usr/bin/python

import argparse, sys, textwrap
from argparse import ArgumentParser

def main():
  parser = ArgumentParser(description=textwrap.dedent('''\
      Merge predictions of the utterances of a single recording
      into a single prediction.

      The program reads an input segments file in Kaldi format
      to get the reference times for each utterance. It then
      reads the predictions stored in a <temp_prediction_dir>
      that has the prediction for each utterance. The output
      prediction for entire recording is obtained by concatenating
      the predictions for each utterance corresponding to the
      recording and the final prediction is output to the
      <prediction_dir>.

      The final prediction file has the format:
      <reco_id> <prediction>.
      The <prediction> is an array of "0" and "1" separated by
      spaces where "0" stands for non-speech and "1" for speech.'''), \
          formatter_class=argparse.RawDescriptionHelpFormatter)
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

  # Open segments file for reading
  try:
    segments_file_handle = open(options.segments_file)
  except IOError as e:
    sys.stderr.write("%s: ERROR: Unable to open file %s\n%s\n" % \
        (sys.argv[0], options.segments_file, e))
    sys.exit(1)

  # Initializations
  reco_id = None
  prev_reco_id = None
  pred = []
  i = 0

  for line in segments_file_handle.readlines():
    # Read segments file
    splits = line.split()

    if len(splits) != 4:
      sys.stderr.write(textwrap.dedent("""\
          %s: ERROR: %s has only %d splits.
          The required format of file is
          <utterance_id> <recording_id> <start_time> <end_time>"""))
      sys.exit(1)

    reco_id = splits[1]

    if prev_reco_id != None and reco_id != prev_reco_id:
      # Done processing the previous recording. Write the predictions for
      # prediction for that recording id and initialize the next one.

      # Open prediction file for writing
      try:
        out_handle = open("%s/%s.pred" % \
          (options.prediction_dir, prev_reco_id), 'w')
      except IOError as e:
        sys.stderr.write("%s: %s: Unable to open %s for writing\n" % \
            (sys.argv[0], e, \
            "%s/%s.pred" % (options.prediction_dir, prev_reco_id)))
        sys.exit(1)

      out_handle.write(' '.join(pred) + "\n")
      out_handle.close()

      pred = []
      i = 0
    # End if

    # Open a temporary prediction file for reading
    try:
      pred_handle = open("%s/%s.pred" % \
          (options.temp_prediction_dir, splits[0]))
    except IOError as e:
      sys.stderr.write("%s: %s: Unable to open file %s\n" % (sys.argv[0], \
          e, "%s/%s.pred" % (options.temp_prediction_dir, splits[0])))
      sys.exit(1)
    # End try catch

    start = int(float(splits[2]) / options.frame_shift)
    end = int(float(splits[3]) / options.frame_shift)

    if end - i >= 0:
      pred.extend(["SIL"] * (end - i))
    else:
      sys.stderr.write("%s: ERROR: The end frame %d is less than the \
          the current frame pointer %d\n" % (sys.argv[0], end, i))
    # End if

    i = end

    try:
      pred[start:end] = pred_handle.readline().strip().split()[1:]
    except (ValueError, IOError, IndexError) as e:
      sys.stderr.write("%s: %s: Incorrect format of file for reco_id %s\n" % \
          (sys.argv[0], e, reco_id))
      sys.exit(1)
    pred_handle.close()

    prev_reco_id = reco_id
  # End for loop over segments file

  assert (prev_reco_id != None)

  # Open prediction file for writing
  try:
    out_handle = open("%s/%s.pred" % \
      (options.prediction_dir, prev_reco_id), 'w')
  except IOError as e:
    sys.stderr.write("%s: %s: Unable to open %s for writing\n" % \
        (sys.argv[0], e, \
        "%s/%s.pred" % (options.prediction_dir, prev_reco_id)))
    sys.exit(1)

  out_handle.write(' '.join(pred) + "\n")
  out_handle.close()
# End function main()

if __name__ == '__main__':
  main()

