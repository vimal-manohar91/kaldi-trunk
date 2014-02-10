// gmmbin/gmm-get-occs.cc

// Author: Vimal Manohar

#include "base/kaldi-common.h"
#include "util/common-utils.h"
#include "gmm/am-diag-gmm.h"
#include "tree/context-dep.h"
#include "hmm/transition-model.h"
#include "gmm/mle-am-diag-gmm.h"

int main(int argc, char *argv[]) {
  try {
    using namespace kaldi;
    typedef kaldi::int32 int32;

    const char *usage =
      "Get the state occupations from a GMM-based acoustic model.\n"
      "Usage:  gmm-get-occs [options] <model-in> <stats-in> <occs-out>\n"
      "e.g.: gmm-est 1.mdl 1.acc 1.occs\n";

    bool binary_write = true;

    ParseOptions po(usage);
    po.Register("binary", &binary_write, "Write output in binary mode");

    po.Read(argc, argv);

    if (po.NumArgs() != 3) {
      po.PrintUsage();
      exit(1);
    }

    std::string model_in_filename = po.GetArg(1),
      stats_filename = po.GetArg(2),
      occs_out_filename = po.GetArg(3);

    AmDiagGmm am_gmm;
    TransitionModel trans_model;
    {
      bool binary_read;
      Input ki(model_in_filename, &binary_read);
      trans_model.Read(ki.Stream(), binary_read);
      am_gmm.Read(ki.Stream(), binary_read);
    }

    Vector<double> transition_accs;
    AccumAmDiagGmm gmm_accs;
    {
      bool binary;
      Input ki(stats_filename, &binary);
      transition_accs.Read(ki.Stream(), binary);
      gmm_accs.Read(ki.Stream(), binary, true);  // true == add; doesn't matter here.
    }

    Vector<BaseFloat> pdf_occs;
    pdf_occs.Resize(gmm_accs.NumAccs());
    for (int i = 0; i < gmm_accs.NumAccs(); i++)
      pdf_occs(i) = gmm_accs.GetAcc(i).occupancy().Sum();

    KALDI_ASSERT(!occs_out_filename.empty()) 
    {
      bool binary = false;
      WriteKaldiObject(pdf_occs, occs_out_filename, binary);
    }

    KALDI_LOG << "Written occs to " << occs_out_filename;
    return 0;
  } catch(const std::exception &e) {
    std::cerr << e.what() << '\n';
    return -1;
  }
}
