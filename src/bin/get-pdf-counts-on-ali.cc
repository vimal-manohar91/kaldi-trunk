// bin/get-pdf-counts-on-ali.cc

// Copyright 2014  Vimal Manohar

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
        "Read a pdf alignment and get counts of each pdf type.\n"
        "\n"
        "Usage: get-pdf-counts-on-ali [options] ali-in-rspecifier [weights-rspecifier] counts-out-wspecifier\n"
        " e.g.: get-pdf-counts-on-ali ark:1.ali ark:1.weights ark:1.counts\n";

    ParseOptions po(usage);
    
    BaseFloat weight_threshold = 0.0;

    po.Register("weight-threshold", &weight_threshold, "Weight threshold. Used only if weights are given. Selects only frames that are above this threshold.");

    po.Read(argc, argv);

    if (po.NumArgs() < 2 || po.NumArgs() > 3) {
      po.PrintUsage();
      exit(1);
    }

    int32 num_args = po.NumArgs();

    std::string ali_rspecifier = po.GetArg(1),
        counts_wspecifier = po.GetArg(num_args);
    
    std::string weights_rspecifier = po.GetArg(2);
    if (num_args == 2)
      weights_rspecifier = "";

    SequentialInt32VectorReader ali_reader(ali_rspecifier);
    RandomAccessBaseFloatVectorReader weights_reader(weights_rspecifier);
    Int32VectorWriter counts_writer(counts_wspecifier);
    std::vector<int32> counts;

    for (; !ali_reader.Done(); ali_reader.Next()) {
      std::string key = ali_reader.Key();
      std::vector<int32> alignment = ali_reader.Value();
      ali_reader.FreeCurrent();

      Vector<BaseFloat> weights(alignment.size());
      if (!weights_rspecifier.empty() && weights_reader.HasKey(key)) {
        weights.CopyFromVec(weights_reader.Value(key));
      } else {
        weights.Set(1.0);
      }
      for (int32 j = 0; j < alignment.size(); j++) {
        while(counts.size() <= alignment[j]) {
          counts.push_back(0);
        }
        if (weights(j) > weight_threshold) {
          counts[alignment[j]]++;
        }
      }
    }
    counts_writer.Write("Counts", counts);
  } catch(const std::exception &e) {
    std::cerr << e.what();
    return -1;
  }
}
