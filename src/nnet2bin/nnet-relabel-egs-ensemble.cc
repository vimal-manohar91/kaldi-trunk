// nnet2bin/nnet-train-simple.cc

// Copyright 2012  Johns Hopkins University (author: Daniel Povey)
//           2014  Xiaohui Zhang

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
#include "nnet2/nnet-randomize.h"
#include "nnet2/train-nnet-ensemble.h"
#include "nnet2/am-nnet.h"

namespace kaldi {
namespace nnet2 {

void RelabelEgsBatch(const std::vector<NnetExample> &egs_gen_post_buffer,
                     const std::vector<Nnet*> &nnets,
                     const BaseFloat &min_post,
                     const int32 &num_examples_wrote,
                     const NnetExampleWriter &example_writer, 
                     std::vector<NnetExample> *egs_relabel_buffer) {
  int32 num_states = nnets[0]->OutputDim();
  // average of posteriors matrix, storing averaged outputs of net ensemble.
  CuMatrix<BaseFloat> post_avg(egs_gen_post_buffer.size(), num_states);
  std::vector<CuMatrix<BaseFloat> > post_mat;
  post_mat.resize(nnets.size());
  for (int32 i = 0; i < nnets.size(); i++) {
    NnetUpdater updater(*(nnets[i]), nnets[i]);
    updater.FormatInput(egs_gen_post_buffer);
    updater.Propagate();
    // posterior matrix, storing output of one net.
    updater.GetOutput(&post_mat[i]);
    post_avg.AddMat(1.0, post_mat[i]);
  }
  post_avg.Scale(1.0 / static_cast<BaseFloat>(nnets.size()));
  Matrix<BaseFloat> cpu_post_avg;
  cpu_post_avg.Swap(&post_avg);
  for (int32 i = 0; i < cpu_post_avg.NumRows(); i++) {
    std::vector<std::pair<int32, BaseFloat> >  post;
    for (int32 n = 0; n < cpu_post_avg.NumCols(); n++) {
      BaseFloat p = cpu_post_avg(i, n);
      if (p >= min_post) {
        post.push_back(std::make_pair(n, p));
      } else if ((p / min_post) >= RandUniform()) {
        post.push_back(std::make_pair(n, min_post));
      }
    }
    (*egs_relabel_buffer)[i].labels = post;
    std::ostringstream ostr;
    ostr << num_examples_wrote + i;
    example_writer.Write(ostr.str(), (*egs_relabel_buffer)[i]);
  }
}

} // namespace nnet2
} // namespace kaldi

int main(int argc, char *argv[]) {
  try {
    using namespace kaldi;
    using namespace kaldi::nnet2;
    typedef kaldi::int32 int32;
    typedef kaldi::int64 int64;

    const char *usage =
        "Do forward propogation of an set of examples through an ensemble of nnets.\n"
        "The averaged posteriors of these nnets will be used as the new lables\n"
        "(soft alignments) of another set of examples (could be the same as\n"
        "the first set). The re-labeled examples are the output.\n"
        "Usage:  nnet-relabel-egs-ensemble [options] <model-in-1> <model-in-2> \n"
        "... <model-in-n> <examples-in-1> <examples-in-2>  <examples-out>\n"
        "\n"
        "e.g.:\n"
        "nnet-relabel-egs-ensemble [args] | nnet-train-ensemble 1.1.nnet 2.1.nnet \n"
        "ark:- egs.gen-post.ark ark:- egs.relabel.ark  ark:- egs.relabeled.ark \n";
    
    int32 minibatch_size = 512;
    std::string use_gpu = "yes";
    
    ParseOptions po(usage);
    po.Register("minibatch-size", &minibatch_size, "the minibatch size of examples to relabel ");
    po.Register("use-gpu", &use_gpu, "yes|no|optional, only has effect if compiled with CUDA"); 
 
    po.Read(argc, argv);
    
    if (po.NumArgs() < 4) {
      po.PrintUsage();
      exit(1);
    }
    
#if HAVE_CUDA==1
    CuDevice::Instantiate().SelectGpuId(use_gpu);
#endif
    
    int32 num_nnets = po.NumArgs() - 3;
    std::string nnet_rxfilename = po.GetArg(1);
    std::string examples_rspecifier_gen_post = po.GetArg(num_nnets + 1),
                examples_rspecifier_relabel = po.GetArg(num_nnets + 2),
                examples_wspecifier = po.GetArg(num_nnets + 3);
    std::string nnet1_rxfilename = po.GetArg(1);
    
    TransitionModel trans_model;
    std::vector<AmNnet> am_nnets(num_nnets);
    {
      bool binary_read;
      Input ki(nnet1_rxfilename, &binary_read);
      trans_model.Read(ki.Stream(), binary_read);
      am_nnets[0].Read(ki.Stream(), binary_read);
    }

    std::vector<Nnet*> nnets(num_nnets);
    nnets[0] = &(am_nnets[0].GetNnet());

    for (int32 n = 1; n < num_nnets; n++) {
      TransitionModel trans_model;
      bool binary_read;
      Input ki(po.GetArg(1 + n), &binary_read);
      trans_model.Read(ki.Stream(), binary_read);
      am_nnets[n].Read(ki.Stream(), binary_read);
      nnets[n] = &am_nnets[n].GetNnet();
    }      
    int64 num_examples = 0;
    int64 num_examples_wrote = 0;
    std::vector<NnetExample> egs_gen_post_buffer;
    std::vector<NnetExample> egs_relabel_buffer;
    BaseFloat min_post = 0.01;
    {
      { // want to make sure this object deinitializes before
        // we write the model, as it does something in the destructor.
        SequentialNnetExampleReader example_reader_gen_post(examples_rspecifier_gen_post);
        SequentialNnetExampleReader example_reader_relabel(examples_rspecifier_relabel);
        NnetExampleWriter example_writer(examples_wspecifier);

        for (; !example_reader_gen_post.Done(); example_reader_gen_post.Next(), example_reader_relabel.Next(), num_examples++) {
          KALDI_ASSERT(example_reader_gen_post.Key() == example_reader_relabel.Key());
          egs_relabel_buffer.push_back(example_reader_relabel.Value());
          egs_gen_post_buffer.push_back(example_reader_gen_post.Value());
          if (static_cast<int32>(egs_gen_post_buffer.size()) == minibatch_size) {
            num_examples_wrote = num_examples - minibatch_size;
            RelabelEgsBatch(egs_gen_post_buffer, nnets, min_post, 
                            num_examples_wrote, example_writer, &egs_relabel_buffer);
            egs_gen_post_buffer.clear();
            egs_relabel_buffer.clear();
          }  
        }
        if (!egs_gen_post_buffer.empty()) {
          KALDI_LOG << "Doing partial minibatch of size "
          << egs_gen_post_buffer.size();
          RelabelEgsBatch(egs_gen_post_buffer, nnets, min_post, 
                          num_examples - egs_gen_post_buffer.size(), 
                          example_writer, &egs_relabel_buffer);
        }
      }
    }
#if HAVE_CUDA==1
    CuDevice::Instantiate().PrintProfile();
#endif
    
    KALDI_LOG << "Finished re-labeling, processed " << num_examples
              << " examples.";
    return (num_examples == 0 ? 1 : 0);
  } catch(const std::exception &e) {
    std::cerr << e.what() << '\n';
    return -1;
  }
}


