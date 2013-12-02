#!/usr/bin/python

import argparse, sys, os, re
from argparse import ArgumentParser

def main():
  segments_file = None
  parser = ArgumentParser(description='Extract insertions from .ctm.sgml file assuming it is sorted')
  parser.add_argument('args', nargs=1, help='<sgml_file>')
  parser.add_argument('--segments', type=str, \
      dest='segments_file', \
      help='Sorted segments file to restrict insertions to outside it')
  options = parser.parse_args()

  segments_file = options.segments_file
  sgml_file = options.args[0]

  try:
    sgml_file_handle = open(sgml_file)
  except IOError:
    sys.stderr.write("ERROR: %s: Cannot open %s\n" % (sys.argv[0], sgml_file))
    sys.exit(1)

  if segments_file != None:
    try:
      segments_handle = open(segments_file)
    except IOError:
      sys.stderr.write("WARNING: %s: Cannot open %s\n" % (sys.argv[0], segments_file))
      sys.exit(1)
    line = segments_handle.readline()
    try:
      seg_utt_id, seg_file_id, seg_s, seg_e = line.strip().split()
    except AttributeError:
      sys.stderr.write("ERROR: %s: %s not of correct format in %s\n" % (sys.argv[0], line, segments_file))
      sys.exit(1)
    seg_s = float(seg_s)
    seg_e = float(seg_e)

  # Initialize variable to store the insertions
  locations = []

  insertions = {}
  insertion_lengths = {}
  insertion_lengths["ALL"] = []

  substitutions = {}
  substitution_lengths = {}
  substitution_lengths["ALL"] = []

  # Read sgml file
  lines = sgml_file_handle.readlines()
  if len(lines) == 0:
    sys.stderr.write("ERROR: %s: %s is empty\n" % (sys.argv[0], sgml_file))
    sys.exit(1)
  # End if

  for l in lines:
    # Extract out the file_id from the sgml file
    m = re.search(r"file=\"(?P<file_id>\w+)\" channel=\"(?P<channel>\w+)\"",l)
    if m:
      # A file_id found. Store it and start processing the next line.
      file_id = m.group('file_id')
      channel = m.group('channel')
      continue
    # End if

    # Extract out the insertions of substitutions of fillers
    m = re.findall(r"(?:^|:)(?P<insertion>(?:(?:I,.*?)|(?:S,\"<.*?)))(?::|$)", l)

    if len(m) > 0:
      # Found an insertion or substitution of a filler
      for a in m:
        # The format of 'a' would be
        # I/S,reference_word,hypothesized_word,start_time+end_time,confidence_score
        # So split it on ',' and process it
        b = a.split(',')

        # Get the start and end times
        s,e = float(b[3].split('+')[0]), float(b[3].split('+')[1])

        # If segments_file is not None. We need to check if
        # the hypothesis is within a segment
        # Since the file is sorted, we can do it by
        # sequentially scanning the file and moving to
        # next line whenever the end of the segment is before
        # the start of the hypothesis
        while segments_file != None and len(line) > 0 and (seg_file_id < file_id or seg_e < s):
          line = segments_handle.readline()
          seg_utt_id, seg_file_id, seg_s, seg_e = line.strip().split()
          seg_s = float(seg_s)
          seg_e = float(seg_e)
        # End while loop. Means we have reached the end of the
        # file or we have reached the location in time of the
        # hypothesized speech

        if segments_file == None or (seg_file_id == file_id and seg_s > e):
          # Outside the segments
          if b[1] != "":
            # This is a substitution
            locations.append((file_id, channel, s, e, e-s, b[2], b[1]))
            # Accumulate substitution statistics
            substitutions[b[2]] = substitutions.get(b[2],0) + 1
            substitution_lengths.setdefault(b[2],[])
            substitution_lengths[b[2]].append(e-s)
            substitutions["ALL"] = substitutions.get("ALL",0) + 1
            substitution_lengths["ALL"].append(e-s)
          else:
            # This is an insertion
            locations.append((file_id, channel, s, e, e-s, b[2]))
            # Accumulate insertion statistics
            insertions[b[2]] = insertions.get(b[2],0) + 1
            insertion_lengths.setdefault(b[2],[])
            insertion_lengths[b[2]].append(e-s)
            insertions["ALL"] = insertions.get("ALL",0) + 1
            insertion_lengths["ALL"].append(e-s)
          # End if
        # End if
      # End for loop over the extracted insertions
    # End if
  # End for loop over sgml_file lines

  if segments_file != None:
    segments_handle.close()
  sgml_file_handle.close()

  # Print statistics
  print("<Statistics>")
  print("<Insertions>")
  print("Count\tWord\tAverage length")
  stats = sorted([ (insertions[w], w,sum(insertion_lengths[w])/len(insertion_lengths[w])) for w in insertions ], key=lambda x:x[0], reverse=True)
  for w in stats:
    print("%5d\t%s\t\t%f" % w)
  print("<Substitutions>")
  stats = sorted([ (substitutions[w], w,sum(substitution_lengths[w])/len(substitution_lengths[w])) for w in substitutions ], key=lambda x:x[0], reverse=True)
  for w in stats:
    print("%5d\t%s\t\t%f" % w)

  # Print counts. This is required to decide the most
  # frequent insertions that would be used to add
  # artificial fillers
  print("<Counts>")
  for w in substitutions:
    insertions[w] = insertions.get(w,0) + substitutions[w]

  for w,c in sorted([ (w,c) for w,c in insertions.items()], key=lambda x:x[1], reverse=True):
    print("%5d\t%s" % (c,w))

  # Print locations of the insertions
  print("<Locations>")
  locations.sort(key=lambda x:x[2])
  locations.sort(key=lambda x:x[1])
  locations.sort(key=lambda x:x[0])

  for w in locations:
    if len(w) == 7:
      print("%50s %s %10f %10f %10f %s %s" % w)
    elif len(w) == 6:
      print("%50s %s %10f %10f %10f %s" % w)
    else:
      sys.stderr.write("ERROR: %s: Incorrect format \n %s\n" % (sys.argv[0], w))

if __name__ == '__main__':
  main()
