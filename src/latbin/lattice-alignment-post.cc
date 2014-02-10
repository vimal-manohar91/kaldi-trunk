// latbin/lattice-alignment-post.cc
// Author: Vimal Manohar

// Copyright 2009-2011  Microsoft Corporation

// See ../../COPYING for clarification regarding multiple authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at //
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
#include "fstext/fstext-lib.h"
#include "lat/kaldi-lattice.h"
#include "lat/lattice-functions.h"

int main(int argc, char *argv[]) {
  try {
    using namespace kaldi;
    typedef kaldi::int32 int32;
    typedef kaldi::int64 int64;
    using fst::SymbolTable;
    using fst::VectorFst;
    using fst::StdArc;

    const char *usage =
      "Do forward backward and get posteriors corresponding to the alignments; output as posteriors of aligned path. Optionally write as a weights vector\n"
      "Usage: lattice-alignment-post [options]  lattice-rspecifier alignments-rspecifier post-wspecifier [weights-wspecifier [avg-weights-wspecifier]] \n"
      " e.g.: lattice-alignment-post --acoustic-scale=0.1 ark:1.lats ark:1.ali ark:1.post ark:/dev/null ark:1.avg_weights\n";
    ParseOptions po(usage);
    BaseFloat acoustic_scale = 1.0;
    BaseFloat lm_scale = 1.0;

    po.Register("acoustic-scale", &acoustic_scale, "Scaling factor for acoustic likelihoods");
    po.Register("lm-scale", &lm_scale, "Scaling factor for LM probabilities. "
        "Note: the ratio acoustic-scale/lm-scale is all that matters.");

    po.Read(argc, argv);

    if (po.NumArgs() < 3 && po.NumArgs() > 5) {
      po.PrintUsage();
      exit(1);
    }

    if (acoustic_scale == 0.0)
      KALDI_ERR << "Do not use a zero acoustic scale (cannot be inverted)";

    std::string lats_rspecifier = po.GetArg(1),
      alignments_rspecifier = po.GetArg(2),
      post_wspecifier = po.GetArg(3),
      weights_wspecifier = po.GetArg(4),
      avg_weights_wspecifier = po.GetArg(5);

    SequentialLatticeReader lat_reader(lats_rspecifier);
    RandomAccessInt32VectorReader alignments_reader(alignments_rspecifier);
    PosteriorWriter post_writer(post_wspecifier);
    BaseFloatVectorWriter weights_writer(weights_wspecifier);
    BaseFloatWriter avg_weights_writer(avg_weights_wspecifier);
    
    int32 n_done = 0, n_err = 0, n_no_ali = 0;

    double total_like = 0.0, lat_like;
    double total_ac_like = 0.0, lat_ac_like;
    double total_time = 0, lat_time;

    for (; !lat_reader.Done(); lat_reader.Next()) {
      std::string key = lat_reader.Key();
      Lattice lat = lat_reader.Value();
      lat_reader.FreeCurrent();

      if (acoustic_scale != 1.0 || lm_scale != 1.0)
        fst::ScaleLattice(fst::LatticeScale(lm_scale, acoustic_scale), &lat);
      
      if (lat.Start() == fst::kNoStateId) {
        KALDI_WARN << "Empty lattice for utterance " << key;
        n_err++;
        continue;
      }

      kaldi::uint64 props = lat.Properties(fst::kFstProperties, false);
      if (!(props & fst::kTopSorted)) {
        if (fst::TopSort(&lat) == false)
          KALDI_ERR << "Cycles detected in lattice.";
      }

      Posterior post;
      lat_like = LatticeForwardBackward(lat, &post, &lat_ac_like);
      total_like += lat_like;
      lat_time = post.size();
      total_time += lat_time;
      total_ac_like += lat_ac_like;

      KALDI_VLOG(2) << "Processed lattice for utterance: " << key << "; found "
        << lat.NumStates() << " states and " << fst::NumArcs(lat)
        << " arcs. Average log-likelihood = " << (lat_like/lat_time)
        << " over " << lat_time << " frames.  Average acoustic log-like"
        << " per frame is " << (lat_ac_like/lat_time);


      if (!alignments_reader.HasKey(key)) {
        KALDI_WARN << "No alignment for utterance " << key;
        n_no_ali++;
        continue;
      }
      
      const std::vector<int32> &alignment = alignments_reader.Value(key);

      if (static_cast<int32>(alignment.size()) != static_cast<int32>(post.size())) {
        KALDI_ERR << "Size mismatch between alignment and posterior\n";
        KALDI_ERR << alignment.size() << " vs " << post.size() << "\n";
      }

      int32 num_frames = static_cast<int32>(post.size());
  
      Posterior alignment_post;
      AlignmentToPosterior(alignment, &alignment_post);

      Vector<BaseFloat> weights(num_frames);
      for (int32 i = 0; i < num_frames; i++) {
        alignment_post[i][0].second = 0.0;
        for (size_t j = 0; j < post[i].size(); j++) {
          if (post[i][j].first == alignment[i]) {
            weights(i) = post[i][j].second;
            alignment_post[i][0].second = weights(i);
            break;
          }
        }
      }
      
      post_writer.Write(key, alignment_post);

      if (weights_wspecifier != "")
        weights_writer.Write(key, weights);
      if (avg_weights_wspecifier != "") {
        avg_weights_writer.Write(key, weights.Sum() / num_frames);
      }

      n_done++;
    }

    KALDI_LOG << "Overall average log-like/frame is "
              << (total_like/total_time) << " over " << total_time
              << " frames.  Average acoustic like/frame is "
              << (total_ac_like/total_time);
    
    KALDI_LOG << "Done " << n_done << " lattices, missing alignments for "
      << n_no_ali << ", other errors on " << n_err;

    if (n_done != 0) return 0;
    else return 1;
  } catch(const std::exception &e) {
    std::cerr << e.what();
    return -1;
  }
}
