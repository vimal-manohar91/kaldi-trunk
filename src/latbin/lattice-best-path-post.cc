// latbin/lattice-best-path-post.cc
// Author: Vimal Manohar
//
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
        "Generate 1-best path through lattices; output as alignments and posteriors of best path as weights\n"
        "Usage: lattice-best-path-post [options]  lattice-rspecifier alignments-wspecifier weights-wspecifier \n"
        " e.g.: lattice-best-path-post --acoustic-scale=0.1 ark:1.lats ark:1.ali ark:1.weights \n";
      
    ParseOptions po(usage);
    BaseFloat acoustic_scale = 1.0;
    BaseFloat lm_scale = 1.0;
    bool get_average_post = false;

    po.Register("acoustic-scale", &acoustic_scale, "Scaling factor for acoustic likelihoods");
    po.Register("lm-scale", &lm_scale, "Scaling factor for LM probabilities. "
                "Note: the ratio acoustic-scale/lm-scale is all that matters.");
    po.Register("get-average-post", &get_average_post, "Get average posterior over the "
                "entire utterance instead of a per-frame posterior");
    
    po.Read(argc, argv);

    if (po.NumArgs() != 3) {
      po.PrintUsage();
      exit(1);
    }

    if (acoustic_scale == 0.0)
      KALDI_ERR << "Do not use a zero acoustic scale (cannot be inverted)";
    
    std::string lats_rspecifier = po.GetArg(1),
        alignments_wspecifier = po.GetOptArg(2),
        weights_wspecifier = po.GetOptArg(3);

    SequentialLatticeReader lat_reader(lats_rspecifier);
    Int32VectorWriter alignments_writer(alignments_wspecifier);
    BaseFloatVectorWriter weights_writer;
    BaseFloatWriter avg_weights_writer;
    
    if (! get_average_post) {
      if (weights_wspecifier != "" && ! weights_writer.Open(weights_wspecifier)) {
        KALDI_ERR << "TableWriter: failed to write to "
          << weights_wspecifier;
      }
    }
    else {
      if (weights_wspecifier != "" && ! avg_weights_writer.Open(weights_wspecifier)) {
        KALDI_ERR << "TableWriter: failed to write to "
          << weights_wspecifier;
      }
    }

    int32 n_done = 0, n_fail = 0;
    int64 n_frame = 0;
    LatticeWeight tot_weight = LatticeWeight::One();
    
    double total_like = 0.0, lat_like;
    double total_ac_like = 0.0, lat_ac_like;
    double total_time = 0, lat_time;

    for (; !lat_reader.Done(); lat_reader.Next()) {
      std::string key = lat_reader.Key();
      Lattice lat = lat_reader.Value();
      lat_reader.FreeCurrent();
      if (acoustic_scale != 1.0 || lm_scale != 1.0)
        fst::ScaleLattice(fst::LatticeScale(lm_scale, acoustic_scale), &lat);

      Lattice best_path;
      ShortestPath(lat, &best_path);  // A specialized
      // implementation of shortest-path for CompactLattice.
      
      if (best_path.Start() == fst::kNoStateId) {
        KALDI_WARN << "Best-path failed for key " << key;
        n_fail++;
      } else {

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
      
        std::vector<int32> alignment;
        std::vector<int32> words;
        LatticeWeight weight;
        GetLinearSymbolSequence(best_path, &alignment, &words, &weight);
        KALDI_VLOG(2) << "For utterance " << key << ", best cost "
                  << weight.Value1() << " + " << weight.Value2() << " = "
                  << (weight.Value1() + weight.Value2());

        if (static_cast<int32>(alignment.size()) != static_cast<int32>(post.size())) {
          KALDI_ERR << "Size mismatch between alignment and posterior\n";
          KALDI_ERR << alignment.size() << " vs " << post.size() << "\n";
        }
      
        int32 num_frames = static_cast<int32>(post.size());

        Vector<BaseFloat> weights(num_frames);
        for (int32 i = 0; i < num_frames; i++) {
          for (size_t j = 0; j < post[i].size(); j++) {
            if (post[i][j].first == alignment[i]) {
              weights(i) = post[i][j].second;
              break;
            }
          }
        }

        alignments_writer.Write(key, alignment);
        if (! get_average_post) {
          weights_writer.Write(key, weights);
        }
        else {
          avg_weights_writer.Write(key, weights.Sum() / num_frames);
        }
        
        n_done++;
        n_frame += alignment.size();
        tot_weight = Times(tot_weight, weight);
        
      }
    }

    KALDI_LOG << "Overall average log-like/frame is "
              << (total_like/total_time) << " over " << total_time
              << " frames.  Average acoustic like/frame is "
              << (total_ac_like/total_time);
    BaseFloat tot_weight_float = tot_weight.Value1() + tot_weight.Value2();
    KALDI_LOG << "Overall score per frame is " << (tot_weight_float/n_frame)
      << " = " << (tot_weight.Value1()/n_frame) << " [graph]"
      << " + " << (tot_weight.Value2()/n_frame) << " [acoustic]"
      << " over " << n_frame << " frames.";
    KALDI_LOG << "Done " << n_done << " lattices, failed for " << n_fail;
    
    if (n_done != 0) return 0;
    else return 1;
  } catch(const std::exception &e) {
    std::cerr << e.what();
    return -1;
  }
}

