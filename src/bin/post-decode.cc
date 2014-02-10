// bin/post-decode.cc
// Author: Vimal Manohar

#include "base/kaldi-common.h"
#include "util/common-utils.h"
#include "hmm/hmm-utils.h"
#include "hmm/posterior.h"

int main(int argc, char *argv[]) {
  using namespace kaldi;
  typedef kaldi::int32 int32;
  try {
    const char *usage =
        "This program does posterior decoding by finding for each frame \n"
        "the transition-id with the highest posterior probability and writes \n"
        "the decoded output as an alignment \n"
        "Optionally write the posterior probability as a weight vector\n"
        "Usage:  post-decode [options] <post-rspecifier> <ali-wspecifier> [weights-wspecifier]\n"
        "e.g.: post-decode ark:1.post ark:1.ali \n";
  
    ParseOptions po(usage);

    po.Read(argc, argv);

    if (po.NumArgs() < 2 || po.NumArgs() > 3) {
      po.PrintUsage();
      exit(1);
    }

    std::string post_rspecifier = po.GetArg(1),
      ali_wspecifier = po.GetArg(2),
      weights_wspecifier = po.GetArg(3);

    int32 n_done = 0;
    
    SequentialPosteriorReader post_reader(post_rspecifier);
    Int32VectorWriter ali_writer(ali_wspecifier);
    BaseFloatVectorWriter weights_writer(weights_wspecifier);

    for (; !post_reader.Done(); post_reader.Next()) {
      std::string key = post_reader.Key();
      const Posterior &post = post_reader.Value();

      int32 num_frames = static_cast<int32>(post.size());
      Vector<BaseFloat> weights(num_frames);

      std::vector<int32> alignment(num_frames);

      for (size_t i = 0; i < static_cast<size_t>(num_frames); i++) {
        BaseFloat max_weight = 0.0;
        alignment[0] = post[i][0].first;
        for (size_t j = 1; j < post[i].size(); j++) {
          if (post[i][j].second > max_weight) {
            max_weight = post[i][j].second;
            weights(i) = post[i][j].second;
            alignment[i] = post[i][j].first;
          }
        }
      }
      
      ali_writer.Write(key, alignment);

      if (weights_wspecifier != "")
        weights_writer.Write(key, weights);
      n_done++;
    }

    KALDI_LOG << "Done " << n_done << " posteriors\n";
    
    if (n_done != 0) return 0;
    else return 1;
  } catch(const std::exception &e) {
    std::cerr << e.what();
    return -1;
  }
}

