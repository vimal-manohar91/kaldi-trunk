// nnet2bin/nnet-set-priors.cc

// Copyright 2014   Vimal Manohar

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
#include "hmm/transition-model.h"
#include "nnet2/am-nnet.h"

int main(int argc, char *argv[]) {
  try {
    using namespace kaldi;
    using namespace kaldi::nnet2;
    typedef kaldi::int32 int32;

    const char *usage =
        "Set priors of a neural network acoustic model\n"
        "\n"
        "Usage:  nnet-set-priors [options] <nnet-in> <counts_rxfilename> <nnet-out>\n"
        "e.g.:\n"
        " nnet-set-priors 1.nnet pdf_counts 2.nnet\n";

    bool binary_write = true;
    BaseFloat prior_floor = 5.0e-06; // The default was previously 1e-8, but
                                     // once we had problems with a pdf-id that
                                     // was not being seen in training, being
                                     // recognized all the time.  This value
                                     // seemed to be the smallest prior of the
                                     // "seen" pdf-ids in one run.

    ParseOptions po(usage);
    po.Register("binary", &binary_write, "Write output in binary mode");
    po.Register("prior-floor", &prior_floor, "When setting priors, floor for "
                "priors (only used to avoid generating NaNs upon inversion)");

    po.Read(argc, argv);

    if (po.NumArgs() != 3) {
      po.PrintUsage();
      exit(1);
    }

    std::string nnet_rxfilename = po.GetArg(1),
      counts_rxfilename = po.GetArg(2),
      nnet_wxfilename = po.GetArg(3);

    AmNnet am_nnet;
    TransitionModel trans_model;
    {
      bool binary_read;
      Input ki(nnet_rxfilename, &binary_read);
      trans_model.Read(ki.Stream(), binary_read);
      am_nnet.Read(ki.Stream(), binary_read);
    }
    
    Vector<BaseFloat> pdf_counts;
    {
      bool binary_read;
      Input ki(counts_rxfilename, &binary_read);
      pdf_counts.Read(ki.Stream(), binary_read);
    }

    BaseFloat sum = pdf_counts.Sum();
    KALDI_ASSERT(sum != 0.0);
    KALDI_ASSERT(prior_floor > 0.0 && prior_floor < 1.0);
    pdf_counts.Scale(1.0 / sum);
    pdf_counts.ApplyFloor(prior_floor);
    pdf_counts.Scale(1.0 / pdf_counts.Sum()); // normalize again.
    am_nnet.SetPriors(pdf_counts);
    
    {
      Output ko(nnet_wxfilename, binary_write);
      trans_model.Write(ko.Stream(), binary_write);
      am_nnet.Write(ko.Stream(), binary_write);
    }
    
    KALDI_LOG << "Read counts for " << pdf_counts.Dim() << " pdfs and set priors to neural network model. Model written to "
      << nnet_wxfilename;
    
    return 0;
  } catch(const std::exception &e) {
    std::cerr << e.what() << '\n';
    return -1;
  }
}


