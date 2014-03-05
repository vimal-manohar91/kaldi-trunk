#!/bin/bash

set -o pipefail
set -u 
################################################################################
# Run Pascal Clark's voice activity detection on all *.sph files in a directory.
#
# Requires:
#
#    1. matlab to be in the default path of the invoking shell
#    2. permission to read all the .m files in /home/clarkcp/VAD/modvad
#    3. the NIST sph2pipe executable to be in the default path.
#
# The following variables can be set from the command line if parse_options.sh
# is present in the default path of the invoking shell
#
WorkDir=".";
OutputDir=".";
nj="1";
#
# This scrpt creates:
#    1. temporary *.wav files in $WorkDir, removed before exiting
#    2. VAD files in $OutputDir, one per *.sph file in $InputDir
#
################################################################################

export PATH=$PATH:/home/vmanoha1/tools/modvad
echo $*

. path.sh
. parse_options.sh

if [ $# -ne 1 ]; then
  echo "Usage: $0 [options] SCPFile";
  echo "        --nj <N>          (number of parallel jobs; default 1)";
  echo "        --WorkDir <dir>   (scratch space; default current dir)";
  echo "        --OutputDir <dir> (default current dir)";
  exit 1;
fi
SCPFile=$1

mkdir -p $WorkDir
mkdir -p $OutputDir

cat $SCPFile | awk '{y=$2; for (i=3;i<NF;i++) {y=y" "$i}; print y" > '$WorkDir'/"$1".wav"}' | bash -e || exit 1

ls $WorkDir/*.wav > $WorkDir/wavFileList || exit 1
nFiles=`cat $WorkDir/wavFileList | wc -l`
echo "$0: $nFiles wav files created in $WorkDir"
if [ $nj -gt 1 ]; then
  perSplit=$[ $nFiles/$nj ]
  if [ $[ $nFiles - $nj*$perSplit ] -gt 0 ]; then perSplit=$[ $perSplit + 1 ]; fi
  split -a 1 -l $perSplit -d $WorkDir/wavFileList $WorkDir/wavFileList.
else
  perSplit=$nFiles
fi
echo "$0: Launching $nj parallel jobs (~ $perSplit files per job)"
fileLists=$WorkDir/wavFileList.*

ModVad=`which modvad.py 2>/dev/null`
[ -z $ModVad ] && exit 1
python $ModVad -l $WorkDir/wavFileList -d $OutputDir || exit 1

exit 0

if [ $nj -gt 1 ]; then
  mv $WorkDir/wavFileList.0 $WorkDir/wavFileList.$nj || exit 1
  queue.pl JOB=1:$nj $WorkDir/log/modvad.JOB.log python $ModVad -l $WorkDir/wavFileList.JOB -d $OutputDir || exit 1
else
  run.pl $WorkDir/log/modvad.log python $ModVad -l $WorkDir/wavFileList -d $OutputDir || exit 1
fi
