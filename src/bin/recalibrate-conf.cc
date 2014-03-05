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
      "Recalibrate the best path confidence scores of a system using the best path\n"
      "and corresponding confidences from other systems.\n"
      "It makes sense only when the best path alignments are pdf alignments and \n"
      "the alignments from different systems match the model and tree.\n"
      "[convert-ali can be used for this]"
      "\n"
      "Usage: recalibrate-conf [options] ali-rspecifier0 weight-rspecifier0 [ali-rspecifier1 weight-rspecifier1 ali-rspecifier2 weight-rspecifier2 ...] weight-wspecifier\n"
      " e.g.: recalibrate-conf ark:0.1.best_path_ali ark:0.1.weights ark:1.1.best_path_ali ark:1.1.weights ark:0.1.recalibrated_weights\n";

    int32 primary_system = 0;
    ParseOptions po(usage);
    po.Register("primary-system", &primary_system, "Index of the primary system. (default: 0)");
    
    po.Read(argc, argv);

    int32 num_args = po.NumArgs();
    if (num_args < 3 || num_args % 2 == 0) {
      po.PrintUsage();
      exit(1);
    }

    int32 num_other_systems = (num_args - 3) / 2;

    std::string ali_rspecifier0 = po.GetArg(1),
      weights_rspecifier0 = po.GetArg(2),
      weights_wspecifier = po.GetArg(num_args);

    // Output weights
    BaseFloatVectorWriter weights_writer(weights_wspecifier);

    // Input best path and posteriors
    
    // First system
    SequentialInt32VectorReader alignment_reader0(ali_rspecifier0);
    RandomAccessBaseFloatVectorReader weights_reader0(weights_rspecifier0);

    // Other systems
    std::vector<RandomAccessInt32VectorReader*> alignment_readers(num_other_systems,
        static_cast<RandomAccessInt32VectorReader*>(NULL));
    std::vector<std::string> alignment_rspecifiers(num_other_systems);
    std::vector<RandomAccessBaseFloatVectorReader*> weights_readers(num_other_systems, 
        static_cast<RandomAccessBaseFloatVectorReader*>(NULL));
    std::vector<std::string> weights_rspecifiers(num_other_systems);

    for (int32 i = 3; i < num_args; ++i) {
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

      // Declare a num_other_systems size vector of alignments and initialize
      // to alignments with num_frames frames
      std::vector< std::vector<int32> > alignments(num_other_systems+1, 
          std::vector<int32>(num_frames, 0));
      alignments[0] = alignment0;

      // Per-frame confidences of the utterance corresponding to all
      // the systems are stored in a matrix
      Matrix<BaseFloat> confidences(num_other_systems+1, num_frames);

      if (weights_reader0.HasKey(key)) {
        Vector<BaseFloat> weights0 = weights_reader0.Value(key);

        if (weights0.Dim() == num_frames) {
          confidences.CopyRowFromVec(weights0, 0);
      
          int32 n_this_success = 0;
          for (int32 n = 1; n <= num_other_systems; ++n) {
            if (alignment_readers[n-1]->HasKey(key) 
                && weights_readers[n-1]->HasKey(key)) {
              alignments[n] = alignment_readers[n-1]->Value(key);
              Vector<BaseFloat> this_weights = weights_readers[n-1]->Value(key);

              if (alignments[n].size() != num_frames) {
                KALDI_WARN << "Dimension mismatch for utterance " << key 
                  << " : " << alignments[n].size() << " for "
                  << "system " << (n) << ", rspecifier: "
                  << alignment_rspecifiers[n-1] << " vs " << num_frames;
                n_mismatch++;
                break;  // If there is any mismatch, no need to check any other
                // systems. Just move on to the next utterance.
                // But first, we must break from this loop.
              } else if (this_weights.Dim() != num_frames) {
                KALDI_WARN << "Dimension mismatch for utterance " << key 
                  << " : " << this_weights.Dim() << " for "
                  << "system " << (n) << ", rspecifier: "
                  << weights_rspecifiers[n-1] << " vs " << num_frames;
                n_mismatch++;
                break;  // If there is any mismatch, no need to check any other
                // systems. Just move on to the next utterance.
                // But first, we must break from this loop.
              }
              confidences.CopyRowFromVec(this_weights, n); 
              n_this_success++;
              n_total_utts++;
            } else {
              KALDI_WARN << "No vector found for utterance " << key << " for "
                << "system " << (n) << ", rspecifier: "
                << alignment_rspecifiers[n-1] << ", " << weights_rspecifiers[n-1];
              n_missing++;
              break;
            }
          }

          if (n_this_success == num_other_systems) {
            // If everything works fine until here, we can recalibrate the score
            // for the primary system's posteriors
            Vector<BaseFloat> weights_out(num_frames);
            for (int32 i = 0; i < num_frames; i++) {
              int32 num_agree = -1;    // Number of other systems that agree with 
              // primary system on this frame pdf
              for (int32 n = 0; n <= num_other_systems; ++n) {
                if (alignments[primary_system][i] == alignments[n][i])
                  num_agree++;
              }
              if (num_agree > 0) {  
                // Atleast one secondary system agrees with the primary system. 
                // Increase the confidence of the primary system.
                // The function used here is c1 -> c1^(1/n)
                weights_out(i) = pow(confidences(primary_system,i), 1.0/num_agree);
              } else {
                // No system agrees. Decrease the confidence of the primary system 
                // hypothesis.
                // This is proportional to how confident the secondary systems are
                // to their own hypotheses
                Vector<BaseFloat> this_frame_conf(num_other_systems+1);
                this_frame_conf.CopyColFromMat(confidences, i);
                weights_out(i) = pow(confidences(primary_system,i), this_frame_conf.Sum()/confidences(primary_system,i));
              }
            }

            weights_writer.Write(key, weights_out);
            n_success++;
          } else {
            KALDI_WARN << "Successfully matched utteracnce " << key
              << " for only " << n_this_success << " out of " 
              << num_other_systems << ". Skipping utterance.";
          }
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
