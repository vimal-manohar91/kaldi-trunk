#! /usr/bin/python

import os, glob, argparse, sys, re, time
from argparse import ArgumentParser

class Timer:
  def __enter__(self):
    self.start = time.clock()
    return self
  def __exit__(self, *args):
    self.end = time.clock()
    self.interval = self.end - self.start

class JointResegmenter:
  def __init__(self, A, f, options):
    self.B = [ i for i in A ]
    self.A = A
    self.file_id = f
    self.N = len(A)
    self.S = [False] * self.N
    self.E = [False] * (self.N+1)

    self.options = options

    self.max_frames = int(options.max_segment_length / options.frame_shift)
    self.hard_max_frames = int(options.hard_max_segment_length / options.frame_shift)
    self.frame_shift = options.frame_shift

    self.THIS_SILENCE = ("0","1","2")
    self.THIS_SPEECH = ("6", "7", "8")
    self.THIS_SPEECH_THAT_SIL = ("6",)
    self.THIS_SPEECH_THAT_NOISE = ("7",)
    self.THIS_NOISE_THAT_SIL = ("3",)
    self.THIS_NOISE_THAT_NOISE = ("4",)
    self.THIS_SIL_THAT_SIL = ("9",)
    self.THIS_SIL_THAT_NOISE = ("10",)
    self.THIS_SILENCE_CONVERT = ("9","10","11")
    self.THIS_SILENCE_PLUS = self.THIS_SILENCE + self.THIS_SILENCE_CONVERT

  def restrict(self, N):
    self.B = self.B[0:N]
    self.A = self.A[0:N]
    self.S = self.S[0:N]
    self.E = self.E[0:N+1]
    if sum(self.S) == sum(self.E) + 1:
      self.E[N] = True
    self.N = N

  def resegment(self):
    with Timer() as t:
      self.get_initial_segments()
    sys.stderr.write("get_initial_segments took %f sec\n" % t.interval)
    with Timer() as t:
      self.set_silence_proportion()
    sys.stderr.write("set_silence_proportion took %f sec\n" % t.interval)
    with Timer() as t:
      self.merge_segments()
    sys.stderr.write("merge took %f sec\n" % t.interval)
    with Timer() as t:
      self.split_long_segments()
    sys.stderr.write("split took %f sec\n" % t.interval)
    with Timer() as t:
      self.remove_noise_only_segments()
    sys.stderr.write("remove took %f sec\n" % t.interval)

  def get_initial_segments(self):
    for i in range(0, self.N):
      if (i > 0) and self.A[i-1] != self.A[i]:
        # This frame is different from the previous frame.
        if self.A[i] not in self.THIS_SILENCE:
          # This frame is non-silence.
          if self.A[i-1] not in self.THIS_SILENCE:
            # Both this and the previous frames are not silence.
            # But they are different. e.g. "4 5"
            # So this is the end of the previous region and
            # the beginning of the next region
            self.S[i] = True
            self.E[i] = True
          else:
            # The previous frame is silence, but not this one.
            # So this frame is the beginning of a new segment
            self.S[i] = True
        else:
          # This frame is silence
          if self.A[i-1] not in self.THIS_SILENCE:
            # Previous frame is not silence, but this one is.
            # So this frame is the end of the previous segment
            self.E[i] = True
      elif i == 0 and self.A[i] not in self.THIS_SILENCE:
        # The frame is non-silence. So this is the start of a new segment.
        self.S[i] = True
    if self.A[self.N-1] not in self.THIS_SILENCE:
      # Handle the special case where the last frame of file is not silence
      self.E[self.N] = True
    assert(sum(self.S) == sum(self.E))

  def set_silence_proportion(self):
    num_nonsil_frames = 0
    in_segment = False

    active_frames = []
    for n in range(0, self.N + 1):
      if self.E[n]:
        assert(in_segment)
        in_segment = False
        active_frames.append(n)
      if n < self.N and self.S[n]:
        assert(not in_segment)
        in_segment = True
        active_frames.append(n)
      if n < self.N:
        if in_segment:
          num_nonsil_frames += 1
    assert (not in_segment)
    if num_nonsil_frames == 0:
      sys.stderr.write("%s: Warning: no segments found for recording %s\n" % (sys.argv[0], self.file_id))

    target_segment_frames = int(num_nonsil_frames / (1.0 - self.options.silence_proportion))

    num_segment_frames = num_nonsil_frames
    while num_segment_frames < target_segment_frames:
      changed = False
      for i in range(0, len(active_frames)):
        n = active_frames[i]
        if self.E[n] and n < self.N and not self.S[n]:
          # This must be the beginning of a silence region.
          # Include some of this silence in the segments
          assert (self.A[n] in self.THIS_SILENCE)
          self.A[n] = str(int(self.B[n]) + 9)
          if self.B[n-1] != self.B[n]:
            self.S[n] = True
            active_frames.append(n+1)
          else:
            self.E[n] = False
            active_frames[i] = n + 1
          self.E[n+1] = True
          num_segment_frames += 1
          changed = True
        if n < self.N and self.S[n] and n > 0 and not self.E[n]:
          assert (self.A[n-1] in self.THIS_SILENCE)
          self.A[n-1] = str(int(self.B[n-1]) + 9)
          if self.B[n-1] != self.B[n]:
            self.E[n] = True
            active_frames.append(n-1)
          else:
            self.S[n] = False
            active_frames[i] = n - 1
          self.S[n-1] = True
          num_segment_frames += 1
          changed = True
        if num_segment_frames >= target_segment_frames:
          break
      if not changed:   # avoid an infinite loop
        break
    if num_segment_frames < target_segment_frames:
      proportion = float(num_segment_frames - num_nonsil_frames) / num_segment_frames
      sys.stderr.write("%s: Warning: for recording %s, only got a proportion %f of silence frames, versus target %f\n" % (sys.argv[0], self.file_id, proportion, self.options.silence_proportion))

  def set_silence_proportion_slow(self):
    n = 0
    while n < self.N:
      if n > 0 and self.S[n] and self.A[n-1] in self.THIS_SILENCE:
        assert (not self.E[n])
        num_nonsil_frames = 0
        while n + num_nonsil_frames < self.N and self.B[n+num_nonsil_frames] not in self.THIS_SILENCE:
          # Count the number of non-silence frames to
          # the right of the start segment
          num_nonsil_frames += 1

        target_left_frames = int(num_nonsil_frames / (1 - self.options.silence_proportion) / 2)
        num_left_frames = 0
        if n > 0:
          self.E[n] = True
        p = n - 1
        while p > 0 and self.A[p] in self.THIS_SILENCE:
          # Convert each silence frame to a new type of
          # silence frame that can be appended to the
          # speech segment
          if p < n - 1 and self.B[p] != self.B[p+1]:
            self.S[p+1] = True
            self.E[p+1] = True
          self.A[p] = str(int(self.B[p]) + 9)
          num_left_frames += 1
          p -= 1
          if num_left_frames >= target_left_frames:
            break
        # if A[p]==A[p-1] S=E=False
        self.S[p+1] = True
        n += num_nonsil_frames
      assert(sum(self.S) == sum(self.E))
      if n < self.N and self.E[n] and self.A[n] in self.THIS_SILENCE:
        assert (not self.S[n])
        num_nonsil_frames = 0
        while self.B[n-1-num_nonsil_frames] not in self.THIS_SILENCE:
          # Count the number of non-silence frames to
          # the left of the start segment
          num_nonsil_frames += 1
        target_right_frames = int(num_nonsil_frames / (1 - self.options.silence_proportion) / 2)
        num_right_frames = 0
        self.S[n] = True
        p = n
        while p < self.N and self.A[p] in self.THIS_SILENCE:
          # Convert each silence frame to a new type of
          # silence frame that can be appended to the
          # speech segment
          if p > n and self.B[p] != self.B[p-1]:
            self.S[p] = True
            self.E[p] = True
          self.A[p] = str(int(self.B[p]) + 9)
          num_right_frames += 1
          p += 1
          if num_right_frames >= target_right_frames:
            break
        self.E[p] = True
        if p < self.N and self.S[p]:
          n = p - 1
        else:
          n = p
      assert(sum(self.S) == sum(self.E))
      n += 1
    assert(sum(self.S) == sum(self.E))

  def merge_segments(self):
    segment_starts = [i for i, val in enumerate(self.S) if val]
    segment_ends = [i for i, val in enumerate(self.E) if val]
    assert (len(segment_starts) == len(segment_ends))

    boundaries = []
    i = 0
    j = 0
    while i < len(segment_starts) and j < len(segment_ends):
      if segment_ends[j] < segment_starts[i]:
        j += 1
      elif segment_ends[j] > segment_starts[i]:
        i += 1
      else:
        segment_score = min(segment_starts[i] - segment_starts[i-1], segment_ends[j+1] - segment_ends[j])
        boundaries.append((segment_ends[j], segment_score, self.transition_type(segment_ends[j])))
        boundaries.sort(key = lambda x: x[1])
        boundaries.sort(key = lambda x: x[2])
        i += 1
        j += 1

    for b in boundaries:
      segment_length = 0

      p = b[0] - 1
      while p >= 0:
        if self.S[p]:
          break
        p -= 1
      segment_length += b[0] - p

      p = b[0] + 1
      while p <= self.N:
        if self.E[p]:
          break
        p += 1
      segment_length += p - b[0]

      if segment_length < self.max_frames:
        self.S[b[0]] = False
        self.E[b[0]] = False

  def split_long_segments(self):
    for n in range(0, self.N):
      if self.S[n]:
        p = n + 1
        while p <= self.N:
          if self.E[p]:
            break
          p += 1
        segment_length = p - n
        if segment_length > self.hard_max_frames:
          num_pieces = int((float(segment_length) / self.hard_max_frames) + 0.99999)
          sys.stderr.write("%s: Warning: for recording %s, " \
              % (sys.argv[0], self.file_id) \
              + "splitting segment of length %f seconds into %d pieces " \
              % (segment_length * self.frame_shift, num_pieces) \
              + "(--hard-max-segment-length %f)\n" \
              % self.options.hard_max_segment_length)
          frames_per_piece = int(segment_length / num_pieces)
          for i in range(1,num_pieces):
            q = n + i * frames_per_piece
            self.S[q] = True
            self.E[q] = True
        if p - 1 > n:
          n = p - 1

  def remove_noise_only_segments(self):
    for n in range(0, self.N):
      if self.S[n]:
        p = n
        saw_speech = False
        while p <= self.N:
          if self.E[p] and p != n:
            break
          if self.A[p] in self.THIS_SPEECH:
            saw_speech = True
          p += 1
        assert (self.E[p])
        if not saw_speech:
          self.S[n] = False
          self.E[p] = False
        if p - 1 > n:
          n = p - 1

  def transition_type(self, j):
    assert (j > 0)
    assert (self.A[j-1] != self.A[j] or self.A[j] in self.THIS_SILENCE_CONVERT)
    if self.A[j-1] in (self.THIS_SPEECH_THAT_NOISE + self.THIS_SPEECH_THAT_SIL) and self.A[j] in (self.THIS_SPEECH_THAT_NOISE + self.THIS_SPEECH_THAT_SIL):
      return 0
    if self.A[j-1] in self.THIS_SPEECH and self.A[j] in self.THIS_SPEECH:
      return 1
    if self.A[j-1] in (self.THIS_SPEECH + self.THIS_NOISE_THAT_SIL) and self.A[j] in (self.THIS_SPEECH + self.THIS_NOISE_THAT_SIL):
      return 2
    if self.A[j-1] in (self.THIS_SPEECH + self.THIS_NOISE_THAT_SIL + self.THIS_NOISE_THAT_NOISE) and self.A[j] in (self.THIS_SPEECH + self.THIS_NOISE_THAT_SIL + self.THIS_NOISE_THAT_NOISE):
      return 3
    if self.A[j-1] in (self.THIS_SPEECH + self.THIS_NOISE_THAT_SIL + self.THIS_NOISE_THAT_NOISE + self.THIS_SIL_THAT_SIL + self.THIS_SIL_THAT_NOISE) and self.A[j] in (self.THIS_SPEECH + self.THIS_NOISE_THAT_SIL + self.THIS_NOISE_THAT_NOISE + self.THIS_SIL_THAT_SIL + self.THIS_SIL_THAT_NOISE):
      return 4
    assert ( self.A[j-1] not in self.THIS_SILENCE and self.A[j] not in self.THIS_SILENCE )
    return 5

  def print_segments(self, out_file_handle = sys.stdout):
    # We also do some sanity checking here.
    segments = []

    assert (self.N == len(self.S))
    assert (self.N + 1 == len(self.E))

    max_end_time = 0
    n = 0
    while n < self.N:
      if self.E[n] and not self.S[n]:
        sys.stderr.write("%s: Error: Ending segment before starting it: n=%d\n" % (sys.argv[0], n))
      if self.S[n]:
        p = n + 1
        while p < self.N and not self.E[p]:
          assert (not self.S[p])
          p += 1
        assert (self.E[p])
        segments.append((n,p))
        max_end_time = p
        if p < self.N and self.S[p]:
          n = p - 1
        else:
          n = p
      n += 1
    if len(segments) == 0:
      sys.stderr.write("%s: Warning: no segments for recording %s\n" % (sys.argv[0], self.file_id))
      sys.exit(1)

    # we'll be printing the times out in hundredths of a second (regardless of the
    # value of $frame_shift), and first need to know how many digits we need (we'll be
    # printing with "%05d" or similar, for zero-padding.
    max_end_time_hundredths_second = int(100.0 * self.frame_shift * max_end_time)
    num_digits = 1
    i = 1
    while i < max_end_time_hundredths_second:
      i *= 10
      num_digits += 1
    format_str = r"%0" + "%d" % num_digits + "d" # e.g. "%05d"

    for start, end in segments:
      assert (end > start)
      start_seconds = "%.2f" % (self.frame_shift * start)
      end_seconds = "%.2f" % (self.frame_shift * end)
      start_str = format_str % (start * self.frame_shift * 100.0)
      end_str = format_str % (end * self.frame_shift * 100.0)
      utterance_id = "%s%s%s%s%s" % (self.file_id, self.options.first_separator, start_str, self.options.second_separator, end_str)
      # Output:
      out_file_handle.write("%s %s %s %s\n" % (utterance_id, self.file_id, start_seconds, end_seconds))

def main():
  parser = ArgumentParser(description='Get segmentation arguments')
  parser.add_argument('--silence-proportion', type=float, \
      dest='silence_proportion', default=0.2, \
      help="The amount of silence at the sides of segments is " \
      + "tuned to give this proportion of silence.")
  parser.add_argument('--frame-shift', type=float, \
      dest='frame_shift', default=0.01, \
      help="Time difference between adjacent frames")
  parser.add_argument('--max-segment-length', type=float, \
      dest='max_segment_length', default=10.0, \
      help="Maximum segment length while we are marging segments")
  parser.add_argument('--hard-max-segment-length', type=float, \
      dest='hard_max_segment_length', default=10.0, \
      help="Hard maximum on the segment length above which the segment " \
      + "will be broken even if in the middle of speech")
  parser.add_argument('--first-separator', type=str, \
      dest='first_separator', default="-", \
      help="Separator between recording-id and start-time")
  parser.add_argument('--second-separator', type=str, \
      dest='second_separator', default="-", \
      help="Separator between start-time and end-time")
  parser.add_argument('--remove-noise-only-segments', type=str, \
      dest='remove_noise_only_segments', default="true", \
      help="Remove segments that have only noise.")
  parser.add_argument('--min-inter-utt-silence-length', type=float, \
      dest='min_inter_utt_silence_length', default=1.0, \
      help="Minimum silence that must exist between two separate utterances");
  parser.add_argument('--channel1-file', type=str, \
      dest='channel1_file', default="inLine", \
      help="String that matches with the channel 1 file")
  parser.add_argument('--channel2-file', type=str, \
      dest='channel2_file', default="outLine", \
      help="String that matches with the channel 2 file")
  parser.add_argument('args', nargs=1, help='<prediction_dir>')
  options = parser.parse_args()

  if not ( options.silence_proportion > 0.01 and options.silence_proportion < 0.99 ):
    sys.stderr.write("Invalid silence-proportion value %f\n" % silence_proportion)
    sys.exit(1)

  prediction_dir = options.args[0]
  channel1_file = options.channel1_file
  channel2_file = options.channel2_file

  pred_files = dict([ (f.split('/')[-1][0:-5], False) for f in glob.glob(os.path.join(prediction_dir, "*.pred")) ])
  for f in pred_files:
    if pred_files[f]:
      continue
    if re.match(".*_"+channel1_file, f) is None:
      if re.match(".*_"+channel2_file, f) is None:
        sys.stderr.write("%s does not match pattern .*_%s or .*_%s\n" % (f,channel1_file, channel2_file))
        sys.exit(1)
      else:
        f1 = f
        f2 = f
        f1 = re.sub("(.*_)"+channel2_file, r"\1"+channel1_file, f1)
    else:
      f1 = f
      f2 = f
      f2 = re.sub("(.*_)"+channel1_file, r"\1"+channel2_file, f2)

    if f2 not in pred_files or f1 not in pred_files:
      pred_files[f] = True
      try:
        A = open(os.path.join(prediction_dir, f+".pred")).readline().strip().split()[1:]
      except IndexError:
        sys.stderr.write("Incorrect format of file %s/%s.pred\n" % (prediction_dir, f))
        sys.exit(1)
      B = []
      for i in A:
        if i == "0":
          B.append("0")
        elif i == "1":
          B.append("4")
        elif i == "2":
          B.append("8")

      r = JointResegmenter(B, f, options)
      r.resegment()
      r.print_segments()
    else:
      if pred_files[f1] and pred_files[f2]:
        continue
      pred_files[f1] = True
      pred_files[f2] = True
      try:
        A1 = open(os.path.join(prediction_dir, f1+".pred")).readline().strip().split()[1:]
      except IndexError:
        sys.stderr.write("Incorrect format of file %s/%s.pred\n" % (prediction_dir, f1))
        sys.exit(1)
      try:
        A2 = open(os.path.join(prediction_dir, f2+".pred")).readline().strip().split()[1:]
      except IndexError:
        sys.stderr.write("Incorrect format of file %s/%s.pred\n" % (prediction_dir, f2))
        sys.exit(1)

      if len(A1) < len(A2):
        A3 = A1
        A1 = A2
        A2 = A3

        f3 = f1
        f1 = f2
        f2 = f3

      B1 = []
      B2 = []
      if (len(A1) - len(A2)) > 40:
        sys.stderr.write("Lengths of %s and %s differ by more than 0.4s. So using isolated resegmentation\n" % (f1,f2))
        for i in A1:
          if i == "0":
            B1.append("0")
          elif i == "1":
            B1.append("4")
          elif i == "2":
            B1.append("8")
        for i in A2:
          if i == "0":
            B2.append("0")
          elif i == "1":
            B2.append("4")
          elif i == "2":
            B2.append("8")
      else:
        for i in range(0, len(A2)):
          if A1[i] == "0" and A2[i] == "0":
            B1.append("0")
            B2.append("0")
          if A1[i] == "0" and A2[i] == "1":
            B1.append("1")
            B2.append("3")
          if A1[i] == "0" and A2[i] == "2":
            B1.append("2")
            B2.append("6")
          if A1[i] == "1" and A2[i] == "0":
            B1.append("3")
            B2.append("1")
          if A1[i] == "1" and A2[i] == "1":
            B1.append("4")
            B2.append("4")
          if A1[i] == "1" and A2[i] == "2":
            B1.append("5")
            B2.append("7")
          if A1[i] == "2" and A2[i] == "0":
            B1.append("6")
            B2.append("2")
          if A1[i] == "2" and A2[i] == "1":
            B1.append("7")
            B2.append("5")
          if A1[i] == "2" and A2[i] == "2":
            B1.append("8")
            B2.append("8")
        for i in range(len(A2), len(A1)):
          if A1[i] == "0":
            B1.append("0")
            B2.append("0")
          if A1[i] == "1":
            B1.append("3")
            B2.append("1")
          if A1[i] == "2":
            B1.append("6")
            B2.append("2")

        r1 = JointResegmenter(B1, f1, options)
        r1.resegment()
        r1.print_segments()

        r2 = JointResegmenter(B2, f2, options)
        r2.resegment()
        r2.restrict(len(A2))
        r2.print_segments()

if __name__ == '__main__':
  main()

