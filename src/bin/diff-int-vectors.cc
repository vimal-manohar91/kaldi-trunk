// bin/diff-int-vectors.cc

// Copyright 2009-2011  Microsoft Corporation

// See ../../COPYING for clarification regarding multiple authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
// THIS CODE IS PROVIDED *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
// WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
// MERCHANTABLITY OR NON-INFRINGEMENT.
// See the Apache 2 License for the specific language governing permissions and
// limitations under the License.

#include "base/kaldi-common.h"
#include "util/common-utils.h"
#include "matrix/kaldi-vector.h"
#include "transform/transform-common.h"


int main(int argc, char *argv[]) {
  try {
    using namespace kaldi;

    const char *usage =
        "Finds the fraction of integers different in two integer vectors\n"
        "(e.g. alignments)\n"
        "\n"
        "Usage: diff-int-vector [options] vector-in-rspecifier1 vector-in-rspecifier2 float-wspecifier)\n"
        "   e.g: copy-int-vector ark:1.ali ark:1.ref ark,t:-\n";
    
    ParseOptions po(usage);

    po.Read(argc, argv);

    if (po.NumArgs() != 3) {
      po.PrintUsage();
      exit(1);
    }

    std::string vector_in_fn1 = po.GetArg(1),
        vector_in_fn2 = po.GetArg(2),
        float_wspecifier = po.GetArg(3);

    int num_done = 0, num_mismatch = 0, num_missing = 0;
    
    BaseFloatWriter writer(float_wspecifier);
    SequentialInt32VectorReader reader1(vector_in_fn1);
    RandomAccessInt32VectorReader reader2(vector_in_fn2);

    for (; !reader1.Done(); reader1.Next(), num_done++) {
      std::string key = reader1.Key();
      std::vector<int32> vector1 = reader1.Value();
      if (!reader2.HasKey(key)) {
        num_missing++;
        continue;
      }
      std::vector<int32> vector2 = reader2.Value(key);
      if (vector1.size() != vector2.size()) {
        num_mismatch++;
        continue;
      }
      int32 size = static_cast<int32> (vector1.size());
      int32 score = 0.0;
      for (int32 i = 0; i < size; i++) {
        score += (vector1[i] == vector2[i] ? 1 : 0);
      }
      writer.Write(key, static_cast<BaseFloat>(score) / static_cast<BaseFloat>(size));
    }
    KALDI_LOG << "Diff" << num_done << " vectors of int32, missing " << num_missing 
      << "keys, mismatch in " << num_mismatch << "vectors";
    return (num_done != 0 ? 0 : 1);
  } catch(const std::exception &e) {
    std::cerr << e.what();
    return -1;
  }
}

