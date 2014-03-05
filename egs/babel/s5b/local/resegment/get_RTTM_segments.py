#!/usr/bin/python

import argparse, sys, os, glob
from argparse import ArgumentParser

def read_rttm_file(rttm_file, temp_dir, options):
  file_id = None
  this_file = []
  ref_file_handle = None
  reference = {}
  for line in rttm_file.readlines():
    splits = line.strip().split()
    type1 = splits[0]
    if type1 == "SPEAKER":
      continue
    if splits[1] != file_id:
      # A different file_id. Need to open a different file to write
      if this_file != []:
        # If this_file is empty, no reference RTTM corresponding to the file_id
        # is read. This will happen at the start of the file_id. Otherwise it means a
        # contiguous segment of previous file_id is processed. So write it to the file.
        # corresponding to the previous file_id
        try:
          ref_file_handle.write(' '.join(this_file))
          # Close the previous file if any
          ref_file_handle.close()
          this_file = []
        except AttributeError:
          1==1

      file_id = splits[1]
      if (file_id not in reference):
        # First time seeing this file_id. Open a new file for writing.
        reference[file_id] = 1
        try:
          ref_file_handle = open(temp_dir+"/"+file_id+".ref", 'w')
        except IOError:
          sys.stderr.write("Unable to open " + temp_dir+"/"+file_id+".ref for writing\n")
          sys.exit(1)
        ref_file_handle.write(file_id + "\t")
      else:
        # This file has been seen before but not in the previous iteration.
        # The file has already been closed. So open it for append.
        try:
          this_file = open(temp_dir+"/"+file_id+".ref").readline().strip().split()[1:]
          ref_file_handle = open(temp_dir+"/"+file_id+".ref", 'a')
        except IOError:
          sys.stderr.write("Unable to open " + temp_dir+"/"+file_id+".ref for appending\n")
          sys.exit(1)

    i = len(this_file)
    category = splits[6]
    word = splits[5]
    start_time = int(float(splits[3])/options.frame_shift + 0.5)
    duration = int(float(splits[4])/options.frame_shift + 0.5)
    if i < start_time:
      this_file.extend(["0"]*(start_time - i))
    if type1 == "NON-LEX":
      if category == "other":
        # <no-speech> is taken as Silence
        this_file.extend(["0"]*duration)
      else:
        this_file.extend(["1"]*duration)
    if type1 == "LEXEME":
      this_file.extend(["2"]*duration)
    if type1 == "NON-SPEECH":
      this_file.extend(["1"]*duration)

  ref_file_handle.write(' '.join(this_file))
  ref_file_handle.close()

def main():
  parser = ArgumentParser(description='Get RTTM segments', formatter_class=argparse.RawDescriptionHelpFormatter)
  parser.add_argument('--frame-shift', type=float, \
      dest='frame_shift', default=0.01, \
      help="Time difference between adjacent frame (default: %(default)s)s")
  parser.add_argument('--first-separator', type=str, \
      dest='first_separator', default="-", \
      help="Separator between recording-id and start-time (default: %(default)s)")
  parser.add_argument('--second-separator', type=str, \
      dest='second_separator', default="-", \
      help="Separator between start-time and end-time (default: %(default)s)")
  parser.add_argument('--keep-noise', action='store_true', \
      help="Keep the noise regions in the segments file")
  parser.add_argument('args', metavar=('<RTTM_file>', '<temp_dir>'), \
      nargs=2, help='<RTTM file> <temp_dir>')
  parser.add_argument('output_segments', nargs='?', default="-", \
      help='Output segments file')
  parser.usage=':'.join(parser.format_usage().split(':')[1:]) \
      + 'e.g. :  %(prog)s rttm_file.mitfarttm3 exp/tri4b_whole_resegment_dev10h/ref > data/dev10h/RTTM_segments'
  options = parser.parse_args()

  rttm_file = options.args[0]
  temp_dir = options.args[1]

  if options.output_segments == '-':
    out_file = sys.stdout
  else:
    try:
      out_file = open(options.output_segments, 'w')
    except IOError as e:
      sys.stderr.write("%s: %s: Unable to open file %s\n" % (sys.argv[0], e, options.output_segments))
      sys.exit(1)
  # End if

  os.system("mkdir -p " + temp_dir)

  read_rttm_file(open(rttm_file), temp_dir, options)

  reference_dir = temp_dir
  reference = [ f.split('/')[-1][0:-4] for f in glob.glob(reference_dir + "/*.ref") ]

  speech_class = ['2']
  if options.keep_noise:
    speech_class.append('1')

  for file_id in reference:
    A = [ x in speech_class for  x in open(reference_dir+"/"+file_id+".ref").readline().split()[1:] ]
    print_segments(A, file_id,  options, out_file)

def print_segments(A, file_id, options, out_file_handle = sys.stdout):
  # We also do some sanity checking here.
  segments = []

  n = 0
  while n < len(A):
    if A[n] and (not A[n-1] or n == 0):
      p = n + 1
      while p < len(A) and A[p]:
        p += 1
      segments.append((n,p))
      max_end_time = p
      if p < len(A):
        n = p - 1
      else:
        n = p
    n += 1

  if len(segments) == 0:
    sys.stderr.write("%s: Warning: no segments for recording %s\n" % (sys.argv[0], file_id))
    sys.exit(1)

  max_end_time_hundredths_second = int(100.0 * options.frame_shift * max_end_time)
  num_digits = 1
  i = 1
  while i < max_end_time_hundredths_second:
    i *= 10
    num_digits += 1
  format_str = r"%0" + "%d" % num_digits + "d" # e.g. "%05d"

  for start, end in segments:
    assert (end > start)
    start_seconds = "%.2f" % (options.frame_shift * start)
    end_seconds = "%.2f" % (options.frame_shift * end)
    start_str = format_str % (start * options.frame_shift * 100.0)
    end_str = format_str % (end * options.frame_shift * 100.0)
    utterance_id = "%s%s%s%s%s" % (file_id, options.first_separator, start_str, options.second_separator, end_str)
    # Output:
    out_file_handle.write("%s %s %s %s\n" % (utterance_id, file_id, start_seconds, end_seconds))

if __name__ == '__main__':
  main()

