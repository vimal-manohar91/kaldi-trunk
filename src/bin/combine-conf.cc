// bin/recalibrate-conf.cc

// Copyright 2014 Vimal Manohar

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

#include <vector>
#include <string>

using std::vector;
using std::string;

#include "base/kaldi-common.h"
#include "util/common-utils.h"
#include "matrix/kaldi-vector.h"

int main(int argc, char *argv[]) {
  try {
    using namespace kaldi;

    const char *usage = 
      "Combine the best path and confidence scores of multiple systems\n"
      "It makes sense only when the best path alignments are pdf alignments and \n"
      "the alignments from different systems match the model and tree.\n"
      "[convert-ali can be used for this]"
      "\n"
      "Usage: combine-conf [options] ali-rspecifier0 weight-rspecifier0 [ali-rspecifier1 weight-rspecifier1 ali-rspecifier2 weight-rspecifier2 ...] ali-wspecifier weight-wspecifier\n"
      " e.g.: combine-conf ark:0.1.best_path_ali ark:0.1.weights ark:1.1.best_path_ali ark:1.1.weights ark:combined_best_path_ali ark:combined_weights\n";

    ParseOptions po(usage);
    
    po.Read(argc, argv);

    int32 num_args = po.NumArgs();
    if (num_args < 4 || num_args % 2 != 0) {
      po.PrintUsage();
      exit(1);
    }

    int32 num_other_systems = (num_args - 4) / 2;

    std::string ali_rspecifier0 = po.GetArg(1),
      weights_rspecifier0 = po.GetArg(2),
      ali_wspecifier = po.GetArg(num_args-1),
      weights_wspecifier = po.GetArg(num_args);

    Int32VectorWriter alignment_writer(ali_wspecifier);
    BaseFloatVectorWriter weights_writer(weights_wspecifier);

    // Input best path and posteriors
    
    // Primary system
    SequentialInt32VectorReader alignment_reader0(ali_rspecifier0);
    RandomAccessBaseFloatVectorReader weights_reader0(weights_rspecifier0);

    // Secondary systems
    std::vector<RandomAccessInt32VectorReader*> alignment_readers(num_other_systems,
        static_cast<RandomAccessInt32VectorReader*>(NULL));
    std::vector<std::string> alignment_rspecifiers(num_other_systems);
    std::vector<RandomAccessBaseFloatVectorReader*> weights_readers(num_other_systems, 
        static_cast<RandomAccessBaseFloatVectorReader*>(NULL));
    std::vector<std::string> weights_rspecifiers(num_other_systems);

    for (int32 i = 3; i < num_args - 1; ++i) {
      if (i % 2 == 1) {
        alignment_readers[(i-3)/2] = new RandomAccessInt32VectorReader(po.GetArg(i));
        alignment_rspecifiers[(i-3)/2] = po.GetArg(i);
      } else {
        weights_readers[(i-4)/2] = new RandomAccessBaseFloatVectorReader(po.GetArg(i));
        weights_rspecifiers[(i-4)/2] = po.GetArg(i);
      }
    }

    int32 n_utts = 0, n_total_utts = 0,
          n_success = 0, n_missing = 0, n_mismatch = 0;

    for (; !alignment_reader0.Done(); alignment_reader0.Next()) {
      // Read alignments from the primary system in sequential order and 
      // and match it with other systems
      std::string key = alignment_reader0.Key();
      std::vector<int32> alignment0 = alignment_reader0.Value();
      alignment_reader0.FreeCurrent();
      n_utts++;         // Number of unique utterances looked at
      n_total_utts++;   // Number of utterances across all systems

      int32 num_frames = alignment0.size();

      if (weights_reader0.HasKey(key)) {
        Vector<BaseFloat> weights0 = weights_reader0.Value(key);

        if (weights0.Dim() == num_frames) {
          Vector<BaseFloat> weights_out(weights0);
          std::vector<int32> alignment_out(alignment0);

          for (int32 n = 1; n <= num_other_systems; ++n) {
            if (alignment_readers[n-1]->HasKey(key) 
                && weights_readers[n-1]->HasKey(key)) {
              std::vector<int32> this_alignment = alignment_readers[n-1]->Value(key);
              Vector<BaseFloat> this_weights = weights_readers[n-1]->Value(key);

              if (this_alignment.size() != num_frames) {
                KALDI_WARN << "Dimension mismatch for utterance " << key 
                  << " : " << this_alignment.size() << " for "
                  << "system " << (n) << ", rspecifier: "
                  << alignment_rspecifiers[n-1] << " vs " << num_frames;
                n_mismatch++;
                continue;  // If there is any mismatch, move to next system
              } else if (this_weights.Dim() != num_frames) {
                KALDI_WARN << "Dimension mismatch for utterance " << key 
                  << " : " << this_weights.Dim() << " for "
                  << "system " << (n) << ", rspecifier: "
                  << weights_rspecifiers[n-1] << " vs " << num_frames;
                n_mismatch++;
                continue;  // If there is any mismatch, move to next system
              }
              for (int32 i = 0; i < num_frames; i++) {
                if (this_weights(i) > weights_out(i)) {
                  weights_out(i) = this_weights(i);
                  alignment_out[i] = this_alignment[i];
                }
              }
              n_total_utts++;
            } else {
              KALDI_WARN << "No vector found for utterance " << key << " for "
                << "system " << (n) << ", rspecifier: "
                << alignment_rspecifiers[n-1] << ", " << weights_rspecifiers[n-1];
              n_missing++;
              break;
            }
          }

          weights_writer.Write(key, weights_out);
          alignment_writer.Write(key, alignment_out);
          n_success++;
        } else {
          KALDI_WARN << "Dimension mismatch for utterance " << key 
            << " : " << weights0.Dim() << " for "
            << "system " << 0 << ", rspecifier: "
            << weights_rspecifier0 << " vs " << num_frames;
          n_mismatch++;
        }
      } else {
        KALDI_WARN << "No vector found for utterance " << key << " for "
          << "system " << 0 << ", rspecifier: "
          << weights_rspecifier0;
        n_missing++;
      }
    }

    KALDI_LOG << "Processed " << n_utts << " utterances: with a total of "
      << n_total_utts << " utterances across " << (num_other_systems+1)
      << " different systems";
    KALDI_LOG << "Produced output for " << n_success << " utterances; "
      << n_missing << " total missing utterances" 
      << " and dimension mismatch on " << n_mismatch;
  
    DeletePointers(&weights_readers);
    DeletePointers(&alignment_readers);

    return(n_success != 0 
        && n_missing + n_mismatch < (n_success - n_missing - n_mismatch) ? 0 : 1);
  } catch(const std::exception &e) {
    std::cerr << e.what();
    return -1;
  }
}
