// bin/pdf-post-to-align-pdf-post.cc
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
        "This program gets the pdf-level posteriors for the given pdf-level alignments. \n"
        "Optionally write the posterior as a weight vector\n"
        "or a table of average utterance posterior\n"
        "\n"
        "Usage:  pdf-post-to-align-pdf-post [options] <pdf-post-rspecifier> <pdf-align-rspecifier> <post-wspecifier> [weights-wspecifier [avg-weights-wspecifier]]\n"
        "e.g.: pdf-post-to-align-pdf-post ark:1.post ark:1.ali ark:1.align_post ark:/dev/null ark:1.avg_weights\n";
  
    ParseOptions po(usage);

    po.Read(argc, argv);

    if (po.NumArgs() < 3 || po.NumArgs() > 5) {
      po.PrintUsage();
      exit(1);
    }
 
    std::string pdf_post_rspecifier = po.GetArg(1),
      pdf_align_rspecifier = po.GetArg(2),
      align_pdf_post_wspecifier = po.GetArg(3),
      weights_wspecifier, avg_weights_wspecifier;
    if (po.NumArgs() >= 4) 
      weights_wspecifier = po.GetArg(4);
    if (po.NumArgs() == 5)
      avg_weights_wspecifier = po.GetArg(5);
    
    int32 n_done = 0, n_err = 0, n_no_ali = 0;
  
    SequentialPosteriorReader pdf_post_reader(pdf_post_rspecifier);
    RandomAccessInt32VectorReader pdf_align_reader(pdf_align_rspecifier);
    PosteriorWriter post_writer(align_pdf_post_wspecifier);
    BaseFloatVectorWriter weights_writer(weights_wspecifier);
    BaseFloatWriter avg_weights_writer(avg_weights_wspecifier);

    for (; !pdf_post_reader.Done(); pdf_post_reader.Next()) {
      std::string key = pdf_post_reader.Key();
      const Posterior &post = pdf_post_reader.Value();

      int32 num_frames = static_cast<int32>(post.size());
      Vector<BaseFloat> weights(num_frames);

      if (!pdf_align_reader.HasKey(key)) {
        KALDI_WARN << "No alignment for utterance " << key << "\n";
        n_no_ali++;
        continue;
      }
      
      const std::vector<int32> &alignment = pdf_align_reader.Value(key);
      
      if (static_cast<int32>(alignment.size()) != static_cast<int32>(post.size())) {
        KALDI_ERR << "Size mismatch between alignment and posterior\n";
        KALDI_ERR << alignment.size() << " vs " << post.size() << "\n";
      }
      
      Posterior alignment_post;
      AlignmentToPosterior(alignment, &alignment_post);
      
      int32 n_zero_post = 0;
      for (size_t i = 0; i < static_cast<size_t>(num_frames); i++) {
        alignment_post[i][0].second = -1.0;
        for (size_t j = 0; j < post[i].size(); j++) {
          if (post[i][j].first == alignment[i]) {
            weights(i) = post[i][j].second;
            alignment_post[i][0].second = weights(i);
            break;
          }
        }
        if (alignment_post[i][0].second == -1.0) {
          n_zero_post++;
          alignment_post[i][0].second = 0.0;
        }
      }
      if (n_zero_post == num_frames) {
        KALDI_WARN << "Zero posterior for all frames of utterance " << key << "\n";
        n_err++;
      }

      post_writer.Write(key, alignment_post);

      if (weights_wspecifier != "")
        weights_writer.Write(key, weights);
      if (avg_weights_wspecifier != "") {
        avg_weights_writer.Write(key, weights.Sum() / num_frames);
      }
      n_done++;
    }

    KALDI_LOG << "Done " << n_done << " posteriors, missing alignments for "
      << n_no_ali << ", other errors on " << n_err;
    
    if (n_done != 0) return 0;
    else return 1;
  } catch(const std::exception &e) {
    std::cerr << e.what();
    return -1;
  }
}

