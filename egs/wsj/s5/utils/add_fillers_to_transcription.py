#!/usr/bin/python

import argparse, sys, os, re
from argparse import ArgumentParser

def main():
  parser = ArgumentParser(description='Add fillers to transcriptions')
  parser.add_argument('args', nargs=4, \
      help='<human_ctm> <reseg_ctm> <insertions_list>')
  parser.add_argument('-s', '--frame-shift', \
      dest='frame_shift', default=0.01, type=float, \
      help="Frame shift in seconds")
  parser.add_argument('--num-fillers', type=int, \
      dest='num_fillers', default=10, \
      help="Number of artificial fillers to be added")
  parser.add_argument('--count-threshold', type=int, \
      dest='count_threshold', default=10, \
      help="Minimum count of filler for a separate model to be added")

  options = parser.parse_args()

  argv = options.args

  human_ctm = argv[0]
  reseg_ctm = argv[1]
  insertion_list = argv[2]
  segments_file = argv[3]

  try:
    insertion_file_handle = open(insertion_list)
  except IOError:
    sys.stderr.write("ERROR: %s: Unable to open file %s\n" % (sys.argv[0], insertion_list))
    sys.exit(1)

  try:
    human_ctm_handle = open(human_ctm)
  except IOError:
    sys.stderr.write("ERROR: %s: Unable to open file %s\n" % (sys.argv[0], human_ctm))
    sys.exit(1)

  try:
    reseg_ctm_handle = open(reseg_ctm)
  except IOError:
    sys.stderr.write("ERROR: %s: Unable to open file %s\n" % (sys.argv[0], reseg_ctm))
    sys.exit(1)

  try:
    line = insertion_file_handle.readline()

    while len(line) > 0 and not re.match("<Counts>",line):
      line = insertion_file_handle.readline()

    i = 0
    line = insertion_file_handle.readline()

    # Read the top few inserted words and store it in a
    # dictionary
    top_insertions = {}
    while len(line) > 0 and not re.match("<Locations>",line):
      c,w = line.strip().split()
      if i < options.num_fillers and w != "\"ALL\"" and not re.match(r"\"<.*>\"", w):
        top_insertions[w] = int(c)
        i += 1
      line = insertion_file_handle.readline()
  except EOFError:
    sys.stderr.write("ERROR: %s: End of file reached prematurely in %s\n" % (sys.argv[0], insertion_file))
    sys.exit(1)

  line = insertion_file_handle.readline()
  # Read the locations of the insertions.
  # Assuming that the file is sorted

  # The format of line is like this:
  # BABEL_OP1_102_99709_20120429_201437_outLine  57.960000  58.200000   0.240000 "<w>" S("<int>")
  # The substitution part is optional and is only for substitutions

  human_lines = []
  reseg_lines = []

  for l in human_ctm_handle.readlines():
    human_splits = l.strip().split()
    human_file_id, human_channel = human_splits[0:2]
    human_s = float(human_splits[2])
    human_len = float(human_splits[3])
    human_w = human_splits[4]
    human_lines.append((human_file_id, human_channel, human_s, human_len, human_w))
  human_lines.sort(key=lambda x:x[2])
  human_lines.sort(key=lambda x:x[1])
  human_lines.sort(key=lambda x:x[0])

  for l in reseg_ctm_handle.readlines():
    reseg_splits = l.strip().split()
    reseg_file_id, reseg_channel = reseg_splits[0:2]
    reseg_s = float(reseg_splits[2])
    reseg_len = float(reseg_splits[3])
    reseg_w = reseg_splits[4]
    reseg_lines.append((reseg_file_id, reseg_channel, reseg_s, reseg_len, reseg_w))
  reseg_lines.sort(key=lambda x:x[2])
  reseg_lines.sort(key=lambda x:x[1])
  reseg_lines.sort(key=lambda x:x[0])

  human_ptr = 0
  reseg_ptr = 0

  out_lines = []

  while len(line) > 0:
    splits = line.strip().split()
    if len(splits) == 6:
      # This is an insertion
      file_id, channel, s, e, conf, w = splits
      s = float(s)
      e = float(e)
      sub_w = None

      while human_ptr < len(human_lines) and (human_lines[human_ptr][0] < file_id or (human_lines[human_ptr][0] == file_id and human_lines[human_ptr][2] <= s)):
        out_lines.append(human_lines[human_ptr])
        human_ptr += 1
      if human_ptr == len(human_lines):
        human_ptr -= 1

      while reseg_ptr < len(reseg_lines) and (reseg_lines[reseg_ptr][0] < file_id or (reseg_lines[reseg_ptr][0] == file_id and reseg_lines[reseg_ptr][2] < s)):
        reseg_ptr += 1
      if reseg_ptr == len(reseg_lines):
        break

      assert(abs(s - reseg_lines[reseg_ptr][2]) < 1e-6)
      assert(abs(e - reseg_lines[reseg_ptr][3] - reseg_lines[reseg_ptr][2]) < 1e-6)
      assert(file_id == reseg_lines[reseg_ptr][0])

      if human_ptr >= len(human_lines) or human_lines[human_ptr][2] > e:
        # This insertion is not in human segments.
        # So just add a filler corresponding to the insertion
        if w in top_insertions:
          if top_insertions[w] > options.count_threshold:
            filler = "<"+re.search(r"\"(?P<word>.*)\"",w).group('word')+">"
          else:
            filler = "<unk>"
          out_lines.append(reseg_lines[reseg_ptr][0:-1]+(filler,))
      else:
        # This insertion is in the segments. Add it
        # only if the neighboring phones does not have
        # any substitutions
        if w in top_insertions and tuple([ x[-1] for x in human_lines[human_ptr-2:human_ptr+1] ]) == tuple([ x[-1] for x in reseg_lines[reseg_ptr-1:reseg_ptr] + reseg_lines[reseg_ptr+1:reseg_ptr+2] ]):
          sys.stderr.write("Inside segments\n")
          if top_insertions[w] > options.count_threshold:
            filler = "<"+re.search(r"\"(?P<word>.*)\"",w).group('word')+">"
          else:
            filler = "<unk>"
          out_lines.append(reseg_lines[reseg_ptr][0:-1]+(filler,))
        # End if
      # End if
    elif len(splits) == 7:
      # This is a substitution
      # There is already a filler here. So just continue.
      continue
      # Its always inside the segments
      file_id, channel, s, e, conf, w, sub_w = splits
      s = float(s)
      e = float(e)

      assert (re.match(r"\"<.*>\"", sub_w))
      while human_ptr < len(human_lines) and (human_lines[human_ptr][0] < file_id or (human_lines[human_ptr][0] == file_id and human_lines[human_ptr][2] <= s)):
        out_lines.append(human_lines[human_ptr])
        human_ptr += 1
      if human_ptr == len(human_lines):
        human_ptr -= 1

      while reseg_ptr < len(reseg_lines) and (reseg_lines[reseg_ptr][0] < file_id or (reseg_lines[reseg_ptr][0] == file_id and reseg_lines[reseg_ptr][2] < s)):
        reseg_ptr += 1
      if reseg_ptr == len(reseg_lines):
        break

      assert(abs(s - reseg_lines[reseg_ptr][2]) < 1e-6)
      assert(abs(e - reseg_lines[reseg_ptr][3] - reseg_lines[reseg_ptr][2]) < 1e-6)
      assert(file_id == reseg_lines[reseg_ptr][0])

      # This insertion is in the segments. Add it
      # only if the neighboring phones does not have
      # any substitutions
      if w in top_insertions and tuple([ x[-1] for x in human_lines[human_ptr-2:human_ptr-1] + human_lines[human_ptr:human_ptr+1] ]) == tuple([ x[-1] for x in reseg_lines[reseg_ptr-1:reseg_ptr] + reseg_lines[reseg_ptr+1:reseg_ptr+2] ]):
        sys.stderr.write("Substitutions %s %s\n" % (w,sub_w))
        if top_insertions[w] > options.count_threshold:
          filler = "<"+re.search(r"\"(?P<word>.*)\"",w).group('word')+">"
        else:
          filler = "<unk>"
        out_lines.append(reseg_lines[reseg_ptr][0:-1]+(filler,))
        out_lines.append(human_lines[human_ptr-1])
      # End if
    else:
      sys.stderr.write("ERROR: %s: Bad line format in %s \n%s\n" % (sys.argv[0], insertion_list, line))
      sys.exit(1)
    # End if
    line = insertion_file_handle.readline()
  # End while loop over insertion_list lines

  while human_ptr < len(human_lines):
    out_lines.append(human_lines[human_ptr])
    human_ptr += 1
  # End while loop over human_ctm lines
  #out_lines.sort(key=lambda x:x[2])
  #out_lines.sort(key=lambda x:x[1])
  #out_lines.sort(key=lambda x:x[0])
  for l in out_lines:
    print("%s %s %f %f %s" % l)

if __name__ == '__main__':
  main()
