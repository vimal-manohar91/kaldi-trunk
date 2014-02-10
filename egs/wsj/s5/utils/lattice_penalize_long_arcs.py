#! /usr/bin/python

import argparse, sys, re
from argparse import ArgumentParser
import math

def penalty(length, threshold):
  if length <= threshold:
    return 0.0
  x = float(length - threshold) / float(threshold)
  y = 0.0

  if x > 10:
    y = 1.0
  return 0.1 * (x + 0.01 * x * x + 0.0001 * y * x * x * x * x)

def main():
  parser = ArgumentParser(description='Penalize long arcs')
  parser.add_argument('--verbose', type=int, \
      dest='verbose', default=0, \
      help='Give higher verbose for more logging (default: %(default)s)')
  parser.add_argument('--std-floor', type=float, default=0.5, \
      help='Standard deviation floor to avoid 0 variance (default: %(default)s)')
  parser.add_argument('--penalty-type', choices=('NEG_LOG_PROB',), default='NEG_LOG_PROB', \
      help='Type of penalty')
  parser.add_argument('--duration-model-scale', type=float, \
      default=0.1, \
      help="Scale of Duration model relative to LM scale (default: %(default)s)")
  parser.add_argument('phone_lengths_file', metavar='<phone_lengths_file>', type=str, \
      help="Phone lengths file as a tuple of the phone as integer and mean and standard deviation of the length of the phone")
  parser.usage=":".join(parser.format_usage().split(':')[1:]) \
      + "e.g. :  gunzip -c lat.1.gz.temp | %(prog)s phone_lengths.txt | gzip -c > lat.1.gz\n"

  options = parser.parse_args()

  try:
    phone_lengths_file = open(options.phone_lengths_file, 'r')
  except IOError as e:
    sys.stderr.write("%s: %s\nUnable to open file %s\n" % (sys.argv[0], e, options.phone_lengths_file))
    sys.exit(1)
  # End try block

  length_stats = {}
  for line in phone_lengths_file.readlines():
    splits = line.strip().split()
    try:
      length_stats[int(splits[0])] = (float(splits[1]), float(splits[2]))
    except (IndexError, TypeError) as e:
      sys.stderr.write("%s: %s\nUnable to parse line %s" % (sys.argv, e, line.strip()))
  # End for loop

  line = sys.stdin.readline()
  while len(line) > 0:
    if len(line.strip()) == 0:
      line = sys.stdin.readline()
      continue
    # End if
    sys.stdout.write("\n\r" + line.strip() + " \n\r")
    line = sys.stdin.readline()
    if len(line.strip()) == 0:
      break
    # End if
    splits = line.strip().split()
    while len(splits) == 4:
      phone = int(splits[2])
      weights = splits[3].split(',')

      length = len(weights[2].split('_'))

      std_length = length_stats[phone][1] + options.std_floor
      mean_length = length_stats[phone][0]
      if options.penalty_type == 'NEG_LOG_PROB':
        p = math.log(2.0 * math.pi * std_length) + (mean_length - length) * (mean_length - length) / (2.0 * std_length * std_length)
      else:
        sys.stderr.write("%s: Invalid penalty type %s\n" % (sys.argv[0], options.penalty_type))
        sys.exit(1)
      # End if

      weights_new = ','.join([str(float(weights[0]) + options.duration_model_scale * p), weights[1], weights[2]])
      sys.stdout.write('\t'.join(splits[0:3]+[weights_new]) + "\n\r")
      line = sys.stdin.readline()
      splits = line.strip().split()
    sys.stdout.write('\t'.join(splits) + "\n\r")
    line = sys.stdin.readline()
  # End while loop

if __name__ == '__main__':
  main()

