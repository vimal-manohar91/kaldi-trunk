#!/usr/bin/python
# Author: Vimal Manohar

import argparse, sys, os, re, textwrap
from argparse import ArgumentParser

def main():
  parser = ArgumentParser(description=textwrap.dedent('''\
      Filter a CTM file using a segments file.

      This is typically used to post-filter the decode output in the
      form of CTM file using a different segments file from the one
      that is used during decode. The different segment could be from
      a VAD segments file obtained from say Poisson Point Process or
      Modulation VAD.

      The CTM file is in the standard NIST format. The segments file is
      the standard Kaldi format.

      This script assumes that the CTM file and the segments file are both
      sorted by the utterance ID. This script would print only the
      hypotheses in the CTM file that are partially or completely inside
      the input segments file.'''), \
          formatter_class=argparse.RawDescriptionHelpFormatter)
  parser.add_argument('ctm_file', type=str, \
      help='Input CTM file')
  parser.add_argument('segments_file', type=str, \
      help='Segments file')
  parser.add_argument('out_ctm_file', type=str, \
      help='Output CTM file. Will overwrite the file.')

  parser.usage=':'.join(parser.format_usage().split(':')[1:]) \
      + 'e.g. :  %(prog)s exp/sgmm5_mmi_b0.1/decode_fmllr_dev10h.seg_it1/score_10/dev10h.seg.ctm.bak data/dev10h.vad/segments exp/sgmm5_mmi_b0.1/decode_fmllr_dev10h.seg_it1/score_10/dev10h.seg.ctm'

  options = parser.parse_args()

  segments_file = options.segments_file
  ctm_file = options.ctm_file

  try:
    ctm_file_handle = open(ctm_file)
  except IOError as e:
    sys.stderr.write("%s: %s: Cannot open file %s\n" % (sys.argv[0], e, ctm_file))
    sys.exit(1)

  try:
    segments_handle = open(segments_file)
  except IOError:
    sys.stderr.write("%s: %s: Cannot open file %s\n" % (sys.argv[0], e, segments_file))
    sys.exit(1)

  if options.out_ctm_file == "-":
    out_ctm_handle = sys.stdout
  else:
    try:
      out_ctm_handle = open(options.out_ctm_file, 'w')
    except IOError:
      sys.stderr.write("%s: %s: Cannot open file %s\n" % (sys.argv[0], e, options.out_ctm_file))
      sys.exit(1)
  # End if

  try:
    seg_utt_id, seg_file_id, seg_s, seg_e = segments_handle.readline().strip().split()
  except (AttributeError, ValueError):
    sys.stderr.write("%s: %s: %s not of correct format in %s\n" % (sys.argv[0], e, line.strip(), segments_file))
    sys.exit(1)

  seg_s = float(seg_s)
  seg_e = float(seg_e)

  # Read CTM file
  for line in ctm_file_handle.readlines():
    splits = line.strip().split()
    s = float(splits[2])
    e = float(splits[3]) + s

    file_id = splits[0]

    # Read lines from the segments file until the segment where the
    # hypothesized word can be found
    while seg_file_id < file_id or (seg_file_id == file_id and seg_e < s):
      try:
        seg_utt_id, seg_file_id, seg_s, seg_e = segments_handle.readline().strip().split()
      except (AttributeError, ValueError):
        sys.stderr.write("%s: %s: %s not of correct format in %s\n" % (sys.argv[0], e, line.strip(), segments_file))
        sys.exit(1)

      seg_s = float(seg_s)
      seg_e = float(seg_e)

    if seg_file_id == file_id and e >= seg_s:
      out_ctm_handle.write(line)

if __name__ == '__main__':
  main()
