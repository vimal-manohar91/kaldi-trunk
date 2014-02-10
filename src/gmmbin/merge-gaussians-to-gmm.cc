// bin/merge-gaussians-to-gmm.cc

// Author: Vimal Manohar

#include "base/kaldi-common.h"
#include "util/common-utils.h"
#include "util/kaldi-io.h"
#include "gmm/diag-gmm.h"
#include "gmm/full-gmm.h"
#include "gmm/am-diag-gmm.h"
#include "hmm/transition-model.h"
#include "gmm/mle-am-diag-gmm.h"

int main(int argc, char *argv[]) {
  try {
    using namespace kaldi;
    typedef kaldi::int32 int32;
    typedef kaldi::BaseFloat BaseFloat;

    const char *usage =
        "Merge a list of specified Gaussians in a diagonal-GMM acoustic model\n"
        "to a full-covariance or diagonal-covariance GMM.\n"
        "Usage: merge-gaussians-to-gmm [options] <model-file> <stats-in> <phone-list> <gmm-out>\n";

    bool binary_write = true, fullcov_gmm = false;

    kaldi::ParseOptions po(usage);
    po.Register("binary", &binary_write, "Write output in binary mode");
    po.Register("fullcov-gmm", &fullcov_gmm, "Write out full covariance GMM.");
    kaldi::GaussianMergingOptions gmm_opts;
    gmm_opts.Register(&po);

    po.Read(argc, argv);

    if (po.NumArgs() != 4) {
      po.PrintUsage();
      exit(1);
    }
    gmm_opts.Check();
    
    std::string model_in_filename = po.GetArg(1),
        stats_filename = po.GetArg(2),
        phone_list_string = po.GetArg(3),
        gmm_out_filename = po.GetArg(4);
    
    std::vector<int32> phones;
    KALDI_ASSERT(phone_list_string != "") 
    {
      SplitStringToIntegers(phone_list_string, ":", false, &phones);
      std::sort(phones.begin(), phones.end());
      KALDI_ASSERT(IsSortedAndUniq(phones) && "Phones non-unique.");
    }
    kaldi::AmDiagGmm am_gmm;
    kaldi::TransitionModel trans_model;
    {
      bool binary_read;
      kaldi::Input ki(model_in_filename, &binary_read);
      trans_model.Read(ki.Stream(), binary_read);
      am_gmm.Read(ki.Stream(), binary_read);
    }

    std::vector<int32> pdfs;
    bool ans = GetPdfsForPhones(trans_model, phones, &pdfs);
    if (!ans) {
      KALDI_WARN << "The pdfs for the listed phones may be shared by other phones "
        << "(note: this probably does not matter.)";
    }

    Vector<double> transition_accs;
    AccumAmDiagGmm gmm_accs;
    {
      bool binary;
      Input ki(stats_filename, &binary);
      transition_accs.Read(ki.Stream(), binary);
      gmm_accs.Read(ki.Stream(), binary, true);  // true == add; doesn't matter here.
    }

    kaldi::DiagGmm gmm;
    MergeGaussiansInPdfs(am_gmm, gmm_accs, pdfs, gmm_opts, &gmm);
    if (fullcov_gmm) {
      kaldi::FullGmm full_gmm;
        full_gmm.CopyFromDiagGmm(gmm);
      kaldi::Output ko(gmm_out_filename, binary_write);
      full_gmm.Write(ko.Stream(), binary_write);
    } else {
      kaldi::Output ko(gmm_out_filename, binary_write);
      gmm.Write(ko.Stream(), binary_write);
    }

    KALDI_LOG << "Written gmm to " << gmm_out_filename;
  } catch(const std::exception &e) {
    std::cerr << e.what() << '\n';
    return -1;
  }
}



