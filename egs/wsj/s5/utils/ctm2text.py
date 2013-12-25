#!/usr/bin/python

import argparse, sys
from argparse import ArgumentParser

def main():
  parser = ArgumentParser(description='Convert a CTM file to text file corresponding to particular segments')
  parser.add_argument('ctm_file', help='CTM file typically after adding additional fillers')
  parser.add_argument('segments_file', help='The segments file corresponding to which we need the text file')
  parser.add_argument('--get-whole-transcripts', dest='get_whole_transcripts', \
      default='false', \
      help='If true then do not remove empty transcripts')

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
  seg_ptr = 0

  for line in segments_lines:
    file_id, seg_st, seg_end, utt_id = line

    # Browse the segments file to the location where the
    # start of the ctm word i.e. ctm_lines[1] is within the
    # segments
    if ctm_ptr >= len(ctm_lines) or (ctm_lines[ctm_ptr][0] == file_id and seg_end <= ctm_lines[ctm_ptr][1]):
      # No word in CTM file. So print empty transcription,
      # which can be removed easily later
      if get_whole_transcripts:
        print("%s" % utt_id)
      continue

    if ctm_ptr >= len(ctm_lines) or (ctm_lines[ctm_ptr][0] == file_id and seg_st < ctm_lines[ctm_ptr][1] and seg_end <= ctm_lines[ctm_ptr][2]):
      # No word in CTM file. So print empty transcription,
      # which can be removed easily later
      if get_whole_transcripts:
        print("%s" % utt_id)
      continue

    # Browse the ctm ptr to the location where the file_id matches
    # and the start of the ctm word (ctm_lines[ctm_ptr][1]) is within the segment
    # segment
    text = []
    while ctm_ptr < len(ctm_lines) and (((ctm_lines[ctm_ptr][0] < file_id)
        or (ctm_lines[ctm_ptr][0] == file_id
          and ctm_lines[ctm_ptr][1] <= seg_end))):
      # Append the word to the text
      text.append(ctm_lines[ctm_ptr][-1])
      ctm_ptr += 1

    if len(text) == 0 and get_whole_transcripts:
      print("%s" % utt_id)
    elif len(text) > 0:
      print("%s %s" % (utt_id, ' '.join(text)))

if __name__ == '__main__':
  main()
