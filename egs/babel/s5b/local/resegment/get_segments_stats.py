#!/usr/bin/python

import sys, argparse
from argparse import ArgumentParser
import numpy as np
import matplotlib
matplotlib.use('Agg')
from matplotlib import pyplot as plt

def main():
  parser = ArgumentParser(description='Get segments stats')
  parser.add_argument('--verbose', type=int, \
      dest='verbose', default=0, \
      help='Give higher verbose for more logging (default: %(default)s)')
  parser.add_argument('segments_file', \
      help='Segments file')
  parser.add_argument('plot_file', nargs='?', \
      help='Output histogram plot to file. With extension.')
  parser.usage=':'.join(parser.format_usage().split(':')[1:]) \
      + 'e.g. :  %(prog)s data/dev10h.seg/segments seg_hist.pdf'
  options = parser.parse_args()

  try:
    segments_file_handle = open(options.segments_file)
  except IOError as e:
    sys.stderr.write("%s: Unable to file %s\n%s\n" % (sys.argv[0], options.segments_file, e.strerror))
    sys.exit(1)

  lengths = []
  for line in segments_file_handle.readlines():
    splits = line.strip().split()
    if len(splits) != 4:
      sys.stderr.write("Incorrect format of line %s in segments file %s\n" % (line, options.segments_file))
      sys.exit(1)

    lengths.append(float(splits[3]) - float(splits[2]))

  sys.stdout.write("Minimum: %6.3f s\n" % min(lengths))
  sys.stdout.write("Maximum: %6.3f s\n" % max(lengths))
  sys.stdout.write("Mean   : %6.3f s\n" % (sum(lengths)/len(lengths)))
  sys.stdout.write("Total  : %6.3f hrs\n" % (sum(lengths)/3600.0))
  sys.stdout.write("Number of segments longer than 10 seconds: %d\n" % sum([1 for x in lengths if x > 10]))

  if options.plot_file == None:
    sys.exit(0)

  n, bins, patches = plt.hist(lengths, bins=100, facecolor='b')

  plt.xlabel('Length')
  plt.ylabel('Number of segments')
  plt.title('Histogram of segment lengths')
  plt.grid(True)
  try:
    plt.savefig(options.plot_file, transparent=True, papertype='a4')
  except IOError as e:
    sys.stderr.write("%s: Unable to file %s\n%s\n" % (sys.argv[0], options.plot_file, e.strerror))
    sys.exit(1)

if __name__ == '__main__':
  main()
