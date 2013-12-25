#!/usr/bin/python

import argparse, sys, os, re
from argparse import ArgumentParser

class Stats:
  def __init__(self):
    self.insertions = 0
    self.substitutions = 0
    self.insertions_added_inside = 0
    self.insertions_added_outside = 0
    self.human_ctm_lines = 0
    self.reseg_ctm_lines = 0
    self.out_ctm_lines = 0

  def print_stats(self):
    sys.stderr.write("%s: Writing stats...\n" % sys.argv[0])
    sys.stderr.write("%3d insertions\n" % self.insertions)
    sys.stderr.write("%3d substitutions\n" % self.substitutions)
    sys.stderr.write("%3d insertions added inside segments\n" % self.insertions_added_inside)
    sys.stderr.write("%3d insertions added outside segments\n" % self.insertions_added_outside)
    sys.stderr.write("%9d lines in human ctm\n" % self.human_ctm_lines)
    sys.stderr.write("%9d lines in reseg ctm\n" % self.reseg_ctm_lines)
    sys.stderr.write("%9d lines in out ctm\n" % self.out_ctm_lines)

def main():
  parser = ArgumentParser(description='Add fillers to transcriptions')
  parser.add_argument('human_ctm', \
      help='Human CTM file - ' \
      + 'Typically obtained by using the script steps/get_train_ctm.sh')
  parser.add_argument('reseg_ctm', \
      help='Reseg CTM file - ' \
      + 'Obtained by decoding the resegmented training data')
  parser.add_argument('insertion_list', \
      help='List of insertions - ' \
      + 'The file must be obtained using the script utils/extract_insertions.py')
  parser.add_argument('segments_file', \
      help='Original train segments file')
  parser.add_argument('-s', '--frame-shift', \
      dest='frame_shift', default=0.01, type=float, \
      help="Frame shift in seconds")
  parser.add_argument('--num-fillers', type=int, \
      dest='num_fillers', default=10, \
      help="Number of artificial fillers to be added")
  parser.add_argument('--count-threshold', type=int, \
      dest='count_threshold', default=10, \
      help="Minimum count of filler for a separate model to be added")

  try:
    options = parser.parse_args()
  except Exception:
    parser.print_help()
    sys.exit(1)

  human_ctm = options.human_ctm
  reseg_ctm = options.reseg_ctm
  insertion_list = options.insertion_list
  segments_file = options.segments_file

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
    segments_file_handle = open(segments_file)
  except IOError:
    sys.stderr.write("ERROR: %s: Unable to open file %s\n" % (sys.argv[0], segments_file))
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
    sys.stderr.write("Found %d top insertions\n" % len(top_insertions))
  except EOFError:
    sys.stderr.write("ERROR: %s: End of file reached prematurely in %s\n" % (sys.argv[0], insertion_file))
    sys.exit(1)

  stats = Stats()

  line = insertion_file_handle.readline()
  # Read the locations of the insertions.
  # Assuming that the file is sorted

  # The format of line is like this:
  # BABEL_OP1_102_99709_20120429_201437_outLine  57.960000  58.200000   0.240000 "<w>" S("<int>")
  # The substitution part is optional and is only for substitutions

  human_lines = []
  reseg_lines = []
  seg_lines = []

  # Read the human ctm file and sort it based on file_id,
  # channel_id and start of word with the order giving higher priority to the file_id
  for l in human_ctm_handle.readlines():
    try:
      human_splits = l.strip().split()
      human_file_id, human_channel = human_splits[0:2]
      human_s = float(human_splits[2])
      human_len = float(human_splits[3])
      human_w = human_splits[4]
      human_lines.append((human_file_id, human_channel, human_s, human_len, human_w))
    except IndexError:
      sys.stderr.write("ERROR: %s: Unparsable line: %s in %s\n" % (sys.argv[0], l.strip(), human_ctm))
      sys.exit(1)

  human_lines.sort(key=lambda x:x[2])
  human_lines.sort(key=lambda x:x[1])
  human_lines.sort(key=lambda x:x[0])

  # Read the reseg ctm file and sort it based on file_id,
  # channel_id and start of word with the order giving higher
  # priority to the file_id
  for l in reseg_ctm_handle.readlines():
    try:
      reseg_splits = l.strip().split()
      reseg_file_id, reseg_channel = reseg_splits[0:2]
      reseg_s = float(reseg_splits[2])
      reseg_len = float(reseg_splits[3])
      reseg_w = reseg_splits[4]
      reseg_lines.append((reseg_file_id, reseg_channel, reseg_s, reseg_len, reseg_w))
    except IndexError:
      sys.stderr.write("ERROR: %s: Unparsable line: %s in %s\n" % (sys.argv[0], l.strip(), reseg_ctm))
      sys.exit(1)
  reseg_lines.sort(key=lambda x:x[2])
  reseg_lines.sort(key=lambda x:x[1])
  reseg_lines.sort(key=lambda x:x[0])

  # Read the segments file and sort it based on file_id,
  # and start of segment with the order giving higher
  # priority to the file_id
  for l in segments_file_handle.readlines():
    try:
      seg_splits = l.strip().split()
      seg_utt_id, seg_file_id = seg_splits[0:2]
      seg_s = float(seg_splits[2])
      seg_e = float(seg_splits[3])
      seg_lines.append((seg_file_id, seg_s, seg_e))
    except IndexError:
      sys.stderr.write("ERROR: %s: Unparsable line: %s in %s\n" % (sys.argv[0], l.strip(), segments_file))
      sys.exit(1)
  seg_lines.sort(key=lambda x:x[1])
  seg_lines.sort(key=lambda x:x[0])

  # Pointers to navigate through the lines in the
  # human ctm, reseg ctm and the segments file
  human_ptr = 0
  reseg_ptr = 0
  seg_ptr = 0

  # Store output lines temporarily so that it
  # can be sorted
  out_lines = []

  while len(line) > 0:
    splits = line.strip().split()

    if len(splits) == 6:
      # This is an insertion
      stats.insertions += 1
      file_id, channel, s, e, conf, w = splits
      s = float(s)
      e = float(e)
      sub_w = None
    elif len(splits) == 7:
      # This is a substitution
      stats.substitutions += 1
      file_id, channel, s, e, conf, w, sub_w = splits
      s = float(s)
      e = float(e)
      assert (re.match(r"\"<.*>\"", sub_w))
    else:
      sys.stderr.write("ERROR: %s: Bad line format in %s \n%s\n" % (sys.argv[0], insertion_list, line))
      sys.exit(1)
    # End if

    # Move human_ptr to the line in the human ctm
    # whose word start is just after the start
    # of the hypothesis
    while human_ptr < len(human_lines) and (human_lines[human_ptr][0] < file_id or (human_lines[human_ptr][0] == file_id and human_lines[human_ptr][2] <= s)):
      out_lines.append(human_lines[human_ptr])
      human_ptr += 1

    #if human_ptr == len(human_lines):
    #  human_ptr -= 1

    # Move reseg_ptr to the line in the reseg ctm
    # whose word start is at the start
    # of the hypothesis. This line must correspond to
    # the same line as in the hypothesis
    while (reseg_ptr < len(reseg_lines)
        and (reseg_lines[reseg_ptr][0] < file_id
          or (reseg_lines[reseg_ptr][0] == file_id
            and reseg_lines[reseg_ptr][2] < s))):
      reseg_ptr += 1
    if reseg_ptr == len(reseg_lines):
      break

    # Move seg_ptr to the line in the segmentes file
    # whose segment end is just after the start
    # of the hypothesis
    while (seg_ptr < len(seg_lines)
        and (seg_lines[seg_ptr][0] < file_id
          or (seg_lines[seg_ptr][0] == file_id
            and seg_lines[seg_ptr][2] < s))):
      seg_ptr += 1

    assert(abs(s - reseg_lines[reseg_ptr][2]) < 1e-6)
    assert(abs(e - reseg_lines[reseg_ptr][3] - reseg_lines[reseg_ptr][2]) < 1e-6)
    assert(file_id == reseg_lines[reseg_ptr][0])

    if sub_w == None:
      # This is an insertion

      # Check if the hypothesized word is in the segments
      # or not.
      # This can be done by checking if the segment start
      # is after the end of the hypothesized word. Since
      # the seg_ptr has been incremented so that
      # the segment end of the previous segment is before
      # the start of the hypothesized word, clearly this
      # hypothesized word must be outside the segments
      if seg_ptr >= len(seg_lines) or seg_lines[seg_ptr][0] != file_id or seg_lines[seg_ptr][1] > e:
        # This insertion is not in human segments.
        # So just add a filler corresponding to the insertion
        # If the frequency of the inserted word
        # is more than a threshold then add a separate
        # filler. Otherwise add <unk> as a filler

        # Here, if w is not in top_insertions, then it is added as <unk>
        # or unknown word.
        # Since it is outside the segments, we need to capture the information
        # somehow. It may not be good to add a separate filler for each
        # because they may not occur enough times.
        # But when the word does not get inserted many times,
        # it may be useful to add as the special filler <unk> that can
        # model all these junk sounds and OOVs in general.
        if w in top_insertions:
          if top_insertions[w] > options.count_threshold:
            filler = "<"+re.search(r"\"(?P<word>.*)\"",w).group('word')+">"
          else:
            filler = "<unk>"
          stats.insertions_added_outside += 1
          out_lines.append(reseg_lines[reseg_ptr][0:-1]+(filler,))
        # End if
      else:
        # This insertion is in the segments. Add it
        # only if the neighboring phones does not have
        # any substitutions
        if (w in top_insertions
            and human_ptr < len(human_lines)
            and human_ptr - 1 >= 0
            and reseg_ptr + 1 < len(reseg_lines)
            and reseg_ptr - 1 >= 0
            and (tuple([ x[-1]
              for x in human_lines[human_ptr-1:human_ptr+1] ])
              == tuple([ x[-1]
                for x in (reseg_lines[reseg_ptr-1:reseg_ptr]
                  + reseg_lines[reseg_ptr+1:reseg_ptr+2])]))):

          # If the frequency of the inserted word
          # is more than a threshold then add a separate
          # filler. Otherwise add <unk> as a filler
          if top_insertions[w] > options.count_threshold:
            filler = "<"+re.search(r"\"(?P<word>.*)\"",w).group('word')+">"
          else:
            filler = "<unk>"
          stats.insertions_added_inside += 1
          out_lines.append(reseg_lines[reseg_ptr][0:-1]+(filler,))
        # End if
      # End if
    else:
      # This is a substitution
      # There is already a filler here. So just continue.
      line = insertion_file_handle.readline()
      continue
      # Add it
      # only if the neighboring phones does not have
      # any substitutions
      #if w in top_insertions and tuple([ x[-1] for x in human_lines[human_ptr-2:human_ptr-1] + human_lines[human_ptr:human_ptr+1] ]) == tuple([ x[-1] for x in reseg_lines[reseg_ptr-1:reseg_ptr] + reseg_lines[reseg_ptr+1:reseg_ptr+2] ]):
      #  sys.stderr.write("Substitutions %s %s\n" % (w,sub_w))
      #  if top_insertions[w] > options.count_threshold:
      #    filler = "<"+re.search(r"\"(?P<word>.*)\"",w).group('word')+">"
      #  else:
      #    filler = "<unk>"
      #  out_lines.append(reseg_lines[reseg_ptr][0:-1]+(filler,))
      #  out_lines.append(human_lines[human_ptr-1])
      # End if
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
  stats.human_ctm_lines = len(human_lines)
  stats.reseg_ctm_lines = len(reseg_lines)
  stats.out_ctm_lines = len(out_lines)
  stats.print_stats()

if __name__ == '__main__':
  main()
