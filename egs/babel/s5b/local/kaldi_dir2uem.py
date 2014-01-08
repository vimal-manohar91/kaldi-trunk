#! /usr/bin/python

import argparse, sys
from argparse import ArgumentParser

def main():
  parser = ArgumentParser(description='Convert kaldi data directory to uem dat files')
  parser.add_argument('--verbose', type=int, \
      dest='verbose', default=0, \
      help='Give higher verbose for more logging')
  parser.add_argument('kaldi_dir', \
      help='Kaldi data directory')
  parser.add_argument('output_dir', \
      help='Directory to store uem dat files')
  options = parser.parse_args()

  segments_file = open(options.kaldi_dir+'/segments', 'r')
  spk_map = {}

  prefix = options.kaldi_dir.split('/')[-1].split('.')[0]

  utt_dat = open(options.output_dir+'/db-'+prefix+'-utt.dat', 'w')
  spk_dat = open(options.output_dir+'/db-'+prefix+'-spk.dat', 'w')

  for line in segments_file.readlines():
    utt_id, file_id, start, end = line.strip().split()

    utt_dat.write("{UTTID %s} {UTT %s} {SPK %s} {FROM %s} {TO %s} {TEXT }\n" % (utt_id, utt_id, file_id, start, end))
    spk_map.setdefault(file_id, [])
    spk_map[file_id].append(utt_id)

  for spk, utts in spk_map.items():
    spk_dat.write("{SEGS %s} {ADC %s.pcm} {CONV %s.wav} {CHANNEL 1} {DUR }\n" % (' '.join(utts), spk, spk))

  segments_file.close()
  utt_dat.close()
  spk_dat.close()

if __name__ == '__main__':
  main()
