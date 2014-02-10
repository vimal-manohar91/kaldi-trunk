// gmmbin/gmm-classify-on-likes.cc

// Copyright 2013-2014  (Author: Vimal Manohar)

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
#include "gmm/am-diag-gmm.h"
#include "hmm/transition-model.h"
#include "fstext/fstext-lib.h"
#include "util/timer.h"

int main(int argc, char *argv[]) {
  try {
    using namespace kaldi;
    typedef kaldi::int32 int32;
    using fst::SymbolTable;
    using fst::VectorFst;
    using fst::StdArc;

    const char *usage =
        "Do frame classification based on the pdf in a GMM-based model \n"
        "that has the highest log-likelihood for the corresponding frame.\n"
        "and outputs per-frame pdf-alignment"
        "Usage: gmm-classify-on-likes [options] model-in features-rspecifier ali-wspecifier\n";

    BaseFloat scale = 1.0;
    std::string phones_string = "";

    ParseOptions po(usage);
    po.Register("scale", &scale, "Factor by which to scale silence likelihoods");
    po.Register("phones-list", &phones_string, "If this option is given, only the likelihoods of these phones will be scaled");
    
    po.Read(argc, argv);

    if (po.NumArgs() != 3) {
      po.PrintUsage();
      exit(1);
    }

    std::string model_in_filename = po.GetArg(1),
        feature_rspecifier = po.GetArg(2),
        ali_wspecifier = po.GetArg(3);
    
    AmDiagGmm am_gmm;
    TransitionModel trans_model;
    {
      bool binary;
      Input ki(model_in_filename, &binary);
      trans_model.Read(ki.Stream(), binary);
      am_gmm.Read(ki.Stream(), binary);
    }

    KALDI_ASSERT(am_gmm.NumPdfs() >= 0);

    std::vector<int32> phones;
    std::vector<int32> pdfs;
    
    if (phones_string != "") {
      SplitStringToIntegers(phones_string, ":", false, &phones);
      std::sort(phones.begin(), phones.end());
      KALDI_ASSERT(IsSortedAndUniq(phones) && "Phones in list non-unique.");
      bool ans = GetPdfsForPhones(trans_model, phones, &pdfs);
      if (!ans) {
        KALDI_WARN << "The pdfs for the phones may be shared by other phones "
          << "(note: this probably does not matter.)";
      }
    } else {
      KALDI_WARN << "gmm-classify-on-likes: no phones specified, no scaling done.";
    }

    SequentialBaseFloatMatrixReader feature_reader(feature_rspecifier);
    Int32VectorWriter alignments_writer(ali_wspecifier);

    int32 num_done = 0;
    for (; !feature_reader.Done(); feature_reader.Next()) {
      std::string key = feature_reader.Key();
      const Matrix<BaseFloat> &features (feature_reader.Value());
      std::vector<int32> alignment(features.NumRows());
      for (int32 i = 0; i < features.NumRows(); i++) {
        SubVector<BaseFloat> feat_row(features, i);
        BaseFloat max_loglike = am_gmm.LogLikelihood(0, feat_row);
        int32 k = 0;
        if (0 < pdfs.size() && pdfs[0] == 0) {
          max_loglike = max_loglike + log(scale);
        }
        alignment[i] = 0;
        for (int32 j = 1; j < am_gmm.NumPdfs(); j++) {
          for (; k < pdfs.size() && pdfs[k] < j; k++);
          BaseFloat loglike = am_gmm.LogLikelihood(j, feat_row);
          if (k < pdfs.size() && pdfs[k] == j) {
            loglike += log(scale);
          }
          if (loglike > max_loglike) {
            max_loglike = loglike;
            alignment[i] = j;
          }
        }
      }
      alignments_writer.Write(key, alignment);
      num_done++;
    }
    
    KALDI_LOG << "gmm-classify-on-likes: classified frames in " << num_done
      << " utterances based on likelihoods.";
    return 0;
  } catch(const std::exception &e) {
    std::cerr << e.what();
    return -1;
  }
}



