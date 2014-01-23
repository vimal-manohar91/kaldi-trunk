#! /usr/bin/python

import argparse, sys
from argparse import ArgumentParser

import numpy as np

def main():
  parser = ArgumentParser(description='Extract word length stats from ctm', formatter_class=argparse.ArgumentDefaultsHelpFormatter, epilog='e.g. %(prog)s exp/sgmm5_initial_mmi_b0.1/decode_fmllr_train.seg_it4/score_8/train.seg.ctm')
  parser.add_argument('--verbose', type=int, \
      dest='verbose', default=0, \
      help='Give higher verbose for more logging')
  parser.add_argument('ctm_file', type=str, \
      help='CTM file')
  options = parser.parse_args()

  try:
    ctm_file_handle = open(options.ctm_file, 'r')
  except IOError as e:
    repr(e)
    sys.strerr.write("%s: ERROR: Unable to open file %s\n" % (sys.argv[0], options.ctm_file))
    sys.exit(1)

  words = {}
  for line in ctm_file_handle:
    splits = line.strip().split()
    l = float(splits[3])
    w = splits[4]
    words.setdefault(w, ([], []))
    words[w][0].append(l)

  for w,a in words.items():
    l = a[0]
    words[w][1].append(sum(l)/len(l))
    words[w][1].append(min(l))
    words[w][1].append(max(l))
    words[w][1].append(np.percentile(l, 25))
    words[w][1].append(np.percentile(l, 50))
    words[w][1].append(np.percentile(l, 75))
    sys.stdout.write("\"%s\" %f %f %f %f %f %f\n" % ((w,)+tuple(words[w][1])))

if __name__ == '__main__':
  main()
