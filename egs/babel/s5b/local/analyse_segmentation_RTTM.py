#!/usr/bin/python

import argparse, sys, os, glob, textwrap
from argparse import ArgumentParser
import numpy as np
import matplotlib
matplotlib.use('Agg')
from matplotlib import pyplot as plt

# A function to compute mean of an array
def mean(l):
  if len(l) > 0:
    return float(sum(l)) / len(l)
  return 0

# Analysis class
# Stores statistics like the confusion matrix, length of the segments etc.
class Analysis:
  def __init__(self, file_id, frame_shift, prefix = "", out_file = sys.stdout):
    self.confusion_matrix = [0] * 9
    self.type_counts = [ [[] for j in range(0,9)] for i in range(0,3) ]
    self.state_count = [ [] for i in range(0,9) ]
    self.energies = [ [] for i in range(0,9) ]
    self.markers = [ [] for i in range(0,9) ]
    self.phones = [ [] for i in range(0,9) ]
    self.min_length = [0] * 9
    self.max_length = [0] * 9
    self.mean_length = [0] * 9
    self.percentile25 = [0] * 9
    self.percentile50 = [0] * 9
    self.percentile75 = [0] * 9
    self.file_id = file_id
    self.frame_shift = frame_shift
    self.prefix = prefix
    self.out_file = out_file

  def plot_energy_histograms(self, out_file):
    for i in range(0,9):
      if len(self.energies[i]) == 0:
        continue
      plt.clf()
      n, bins, patches = plt.hist(self.energies[i], bins=100, facecolor='b')

      plt.xlabel('Energy')
      plt.ylabel('Number of frames')
      plt.title('Histogram of frame energies')
      plt.grid(True)

      try:
        plt.savefig("%s-%d.pdf" % (out_file, i), transparent=True, papertype='a4')
      except IOError as e:
        sys.stderr.write("%s: %s\n" % (sys.argv[0], e))
        sys.exit(1)

  # Add the statistics of this object to another object a
  # Typically used in a global object to accumulate stats
  # from local objects
  def add(self, a):
    for i in range(0,9):
      self.confusion_matrix[i] += a.confusion_matrix[i]
      self.state_count[i] += a.state_count[i]
      self.energies[i] += a.energies[i]

  # Print the confusion matrix
  # The interpretation of 'speech', 'noise' and 'silence' are bound to change
  # through the different post-processing stages. e.g at the end, speech and silence
  # correspond respectively to 'in segment' and 'out of segment'
  def write_confusion_matrix(self, write_hours = False, file_handle = sys.stderr):
    sys.stderr.write("Total counts: \n")

    name = ['Silence as silence', \
        'Silence as noise', \
        'Silence as speech', \
        'Noise as silence', \
        'Noise as noise', \
        'Noise as speech', \
        'Speech as silence', \
        'Speech as noise', \
        'Speech as speech']

    for j in range(0,9):
      if self.frame_shift != None:
        # The conventional usage is for frame_shift to have a value.
        # But this function can handle other counts like the number of frames.
        # This function is called to print in counts instead of seconds in
        # functions like merge_segments
        if write_hours:
          # Write stats in hours instead of seconds
          sys.stderr.write("File %s: %s : %s : %8.3f hrs\n" %
              (self.file_id, self.prefix, name[j],
                self.confusion_matrix[j] * self.frame_shift / 3600.0))
        else:
          sys.stderr.write("File %s: %s : %s : %8.3f seconds\n" %
              (self.file_id, self.prefix, name[j],
                self.confusion_matrix[j] * self.frame_shift))
        # End if write_hours
      else:
        sys.stderr.write("File %s: %s : Confusion: Type %d : %8.3f counts\n" %
            (self.file_id, self.prefix, j, self.confusion_matrix[j]))
      # End if
    # End for loop over 9 cells of confusion matrix

  # Print the total stats that are just row and column sums of
  # 3x3 confusion matrix
  def write_total_stats(self, write_hours = True, file_handle = sys.stderr):
    sys.stderr.write("Total Stats: \n")

    name = ['Actual Silence', \
        'Actual Noise', \
        'Actual Speech']

    for j in [0,1,2]:
      if self.frame_shift != None:
        # The conventional usage is for frame_shift to have a value.
        # But this function can handle other counts like the number of frames.
        # This function is called to print in counts instead of seconds in
        # functions like merge_segments
        if write_hours:
          # Write stats in hours instead of seconds
          sys.stderr.write("File %s: %s : %s : %8.3f hrs\n" %
              (self.file_id, self.prefix, name[j],
                sum(self.confusion_matrix[3*j:3*j+3]) * self.frame_shift / 3600.0))
        else:
          sys.stderr.write("File %s: %s : %s : %8.3f seconds\n" %
              (self.file_id, self.prefix, name[j],
                sum(self.confusion_matrix[3*j:3*j+3]) * self.frame_shift))
        # End if write_hours
      else:
        sys.stderr.write("File %s: %s : %s : %8.3f counts\n" %
            (self.file_id, self.prefix, name[j],
              sum(self.confusion_matrix[3*j:3*j+3])))
      # End if
    # End for loop over 3 rows of confusion matrix

    name = ['Predicted Silence', \
        'Predicted Noise', \
        'Predicted Speech']

    for j in [0,1,2]:
      if self.frame_shift != None:
        # The conventional usage is for frame_shift to have a value.
        # But this function can handle other counts like the number of frames.
        # This function is called to print in counts instead of seconds in
        # functions like merge_segments
        if write_hours:
          # Write stats in hours instead of seconds
          sys.stderr.write("File %s: %s : %s : %8.3f hrs\n" %
              (self.file_id, self.prefix, name[j],
                sum(self.confusion_matrix[j:7+j:3]) * self.frame_shift / 3600.0))
        else:
          sys.stderr.write("File %s: %s : %s : %8.3f seconds\n" %
              (self.file_id, self.prefix, name[j],
                sum(self.confusion_matrix[j:7+j:3]) * self.frame_shift))
        # End if write_hours
      else:
        sys.stderr.write("File %s: %s : %s : %8.3f counts\n" %
            (self.file_id, self.prefix, name[j],
              sum(self.confusion_matrix[j:7+j:3])))
      # End if
    # End for loop over 3 columns of confusion matrix

  # Print detailed stats of lengths of each of the 3 types of frames
  # in 8 kinds of segments
  def write_type_stats(self, file_handle = sys.stderr):
    for j in range(0,3):
      # 3 types of frames. Silence, noise, speech.
      # Typically, we store the number of frames of each type here.
      for i in range(0,9):
        # 2^3 = 8 kinds of segments like 'segment contains only silence',
        # 'segment contains only noise', 'segment contains noise and speech'.
        # For compatibility with the rest of the analysis code,
        # the for loop is over 9 kinds.
        max_length    = max([0]+self.type_counts[j][i])
        min_length    = min([10000]+self.type_counts[j][i])
        mean_length   = mean(self.type_counts[j][i])
        try:
          percentile25  = np.percentile(self.type_counts[j][i], 25)
        except ValueError:
          percentile25 = 0
        try:
          percentile50  = np.percentile(self.type_counts[j][i], 50)
        except ValueError:
          percentile50 = 0
        try:
          percentile75  = np.percentile(self.type_counts[j][i], 75)
        except ValueError:
          percentile75 = 0

        file_handle.write("File %s: %s : TypeStats: Type %d %d: Min: %4d Max: %4d Mean: %4d percentile25: %4d percentile50: %4d percentile75: %4d\n" % (self.file_id, self.prefix, j, i,  min_length, max_length, mean_length, percentile25, percentile50, percentile75))
      # End for loop over 9 different kinds of segments
    # End for loop over 3 types of frames

  # Print detailed stats of each cell of the confusion matrix.
  # The stats include different statistical measures like mean, max, min
  # and median of the length of continuous regions of frames in
  # each of the 9 cells of the confusion matrix
  def write_length_stats(self, file_handle = sys.stderr):
    for i in range(0,9):
      self.max_length[i]    = max([0]+self.state_count[i])
      self.min_length[i]    = min([10000]+self.state_count[i])
      self.mean_length[i]   = mean(self.state_count[i])
      try:
        self.percentile25[i]  = np.percentile(self.state_count[i], 25)
      except ValueError:
        self.percentile25[i] = 0
      try:
        self.percentile50[i]  = np.percentile(self.state_count[i], 50)
      except ValueError:
        self.percentile50[i] = 0
      try:
        self.percentile75[i]  = np.percentile(self.state_count[i], 75)
      except ValueError:
        self.percentile75[i] = 0

      file_handle.write("File %s: %s : Length: Type %d: Min: %4d Max: %4d Mean: %4d percentile25: %4d percentile50: %4d percentile75: %4d\n" % (self.file_id, self.prefix, i,  self.min_length[i], self.max_length[i], self.mean_length[i], self.percentile25[i], self.percentile50[i], self.percentile75[i]))
    # End for loop over 9 cells

  # Print detailed stats of each cell of the confusion matrix.
  # The stats include different statistical measures like mean, max, min
  # and median of the energies of continuous regions of frames in
  # each of the 9 cells of the confusion matrix
  def write_energy_stats(self, file_handle = sys.stderr):
    min_energy = [0] * 9
    max_energy = [0] * 9
    mean_energy = [0] * 9
    percentile25 = [0] * 9
    percentile50 = [0] * 9
    percentile75 = [0] * 9
    for i in range(0,9):
      if len(self.energies[i]) > 0:
        max_energy[i]    = max(self.energies[i])
        min_energy[i]    = min(self.energies[i])
        mean_energy[i]   = mean(self.energies[i])
        try:
          percentile25[i]  = np.percentile(self.energies[i], 25)
        except ValueError:
          percentile25[i] = 0
        try:
          percentile50[i]  = np.percentile(self.energies[i], 50)
        except ValueError:
          percentile50[i] = 0
        try:
          percentile75[i]  = np.percentile(self.energies[i], 75)
        except ValueError:
          percentile75[i] = 0

        file_handle.write("File %s: %s : Energy: Type %d: Min: %f Max: %f Mean: %f percentile25: %f percentile50: %f percentile75: %f\n" % (self.file_id, self.prefix, i,  min_energy[i], max_energy[i], mean_energy[i], percentile25[i], percentile50[i], percentile75[i]))
    # End for loop over 9 cells

  # Print detailed stats of each cell of the confusion matrix.
  # Similar structure to the above function. But this also prints additional
  # details. Format is like this -
  # Markers: Type <type>: <start_frame> (<num_of_frames>) (<hypothesized_phones>)
  # The hypothesized_phones can be looked at to see what phones are
  # present in the hypothesis from start_frame for num_of_frames frames.
  def write_markers(self, file_handle = sys.stderr):
    file_handle.write("Start frames of different segments:\n")
    for j in range(0,9):
      if self.markers[j] == []:
        continue
      if self.phones[j] == []:
        file_handle.write("File %s: %s : Markers: Type %d: %s\n" % (self.file_id, self.prefix, j,  str(sorted([str(self.markers[j][i])+' ('+ str(self.state_count[j][i])+ ')' for i in range(0, len(self.state_count[j]))],key=lambda x:int(x.split()[0])))))
      else:
        file_handle.write("File %s: %s : Markers: Type %d: %s\n" % (self.file_id, self.prefix, j,  str(sorted([str(self.markers[j][i])+' ('+ str(self.state_count[j][i])+') ( ' + str(self.phones[j][i]) + ')' for i in range(0, len(self.state_count[j]))],key=lambda x:int(x.split()[0])))))
    # End for loop over 9 cells

def read_rttm_file(rttm_file, temp_dir, frame_shift):
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
    start_time = int(float(splits[3])/frame_shift + 0.5)
    duration = int(float(splits[4])/frame_shift + 0.5)
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
  parser = ArgumentParser(description=textwrap.dedent('''\
      Analyse segmentation using RTTM file.

      This script takes in the predictions present in a prediction directory
      and an RTTM file in the Babel format. This script generates various
      statistics both per-file and aggregate.

      Statistics:
      1) Confusion Matrix: This shows the amount of data in seconds or hours
          that is confused between the classes Silence, Noise and Speech. It
          is a 3 x 3 matrix with true class and the predicted class as the
          row and column headers
      2) Length stats: This is a set of similar matrices as the confusion
          matrix but the elements consist of statistics like mean, median,
          min and max of contiguous regions of the confusion classes.
      3) Markers: This is a more detailed version of the length stats that
          in addition gives the starting position of the contiguous regions
          and also the predicted phones in those contiguous regions.
      4) Energy: Compute the C0 statistics corresponding to the confusion
          classes. This requires the C0 to be read from an archive'''), \
              formatter_class=argparse.RawDescriptionHelpFormatter)
  parser.add_argument('--write-per-phone-energy-stats', action='store_true', \
      help='Print energy stats of the difference phones')
  parser.add_argument('--write-energy-stats', action='store_true', \
      help='Print energy stats of the difference classes')
  parser.add_argument('--write-confusion-matrix', action='store_true', \
      help='Print confusion matrix')
  parser.add_argument('--write-length-stats', action='store_true', \
      help='Print length of the difference classes')
  parser.add_argument('--write-markers', action='store_true', \
      help='Print start markers of the difference classes')
  parser.add_argument('--plot-energy-histograms', action='store_true', \
      help='Plot energy histograms to file')
  parser.add_argument('--stat-threshold', type=float, default=0.0, \
      help="Do not include regions smaller than threshold while computing energy stats. (default: %(default)s)s")
  parser.add_argument('--frame-shift', type=float, \
      dest='frame_shift', default=0.01, \
      help="Time difference between adjacent frame (default: %(default)s)s")
  parser.add_argument('--energy-archive', \
      help='Kaldi archive file that has the C0 for each frame')
  parser.add_argument('rttm_file', help='Babel RTTM file in standard format')
  parser.add_argument('prediction_dir', help='Directory where the predictions \
      of the phone decoder can be found')
  parser.add_argument('phone_map', \
      help='Phone Map file that maps from phones to classes')
  parser.add_argument('temp_dir', help='A temporary directory to store the \
      segments classification based on an RTTM file')
  parser.add_argument('out_file', nargs='?', \
      help='Write stats to an output file')
  parser.usage=':'.join(parser.format_usage().split(':')[1:]) \
      + 'e.g. :  %(prog)s rttm.mitfa3rttm exp/tri4b_resegment_dev10h/pred \
exp/tri4b_resegment_dev10h/phone_map.txt exp/tri4b_resegment_dev10h/ref'
  options = parser.parse_args()

  os.system("mkdir -p " + options.temp_dir)

  # Read RTTM file and write the classes (Speech, Noise, Silence) to
  # separate files in temp_dir with file name as <file_id>.ref
  if options.rttm_file != "/dev/null":
    try:
      read_rttm_file(open(options.rttm_file), options.temp_dir, options.frame_shift)
    except IOError as e:
      sys.stderr.write("%s: %s: Unable to open %s\n" % \
          (sys.argv[0], e, options.rttm_file))
      sys.exit(1)

  phone_map = {}
  try:
    for line in open(options.phone_map).readlines():
      phone, cls = line.strip().split()
      phone_map[phone] = cls
  except IOError as e:
    repr(e)
    sys.exit(1)

  energies = None
  if options.energy_archive != None:
    try:
      energy_ark_handle = open(options.energy_archive)
    except IOError as e:
      sys.stderr.write("%s: %s: Unable to open %s\n" % \
          (sys.argv[0], e, options.energy_archive))
      sys.exit(1)

    energies = {}
    for line in energy_ark_handle.readlines():
      splits = line.strip().split()
      energies[splits[0]] = tuple([ float(x) for x in splits[2:-1] ])

  if options.rttm_file != "/dev/null":
    reference_dir = options.temp_dir
    reference = dict([ (f.split('/')[-1][0:-4], []) for f in glob.glob(reference_dir + "/*.ref") ])

  prediction = [ f.split('/')[-1][0:-5] for f in glob.glob(options.prediction_dir + "/*.pred") ]
  prediction.sort()

  global_analysis = Analysis("TOTAL", options.frame_shift)
  phone_energies = dict([(x,[]) for x in phone_map])

  # Analyse all the .pred files
  for file_id in prediction:
    # Open prediction file
    try:
      this_pred = open(options.prediction_dir+"/"+file_id+".pred").readline().strip().split()[1:]
    except IOError:
      sys.stderr.write("Unable to open " + prediction_dir+"/"+file_id+".pred\tSkipping utterance\n")
      continue

    # If there is not reference for the file_id skip it
    if options.rttm_file != "/dev/null":
      if file_id not in reference:
        sys.stderr.write(reference_dir+"/"+file_id+".ref not found\tSkipping utterance\n")
        continue

      # Open the reference classes file
      try:
        this_ref = open(reference_dir+"/"+file_id+".ref").readline().strip().split()[1:]
      except IOError:
        sys.stderr.write("Unable to open " + reference_dir+"/"+file_id+".ref\tSkipping utterance\n")
        continue
    else:
      this_ref = [ phone_map[x] for x in this_pred ]

    # Normalization. So that the every thing is of the same length
    this_len = len(this_pred)
    #if len(this_ref) > this_len:
    #  this_pred.extend(["SIL"]*(len(this_ref) - this_len))
    #  this_len = len(this_ref)
    if len(this_ref) < this_len:
      this_ref.extend(["0"]*(this_len - len(this_ref)))
      this_len = len(this_ref)
    else:
      this_ref = this_ref[0:this_len]

    # Create a new Analysis object to get the statistics
    C = ["0"] * this_len
    a = Analysis(file_id, options.frame_shift)

    count = 0
    for i in range(0,this_len):
      if energies != None:
        phone_energies[this_pred[i]].append(energies[file_id][i])
      if   this_ref[i] == "0" and phone_map[this_pred[i]] == "0":
        C[i] = "0"
      elif this_ref[i] == "0" and phone_map[this_pred[i]] == "1":
        C[i] = "1"
      elif this_ref[i] == "0" and phone_map[this_pred[i]] == "2":
        C[i] = "2"
      elif this_ref[i] == "1" and phone_map[this_pred[i]] == "0":
        C[i] = "3"
      elif this_ref[i] == "1" and phone_map[this_pred[i]] == "1":
        C[i] = "4"
      elif this_ref[i] == "1" and phone_map[this_pred[i]] == "2":
        C[i] = "5"
      elif this_ref[i] == "2" and phone_map[this_pred[i]] == "0":
        C[i] = "6"
      elif this_ref[i] == "2" and phone_map[this_pred[i]] == "1":
        C[i] = "7"
      elif this_ref[i] == "2" and phone_map[this_pred[i]] == "2":
        C[i] = "8"
      if i > 0 and C[i-1] != C[i]:
        a.state_count[int(C[i-1])].append(count)
        a.markers[int(C[i-1])].append(i - count)
        if energies != None:
          if count > options.stat_threshold / options.frame_shift:
            a.energies[int(C[i-1])].extend(energies[file_id][i-count:i])
          a.phones[int(C[i-1])].append(str(mean(energies[file_id][i-count:i])) + " " + ' '.join(set(this_pred[i-count:i])))
        else:
          a.phones[int(C[i-1])].append(' '.join(set(this_pred[i-count:i])))
        count = 1
      else:
        count += 1

    for j in range(0,9):
      a.confusion_matrix[j] = sum([C[i] == str(j) for i in range(0,len(C))])

    global_analysis.add(a)

    if options.write_energy_stats:
      a.write_energy_stats()
    if options.write_confusion_matrix:
      a.write_confusion_matrix()
    if options.write_length_stats:
      a.write_length_stats()
    if options.write_markers:
      a.write_markers()

  if options.write_energy_stats:
    global_analysis.write_energy_stats()
  if options.write_confusion_matrix:
    global_analysis.write_confusion_matrix(True)
  if options.write_length_stats:
    global_analysis.write_length_stats()
  if options.write_markers:
    global_analysis.write_markers()
  if options.write_per_phone_energy_stats:
    for phone, energies in phone_energies.items():
      if len(energies) == 0:
        continue
      print("%s %f %f %f %f %f %f" % (phone, min(energies), max(energies), mean(energies), np.percentile(energies, 25), np.percentile(energies, 50), np.percentile(energies, 75)))
  if options.plot_energy_histograms and options.out_file:
    global_analysis.plot_energy_histograms(options.out_file)

if __name__ == '__main__':
  main()

