// featbin/get-c0.cc
// Author: Vimal Manohar

#include "base/kaldi-common.h"
#include "util/common-utils.h"
#include "matrix/kaldi-matrix.h"

int main(int argc, char *argv[]) {
  try {
    using namespace kaldi;

    const char *usage =
      "Get c0 from the features and write to archive format.\n"
      "Usage: get-c0 [options] <feat-rspecifier> <c0-wspecifier> [<avg-c0-wspecifier>]\n";

    ParseOptions po(usage);
    bool binary = true, average;
    po.Register("binary", &binary, "Binary-mode output (not relevant if writing "
        "to archive)");
    po.Read(argc, argv);

    if (po.NumArgs() < 2) {
      po.PrintUsage();
      exit(1);
    }

    int32 num_done = 0;

    if (ClassifyRspecifier(po.GetArg(1), NULL, NULL) != kNoRspecifier) {
      std::string feat_rspecifier = po.GetArg(1);
      std::string c0_wspecifier = po.GetArg(2);
      std::string avg_c0_wspecifier = po.GetArg(3);

      BaseFloatVectorWriter c0_writer(c0_wspecifier); 
      BaseFloatWriter avg_c0_writer(avg_c0_wspecifier);
      SequentialBaseFloatMatrixReader kaldi_reader(feat_rspecifier);
      for (; !kaldi_reader.Done(); kaldi_reader.Next(), num_done++) {
        Matrix<BaseFloat> feats = kaldi_reader.Value();
        Vector<BaseFloat> c0(feats.NumRows());
        c0.CopyColFromMat(feats, 0);
        c0_writer.Write(kaldi_reader.Key(), c0);
        if (! avg_c0_wspecifier.empty())
          avg_c0_writer.Write(kaldi_reader.Key(), c0.Sum()/c0.Dim());
      }
    }
    KALDI_LOG << "Got C0 from " << num_done << " feature matrices.";
    return (num_done != 0 ? 0 : 1);
  } catch(const std::exception &e) {
    std::cerr << e.what();
    return -1;
  }
}


