// latbin/lattice-rescore-long-arcs.cc
// Author: Vimal Manohar
//

#include "base/kaldi-common.h"
#include "util/common-utils.h"
#include "fstext/fstext-lib.h"
#include "lat/kaldi-lattice.h"

template<class Weight, class Int>
void RescoreLongArcs(const MutableFst<ArcTpl<CompactLatticeWeightTpl<Weight, Int> > > &fst, std::vector<int> silphone_list, BaseFloat 
int main(int argc, char *argv[]) {
  try {
    using namespace kaldi;
    typedef kaldi::int32 int32;
    typedef kaldi::int64 int64;
    using fst::SymbolTable;
    using fst::VectorFst;
    using fst::StdArc;
    using fst::ReadFstKaldi;

    const char *usage =
        "Add a penalty to the graph-cost of arcs of a phone-aligned "
        "lattice if the length of the arc is greater a threshold. "
        "The penalty cost increases with the length of the arc\n"
        "Usage: lattice-rescore-long-arcs [options] phone-aligned-lattice-rspecifier lattice-wspecifier\n"
        " e.g.: lattice-rescore-long-arcs ark:in.lats ark:out.lats\n";

    ParseOptions po(usage);
    int32 arc_length_threshold_silphones = 50;
    int32 arc_length_threshold_nonsilphones = 10;

    po.Register("arc-length-threshold-silphones", &arc_length_threshold_silphones, "Length of silence phones above which the arc would be penalized");
    po.Register("arc-length-threshold-nonsilphones", &arc_length_threshold_nonsilphones, "Length of non-silence phones above which the arc would be penalized");

    po.Read(argc, argv);
    if (po.NumArgs() != 2) { 
      po.PrintUsage();
      exit(1);
    }

    std::string lats_rspecifier = po.GetArg(1),
      lats_wspecifier = po.GetArg(2);

    SequentialCompactLatticeReader clat_reader(lats_rspecifier);

    CompactLatticeWriter clat_writer(lats_wspecifier);

    int32 n_done = 0, n_fail = 0;

    for (; !clat_reader.Done(); clat_reader.Next()) {
      std::string key = clat_reader.Key();
      CompactLattice clat = clat_reader.Value();
      clat_reader.FreeCurrent();

    }
    
