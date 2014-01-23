#!/usr/bin/python
# Author: Vimal Manohar
#
# This file takes an augmented CTM file that includes artificially added
# fillers and creates a segments file and text file.
# It uses the original segments file as reference and adds new segments
# wherever there is an inserted filler.

import argparse, sys
from argparse import ArgumentParser

def main():
  parser = ArgumentParser(description='Convert a CTM file to text file ande segments file')
  parser.add_argument('--get-whole-transcripts', \
      dest='get_whole_transcripts', default='false', \
      choices=['true', 'false'], \
      help='If true, then do not remove empty transcripts (default: $(default)s)')
  parser.add_argument('ctm_file', \
      help='CTM file typically after adding additional fillers')
  parser.add_argument('segments_file', \
      help='The segments file corresponding to which we need the text file')
  parser.add_argument('out_segments_file', help='Output segments file')
  parser.usage=':'.join(parser.format_usage().split(':')[1:]) + 'e.g. :  %(prog)s exp/tri4b_augment_train/ctm_per_reco data/train/segments.orig data/train/segments > data/train/text'
  options = parser.parse_args()

  if not (options.get_whole_transcripts == "true" or
      options.get_whole_transcripts == "True" or
      options.get_whole_transcripts == "false" or
      options.get_whole_transcripts == "False"):
    sys.stderr.write("%s: ERROR: Invalid option %s for --get-whole-transcripts. Must be (true|false)\n" % (sys.argv[0], options.get_whole_transcripts))
    sys.exit(1)

  get_whole_transcripts = False
  if (options.get_whole_transcripts == "true" or
      options.get_whole_transcripts == "True"):
    get_whole_transcripts = True

  try:
    out_segments_file = open(options.out_segments_file, 'w')
  except IOError:
    sys.stderr.write("%s: ERROR: Unable to open file %s\n" % (sys.argv[0], options.out_segments_file))
    sys.exit(1)

  try:
    ctm_file_handle = open(options.ctm_file)
  except IOError:
    sys.stderr.write("%s: ERROR: Unable to open file %s\n" % (sys.argv[0], options.ctm_file))
    sys.exit(1)

  try:
    segments_file_handle = open(options.segments_file)
  except IOError:
    sys.stderr.write("%s: ERROR: Unable to open file %s\n" % (sys.argv[0], options.segments_file))
    sys.exit(1)

  ctm_lines = []
  for line in ctm_file_handle.readlines():
    file_id, start, t, w = line.strip().split()
    ctm_lines.append([file_id, (float(start)), (float(t) + float(start)), w])

  segments_lines = []
  for line in segments_file_handle.readlines():
    utt_id, file_id, start, end = line.strip().split()
    segments_lines.append([file_id, (float(start)), (float(end)), utt_id])

  # Sort first on the start times and then sort on the file_id.
  # So that all the ctm words corresponding to a particular
  # file_id are together.
  ctm_lines.sort(key=lambda x:x[1])
  ctm_lines.sort(key=lambda x:x[0])

  # Sort first on the start times and then sort on the file_id.
  # So that all the segments corresponding to a particular
  # file_id are together.
  segments_lines.sort(key=lambda x:x[1])
  segments_lines.sort(key=lambda x:x[0])

  ctm_ptr = 0

  for seg_ptr,line in enumerate(segments_lines):
    file_id, seg_st, seg_end, utt_id = line
    utt_id = "%s-%06d-%06d" % (file_id, seg_st*100, seg_end*100);

    # Browse the segments file to the location where the
    # start of the ctm word i.e. ctm_lines[1] is within the
    # segments
    if ctm_ptr >= len(ctm_lines) or (ctm_lines[ctm_ptr][0] == file_id and seg_end <= ctm_lines[ctm_ptr][1]):
      # No word in CTM file. So print empty transcription,
      # which can be removed easily later
      if get_whole_transcripts:
        print("%s" % utt_id)
        out_segments_file.write("%s-%06d-%06d %s %.3f %.3f\n" % (file_id, seg_st*100, seg_end*100, file_id, seg_st, seg_end))
      continue

    # If the CTM word occurs after the segments. Then there is no more CTM words for that segment. So continue to the next segment.
    if ctm_ptr >= len(ctm_lines) or (ctm_lines[ctm_ptr][0] == file_id and seg_st < ctm_lines[ctm_ptr][1] and seg_end <= ctm_lines[ctm_ptr][2]):
      # No word in CTM file. So print empty transcription,
      # which can be removed easily later
      if get_whole_transcripts:
        print("%s" % utt_id)
        out_segments_file.write("%s-%06d-%06d %s %.3f %.3f\n" % (file_id, seg_st*100, seg_end*100, file_id, seg_st, seg_end))
      continue

    # Browse the ctm ptr to the location where the file_id matches
    # and the start of the ctm word (ctm_lines[ctm_ptr][1]) is within the segment
    text = []
    while ctm_ptr < len(ctm_lines) and (((ctm_lines[ctm_ptr][0] < file_id)
        or (ctm_lines[ctm_ptr][0] == file_id
          and ctm_lines[ctm_ptr][1] <= seg_end))):
      if ctm_lines[ctm_ptr][1] - seg_st < -0.01:
        # Inserted filler outside the segments. So add a new segment
        # that covers just the interval of the hypothesis +- 0.3s
        # on either side if it does not extend beyond the
        # adjacent segment
        st = max(ctm_lines[ctm_ptr][1]-0.3, segments_lines[seg_ptr-1][2])
        end = min(ctm_lines[ctm_ptr][2]+0.3, segments_lines[seg_ptr][1])
        utt = "%s-%06d-%06d" % (file_id, st*100, end*100);

        # Write new segment to the segments file
        out_segments_file.write("%s %s %.3f %.3f\n" % (utt, file_id, st, end))

        # Write the inserted filler to the text file
        sys.stdout.write("%s %s\n" % (utt, ctm_lines[ctm_ptr][-1]))
      else:
        # Append the word to the text
        text.append(ctm_lines[ctm_ptr][-1])
      ctm_ptr += 1

    # Write transcription of the utterance to the text file
    if len(text) == 0 and get_whole_transcripts:
      print("%s" % utt_id)
      out_segments_file.write("%s-%06d-%06d %s %.3f %.3f\n" % (file_id, seg_st*100, seg_end*100, file_id, seg_st, seg_end))
    elif len(text) > 0:
      print("%s %s" % (utt_id, ' '.join(text)))
      out_segments_file.write("%s-%06d-%06d %s %.3f %.3f\n" % (file_id, seg_st*100, seg_end*100, file_id, seg_st, seg_end))

if __name__ == '__main__':
  main()
