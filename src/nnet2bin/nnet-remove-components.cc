// nnet2bin/nnet-remove-components.cc

// Copyright 2012  Johns Hopkins University (author:  Vimal Manohar)

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

#include "base/kaldi-common.h"
#include "util/common-utils.h"
#include "nnet2/am-nnet.h"

int main(int argc, char *argv[]) {
  try {
    using namespace kaldi;
    using namespace kaldi::nnet2;
    typedef kaldi::int32 int32;

    const char *usage =
        "Copy a (cpu-based) neural net and optionally remove certain layers\n"
        "Usage:  nnet-remove-components [options] <nnet-in> <nnet-out>\n"
        "e.g.:   nnet-remove-components --remove-last-layers=1 1.mdl 1.new.mdl\n";

    bool binary_write = true;
    int32 remove_first_layers = 0;
    int32 remove_last_layers = 0;
    
    ParseOptions po(usage);
    po.Register("binary", &binary_write, "Write output in binary mode");
    po.Register("remove-last-layers", &remove_last_layers, "Remove N last layers (Components) from Nnet");
    po.Register("remove-first-layers", &remove_first_layers, "Remove N first layers (Components) from Nnet");

    po.Read(argc, argv);
    
    if (po.NumArgs() != 2) {
      po.PrintUsage();
      exit(1);
    }

    std::string nnet_rxfilename = po.GetArg(1),
        nnet_wxfilename = po.GetArg(2);
    
    Nnet nnet;
    {
      bool binary;
      Input ki(nnet_rxfilename, &binary);
      nnet.Read(ki.Stream(), binary);
    }

    if (remove_last_layers > 0) {
      for (int32 i = 0; i < remove_last_layers; i++) {
        nnet.RemoveLastComponent();
      }
    }

    if (remove_first_layers > 0) {
      for (int32 i = 0; i < remove_first_layers; i++) {
        nnet.RemoveComponent(0);
      }
    }

    {
      Output ko(nnet_wxfilename, binary_write);
      nnet.Write(ko.Stream(), binary_write);
    }

    KALDI_LOG << "Copied neural net from " << nnet_rxfilename
              << " to " << nnet_wxfilename;
    return 0;
  } catch(const std::exception &e) {
    std::cerr << e.what() << '\n';
    return -1;
  }
}

