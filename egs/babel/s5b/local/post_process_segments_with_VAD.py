#! /usr/bin/python

import os, argparse, sys, textwrap
from argparse import ArgumentParser

def main():
  parser = ArgumentParser(description=textwrap.dedent('''\
      Filter out segments using a VAD file.

      The program takes the input segments file possibly from stdin
      and a VAD directory as argument. The program searches for the
      .vad file in VAD directory corresponding to the recording id
      and removes any part in the segment that the VAD considers as
      non-speech if the non-speech is longer than a threshold length.

      The VAD files are the format:
      <start-time> <end-time>
      where start time and end time are times * 100 stored as integers.

      The segments file is in the usual Kaldi format.

      This is typically used with VAD generated by non-speech remover
      such as the one based on Poisson Point Process.'''), \
          formatter_class=argparse.RawDescriptionHelpFormatter)
  parser.add_argument('--verbose', type=int, \
      dest='verbose', default=0, \
      help='Give higher verbose for more logging (default: %(default)s)')
  parser.add_argument('--frame-shift', type=float, \
      dest='frame_shift', default=0.01, \
      help="Time difference between adjacent frame (default: %(default)s)s")
  parser.add_argument('--non-speech-threshold', type=float, \
      dest='non_speech_threshold', default=1.0, \
      help="""Remove any non-speech region that is longer than the threshold
      in seconds""")
  parser.add_argument('--first-separator', type=str, \
      dest='first_separator', default="-", \
      help="Separator between recording-id and start-time (default: %(default)s)")
  parser.add_argument('--second-separator', type=str, \
      dest='second_separator', default="-", \
      help="Separator between start-time and end-time (default: %(default)s)")
  parser.add_argument('--padding', type=float, default=0.0, \
      help="Padding to VAD segments")
  parser.add_argument('--min-segment-length', type=float, default=0.2, \
      help="Discard segments smaller than a particular length")
  parser.add_argument('input_segments', \
      help='Input segments file')
  parser.add_argument('vad_directory', \
      help='VAD directory containing all the .vad files')
  parser.add_argument('output_segments', nargs='?', default="-", \
      help='Output segments file')
  parser.usage=':'.join(parser.format_usage().split(':')[1:]) \
      + 'e.g. :  %(prog)s - exp/tri4b_whole_resegment_dev10h/modvad data/dev10h.seg/segments'
  options = parser.parse_args()

  # Read input segments from either stdin or open a file for reading
  if options.input_segments == '-':
    in_file_handle = sys.stdin
  else:
    try:
      in_file_handle = open(options.input_segments, 'r')
    except IOError as e:
      sys.stderr.write("%s: %s: Unable to open file %s\n" % (sys.argv[0], e, options.input_segments))
      sys.exit(1)
  # End if

  # Open output segments file for writing
  if options.output_segments == '-':
    out_file_handle = sys.stdout
  else:
    try:
      out_file_handle = open(options.output_segments, 'w')
    except IOError as e:
      sys.stderr.write("%s: %s: Unable to open file %s\n" % (sys.argv[0], e, options.output_segments))
      sys.exit(1)
  # End if

  # Initializations
  reco_id = None
  prev_reco_id = None

  A = []
  S = []
  E = []
  i = 0

  # Read input segment lines
  for line in in_file_handle.readlines():
    if len(line.strip()) == 0:
      # Skip any empty lines
      continue
    # End if

    # Segment line has format <utterance_id> <reco_id> <start> <end>
    # Split the line and store the start and end times in number of frames
    # rather than in seconds
    splits = line.strip().split()
    reco_id = splits[1]
    seg_start = int(float(splits[2]) / options.frame_shift)
    seg_end = int(float(splits[3]) / options.frame_shift)

    if reco_id == prev_reco_id or prev_reco_id == None:
      # prev_reco_id is None for the first file
      # If reco_id is same as in the previous iteration, then we are still
      # reading the segments for the same file
      # Continue to extend the same array
      if (seg_end > i):
        A.extend([False]*(seg_end-i))
        S.extend([False]*(seg_end-i))
        E.extend([False]*(seg_end-i+1))

      # A must have True between seg_start and seg_end with True at the
      # boundaries in S and E
      A[seg_start:seg_end] = [True]*(seg_end-seg_start)
      S[seg_start] = True
      E[seg_end] = True

      # Already processed till seg_end
      i = seg_end
    else:
      # reco_id is different from previous iteration's. Finish processing the
      # previous recording id before moving to the new one.

      # Initializations for reading VAD segments
      j = 0
      B = []
      try:
        vad_handle = open("%s/%s.vad" % (options.vad_directory, prev_reco_id))
      except IOError as e:
        sys.stderr.write("%s: %s: Cannot open %s/%s.vad for reading\n" % (sys.argv[0], e, options.vad_directory, prev_reco_id))
        sys.exit(1)

      for l in vad_handle.readlines():
        # Read VAD lines
        if len(l.strip()) == 0:
          # Skip any empty lines in VAD
          continue

        # VAD line has format <start> <end>,
        # where the start and end times are stored as integers in 10ms units
        # Split the line and store the start and end times in number of frames
        # rather than in 10ms. This may be the same if frame shift is 0.01
        s = l.strip().split()
        vad_start = int((float(s[0]) / 100.0 - options.padding) / options.frame_shift)
        vad_end = int((float(s[1]) / 100.0 + options.padding) / options.frame_shift)

        if (vad_end > j):
          B.extend([False]*(vad_end-j))

        # Mark as True the portion inside a VAD segment
        B[vad_start:vad_end] = [True] * (vad_end-vad_start)
        j = vad_end
      # End for loop over lines in VAD file

      # Print segments after doing some processing using the VAD segments
      print_segments(A, B, S, E, prev_reco_id, options, out_file_handle)

      if options.verbose > 0:
        sys.stderr.write("Done processing file id %s\n" % prev_reco_id)

      # Start getting segments for new recording id
      i =  0
      A = [False]*(seg_end-i)
      S = [False]*(seg_end-i)
      E = [False]*(seg_end-i+1)

      A[seg_start:seg_end] = [True]*(seg_end-seg_start)
      S[seg_start] = True
      E[seg_end] = True

      i = seg_end
    # End if checking reco_id

    # Set the current reco_id as the prev_reco_id for the next iteration
    prev_reco_id = reco_id
  # End for loop over lines in segments file

  # Process the final file_id that is not processed in the loop.
  j = 0
  B = []
  vad_handle = open("%s/%s.vad" % (options.vad_directory, prev_reco_id))
  for l in vad_handle.readlines():
    # Read VAD lines
    if len(l.strip()) == 0:
      # Skip any empty lines in VAD
      continue

    # VAD line has format <start> <end>,
    # where the start and end times are stored as integers in 10ms units
    # Split the line and store the start and end times in number of frames
    # rather than in 10ms. This may be the same if frame shift is 0.01
    s = l.strip().split()
    vad_start = int((float(s[0]) / 100.0 - options.padding) / options.frame_shift)
    vad_end = int((float(s[1]) / 100.0 + options.padding) / options.frame_shift)

    if (vad_end > j):
      B.extend([False]*(vad_end-j))

    # Mark as True the portion inside a VAD segment
    B[vad_start:vad_end] = [True] * (vad_end-vad_start)
    j = vad_end
  # End for loop over lines in VAD file

  # Print segments after doing some processing using the VAD segments
  print_segments(A, B, S, E, prev_reco_id, options, out_file_handle)
# End function main()

# This function processes the prediction array of the input segments A,
# the prediction array of the VAD segments B, the original start and end
# boundary markers, S and E respectively to get the output segments.
# The VAD segments is a non-speech remover of high precision. If it has removed
# something then that is actually non-speech with high probability.
def print_segments(A, B, S, E, reco_id, options, out_file_handle):
  # Initialize the output segment prediction array
  C = [0]*len(A)

  for n in range(0,len(A)):
    if A[n] and (n >= len(B) or not B[n]):
      # VAD says this is non-speech. So this frame is likely to be
      # non-speech. Can remove this later based on some threshold.
      C[n] = 2
    elif A[n] and B[n]:
      # VAD also says it is speech. No additional information here.
      C[n] = 1
    else:
      C[n] = 0
  # End for loop over input prediction

  n = 0
  while n < len(C):
    if C[n] == 2:
      p = n + 1
      while p < len(C) and C[p] == 2:
        p += 1
      if p - n > options.non_speech_threshold or p >= len(A) or not A[p] or n == 0 or not A[n-1]:
        sys.stderr.write("Non-speech of length %d removed\n" % (p-n))
        C[n:p] = [False]*(p-n)
        if (n == 0 or not A[n-1]) and (p >= len(A) or not A[p]):
          # Silence on both sides
          assert (S[n] and E[p])
          S[n] = False
          E[p] = False
        elif n == 0 or not A[n-1]:
          # Silence on left side
          assert (S[n])
          S[n] = False
          S[p] = True
        elif p >= len(A) or not A[p]:
          # Silence on right side
          assert (E[p])
          E[p] = False
          E[n] = True
        else:
          # Speech on both sides
          assert (p - n > options.non_speech_threshold and A[p] and A[n-1])
          E[n] = True
          S[p] = True
      else:
        # Speech on both sides and length of non-speech is less than threshold
        assert (A[p] and A[n-1])
        sys.stderr.write("Non-speech of length %d not removed\n" % (p-n))
        C[n:p] = [True]*(p-n)
      n = p
      if n == len(C):
        break
    else:
      C[n] = (C[n] == 1)
      n += 1

  segments = []
  n = 0
  while n < len(C):
    if (S[n] and C[n]) or ((n == 0 or not C[n-1]) and C[n]):
      # Start of a segment or a transition in C
      p = n + 1
      while p < len(C) and C[p] and not E[p]:
        p += 1
      if p - n > options.min_segment_length / options.frame_shift:
        segments.append((n,p))
        max_end_time = p
      else:
        sys.stderr.write("Discarding segment of length %.2f seconds\n" % ((p-n)*options.frame_shift))
      if p < len(C) and (C[p] or S[p]):
        n = p - 1
      else:
        n = p
    n += 1

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
    utterance_id = "%s%s%s%s%s" % (reco_id, options.first_separator, start_str, options.second_separator, end_str)
    # Output:
    out_file_handle.write("%s %s %s %s\n" % (utterance_id, reco_id, start_seconds, end_seconds))

if __name__ == '__main__':
  main()