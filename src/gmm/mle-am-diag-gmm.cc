// gmm/mle-am-diag-gmm.cc

// Copyright 2009-2011  Saarland University (Author: Arnab Ghoshal);
//                      Microsoft Corporation;  Georg Stemmer;  Yanmin Qian

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

#include "gmm/am-diag-gmm.h"
#include "gmm/mle-am-diag-gmm.h"
#include "util/stl-utils.h"
#include "tree/clusterable-classes.h"
#include "tree/cluster-utils.h"

namespace kaldi {

const AccumDiagGmm& AccumAmDiagGmm::GetAcc(int32 index) const {
  KALDI_ASSERT(index >= 0 && index < static_cast<int32>(gmm_accumulators_.size()));
  return *(gmm_accumulators_[index]);
}

AccumDiagGmm& AccumAmDiagGmm::GetAcc(int32 index) {
  KALDI_ASSERT(index >= 0 && index < static_cast<int32>(gmm_accumulators_.size()));
  return *(gmm_accumulators_[index]);
}

AccumAmDiagGmm::~AccumAmDiagGmm() {
  DeletePointers(&gmm_accumulators_);
}

void AccumAmDiagGmm::Init(const AmDiagGmm &model,
                              GmmFlagsType flags) {
  DeletePointers(&gmm_accumulators_);  // in case was non-empty when called.
  gmm_accumulators_.resize(model.NumPdfs(), NULL);
  for (int32 i = 0; i < model.NumPdfs(); i++) {
    gmm_accumulators_[i] = new AccumDiagGmm();
    gmm_accumulators_[i]->Resize(model.GetPdf(i), flags);
  }
}

void AccumAmDiagGmm::Init(const AmDiagGmm &model,
                              int32 dim, GmmFlagsType flags) {
  KALDI_ASSERT(dim > 0);
  DeletePointers(&gmm_accumulators_);  // in case was non-empty when called.
  gmm_accumulators_.resize(model.NumPdfs(), NULL);
  for (int32 i = 0; i < model.NumPdfs(); i++) {
    gmm_accumulators_[i] = new AccumDiagGmm();
    gmm_accumulators_[i]->Resize(model.GetPdf(i).NumGauss(),
                                 dim, flags);
  }
}

void AccumAmDiagGmm::SetZero(GmmFlagsType flags) {
  for (size_t i = 0; i < gmm_accumulators_.size(); i++) {
    gmm_accumulators_[i]->SetZero(flags);
  }
}

BaseFloat AccumAmDiagGmm::AccumulateForGmm(
    const AmDiagGmm &model, const VectorBase<BaseFloat> &data,
    int32 gmm_index, BaseFloat weight) {
  KALDI_ASSERT(static_cast<size_t>(gmm_index) < gmm_accumulators_.size());
  BaseFloat log_like =
      gmm_accumulators_[gmm_index]->AccumulateFromDiag(model.GetPdf(gmm_index),
                                                       data, weight);
  total_log_like_ += log_like * weight;
  total_frames_ += weight;
  return log_like;
}

BaseFloat AccumAmDiagGmm::AccumulateForGmmTwofeats(
    const AmDiagGmm &model,
    const VectorBase<BaseFloat> &data1,
    const VectorBase<BaseFloat> &data2,
    int32 gmm_index,
    BaseFloat weight) {
  KALDI_ASSERT(static_cast<size_t>(gmm_index) < gmm_accumulators_.size());
  const DiagGmm &gmm = model.GetPdf(gmm_index);
  AccumDiagGmm &acc = *(gmm_accumulators_[gmm_index]);
  Vector<BaseFloat> posteriors;
  BaseFloat log_like = gmm.ComponentPosteriors(data1, &posteriors);
  posteriors.Scale(weight);
  acc.AccumulateFromPosteriors(data2, posteriors);
  total_log_like_ += log_like * weight;
  total_frames_ += weight;
  return log_like;
}


void AccumAmDiagGmm::AccumulateFromPosteriors(
    const AmDiagGmm &model, const VectorBase<BaseFloat> &data,
    int32 gmm_index, const VectorBase<BaseFloat> &posteriors) {
  KALDI_ASSERT(gmm_index >= 0 && gmm_index < NumAccs());
  gmm_accumulators_[gmm_index]->AccumulateFromPosteriors(data, posteriors);
  total_frames_ += posteriors.Sum();
}

void AccumAmDiagGmm::AccumulateForGaussian(
    const AmDiagGmm &am, const VectorBase<BaseFloat> &data,
    int32 gmm_index, int32 gauss_index, BaseFloat weight) {
  KALDI_ASSERT(gmm_index >= 0 && gmm_index < NumAccs());
  KALDI_ASSERT(gauss_index >= 0
      && gauss_index < am.GetPdf(gmm_index).NumGauss());
  gmm_accumulators_[gmm_index]->AccumulateForComponent(data, gauss_index, weight);
}

void AccumAmDiagGmm::Read(std::istream &in_stream, bool binary,
                          bool add) {
  int32 num_pdfs;
  ExpectToken(in_stream, binary, "<NUMPDFS>");
  ReadBasicType(in_stream, binary, &num_pdfs);
  KALDI_ASSERT(num_pdfs > 0);
  if (!add || (add && gmm_accumulators_.empty())) {
    gmm_accumulators_.resize(num_pdfs, NULL);
    for (std::vector<AccumDiagGmm*>::iterator it = gmm_accumulators_.begin(),
             end = gmm_accumulators_.end(); it != end; ++it) {
      if (*it != NULL) delete *it;
      *it = new AccumDiagGmm();
      (*it)->Read(in_stream, binary, add);
    }
  } else {
    if (gmm_accumulators_.size() != static_cast<size_t> (num_pdfs))
      KALDI_ERR << "Adding accumulators but num-pdfs do not match: "
                << (gmm_accumulators_.size()) << " vs. "
                << (num_pdfs);
    for (std::vector<AccumDiagGmm*>::iterator it = gmm_accumulators_.begin(),
             end = gmm_accumulators_.end(); it != end; ++it)
      (*it)->Read(in_stream, binary, add);
  }
  // TODO(arnab): Bad hack! Need to make this self-delimiting.
  in_stream.peek();  // This will set the EOF bit for older accs.
  if (!in_stream.eof()) {
    double like, frames;
    ExpectToken(in_stream, binary, "<total_like>");
    ReadBasicType(in_stream, binary, &like);
    total_log_like_ = (add)? total_log_like_ + like : like;
    ExpectToken(in_stream, binary, "<total_frames>");
    ReadBasicType(in_stream, binary, &frames);
    total_frames_ = (add)? total_frames_ + frames : frames;
  }
}

void AccumAmDiagGmm::Write(std::ostream &out_stream, bool binary) const {
  int32 num_pdfs = gmm_accumulators_.size();
  WriteToken(out_stream, binary, "<NUMPDFS>");
  WriteBasicType(out_stream, binary, num_pdfs);
  for (std::vector<AccumDiagGmm*>::const_iterator it =
      gmm_accumulators_.begin(), end = gmm_accumulators_.end(); it != end; ++it) {
    (*it)->Write(out_stream, binary);
  }
  WriteToken(out_stream, binary, "<total_like>");
  WriteBasicType(out_stream, binary, total_log_like_);

  WriteToken(out_stream, binary, "<total_frames>");
  WriteBasicType(out_stream, binary, total_frames_);
}


// BaseFloat AccumAmDiagGmm::TotCount() const {
//  BaseFloat ans = 0.0;
//  for (int32 pdf = 0; pdf < NumAccs(); pdf++)
//    ans += gmm_accumulators_[pdf]->occupancy().Sum();
//  return ans;
// }

void ResizeModel (int32 dim, AmDiagGmm *am_gmm) {
  for (int32 pdf_id = 0; pdf_id < am_gmm->NumPdfs(); pdf_id++) {
    DiagGmm &pdf = am_gmm->GetPdf(pdf_id);
    pdf.Resize(pdf.NumGauss(), dim);
    Matrix<BaseFloat> inv_vars(pdf.NumGauss(), dim);
    inv_vars.Set(1.0); // make all vars 1.
    pdf.SetInvVars(inv_vars);
    pdf.ComputeGconsts();
  }
}

void MleAmDiagGmmUpdate (const MleDiagGmmOptions &config,
                         const AccumAmDiagGmm &am_diag_gmm_acc,
                         GmmFlagsType flags,
                         AmDiagGmm *am_gmm,
                         BaseFloat *obj_change_out,
                         BaseFloat *count_out) {
  if (am_diag_gmm_acc.Dim() != am_gmm->Dim()) {
    KALDI_ASSERT(am_diag_gmm_acc.Dim() != 0);
    KALDI_WARN << "Dimensions of accumulator " << am_diag_gmm_acc.Dim()
               << " and gmm " << am_gmm->Dim() << " do not match, resizing "
               << " GMM and setting to zero-mean, unit-variance.";
    ResizeModel(am_diag_gmm_acc.Dim(), am_gmm);
  }
  
  KALDI_ASSERT(am_gmm != NULL);
  KALDI_ASSERT(am_diag_gmm_acc.NumAccs() == am_gmm->NumPdfs());
  if (obj_change_out != NULL) *obj_change_out = 0.0;
  if (count_out != NULL) *count_out = 0.0;
  BaseFloat tmp_obj_change, tmp_count;
  BaseFloat *p_obj = (obj_change_out != NULL) ? &tmp_obj_change : NULL,
            *p_count   = (count_out != NULL) ? &tmp_count : NULL;

  for (int32 i = 0; i < am_diag_gmm_acc.NumAccs(); i++) {
    MleDiagGmmUpdate(config, am_diag_gmm_acc.GetAcc(i), flags,
                     &(am_gmm->GetPdf(i)), p_obj, p_count);

    if (obj_change_out != NULL) *obj_change_out += tmp_obj_change;
    if (count_out != NULL) *count_out += tmp_count;
  }
}


void MapAmDiagGmmUpdate (const MapDiagGmmOptions &config,
                         const AccumAmDiagGmm &am_diag_gmm_acc,
                         GmmFlagsType flags,
                         AmDiagGmm *am_gmm,
                         BaseFloat *obj_change_out,
                         BaseFloat *count_out) {
  KALDI_ASSERT(am_gmm != NULL && am_diag_gmm_acc.Dim() == am_gmm->Dim() &&
               am_diag_gmm_acc.NumAccs() == am_gmm->NumPdfs());
  if (obj_change_out != NULL) *obj_change_out = 0.0;
  if (count_out != NULL) *count_out = 0.0;
  BaseFloat tmp_obj_change, tmp_count;
  BaseFloat *p_obj = (obj_change_out != NULL) ? &tmp_obj_change : NULL,
      *p_count   = (count_out != NULL) ? &tmp_count : NULL;

  for (int32 i = 0; i < am_diag_gmm_acc.NumAccs(); i++) {
    MapDiagGmmUpdate(config, am_diag_gmm_acc.GetAcc(i), flags,
                     &(am_gmm->GetPdf(i)), p_obj, p_count);

    if (obj_change_out != NULL) *obj_change_out += tmp_obj_change;
    if (count_out != NULL) *count_out += tmp_count;
  }
}


BaseFloat AccumAmDiagGmm::TotStatsCount() const {
  double ans = 0.0;
  for (int32 i = 0; i < NumAccs(); i++) {
    const AccumDiagGmm &acc = GetAcc(i);
    ans += acc.occupancy().Sum();
  }
  return ans;
}

void AccumAmDiagGmm::Scale(BaseFloat scale) {
  for (int32 i = 0; i < NumAccs(); i++) {
    AccumDiagGmm &acc = GetAcc(i);
    acc.Scale(scale, acc.Flags());
  }
  total_frames_ *= scale;
  total_log_like_ *= scale;
}

void AccumAmDiagGmm::Add(BaseFloat scale, const AccumAmDiagGmm &other) {
  total_frames_ += scale * other.total_frames_;
  total_log_like_ += scale * other.total_log_like_;
  
  int32 num_accs = NumAccs();
  KALDI_ASSERT(num_accs == other.NumAccs());
  for (int32 i = 0; i < num_accs; i++)
    gmm_accumulators_[i]->Add(scale, *(other.gmm_accumulators_[i]));
}

void MergeGaussiansInPdfs(const AmDiagGmm &am, 
    const AccumAmDiagGmm &gmm_accs,
    const std::vector<int32> &pdf_list,
    GaussianMergingOptions opts,
    DiagGmm *gmm_out) {
  opts.Check();  // Make sure the various # of Gaussians make sense.

  // Get state occs
  Vector<BaseFloat> pdf_occs;
  pdf_occs.Resize(gmm_accs.NumAccs());

  // Count # of gaussian in the specified pdf list
  int32 num_gauss = 0;
  for (int32 kj = 0, num_pdfs = pdf_list.size(); kj < num_pdfs; kj++) {
    int32 pdf_index = pdf_list[kj];
    num_gauss += am.NumGaussInPdf(pdf_index);
    pdf_occs(pdf_index) = gmm_accs.GetAcc(pdf_index).occupancy().Sum();
  }

  if (num_gauss > opts.max_num_gauss) {
    KALDI_LOG << "MergeGaussiansInPdfs: first reducing num-gauss from " << num_gauss
      << " in " << pdf_list.size() << " pdfs of the pdf-list to " 
      << opts.max_num_gauss;
    AmDiagGmm tmp_am;
    tmp_am.CopyFromAmDiagGmm(am);
    BaseFloat power = 1.0, min_count = 1.0; // Make the power 1, which I feel
    // is appropriate to the way we're doing the overall clustering procedure.
    tmp_am.MergeByCount(pdf_occs, opts.max_num_gauss, power, min_count);

    // Count # of gaussian in the specified pdf list
    int num_gauss = 0;
    for (int32 kj = 0, num_pdfs = pdf_list.size(); kj < num_pdfs; kj++) {
      int32 pdf_index = pdf_list[kj];
      num_gauss += am.NumGaussInPdf(pdf_index);
    }

    if (num_gauss > opts.max_num_gauss) {
      KALDI_LOG << "Clustered down to " << num_gauss
        << "; will not cluster further";
      opts.max_num_gauss = num_gauss;
    }
    MergeGaussiansInPdfs(tmp_am, gmm_accs, pdf_list, opts, gmm_out);
    return;
  } 

  int32 num_pdfs = static_cast<int32>(pdf_list.size()),
        dim = am.Dim(),
        num_clust_states = num_pdfs;
  std::vector< std::vector<Clusterable*> > state_clust_gauss;

  Vector<BaseFloat> tmp_mean(dim);
  Vector<BaseFloat> tmp_var(dim);
  DiagGmm tmp_gmm;

  std::vector<int32> state_clusters;

  if (opts.reduce_state_factor != 1.0) {
    // This is typically done when the number of gaussians is very large. 
    // For example, in getting the Speech GMM.
    num_clust_states = static_cast<int32>(opts.reduce_state_factor*num_pdfs);

    std::vector<Clusterable*> states;
    states.reserve(num_pdfs);  // NOT resize(); uses push_back.

    // Replace the GMM for each state with a single Gaussian.
    KALDI_VLOG(1) << "Merging densities to 1 Gaussian per state.";
    for (int32 kj = 0; kj < num_pdfs; kj++) {
      int32 pdf_index = pdf_list[kj];
      KALDI_VLOG(3) << "Merging Gausians for state : " << pdf_index;
      tmp_gmm.CopyFromDiagGmm(am.GetPdf(pdf_index));
      tmp_gmm.Merge(1);
      tmp_gmm.GetComponentMean(0, &tmp_mean);
      tmp_gmm.GetComponentVariance(0, &tmp_var);
      tmp_var.AddVec2(1.0, tmp_mean);  // make it x^2 stats.
      BaseFloat this_weight = pdf_occs(pdf_index);
      tmp_mean.Scale(this_weight);
      tmp_var.Scale(this_weight);
      states.push_back(new GaussClusterable(tmp_mean, tmp_var,
            opts.cluster_varfloor, this_weight));
    }

    // Bottom-up clustering of the Gaussians corresponding to each state, which
    // gives a partial clustering of states in the 'state_clusters' vector.
    KALDI_VLOG(1) << "Creating " << num_clust_states << " clusters of states.";
    ClusterBottomUp(states, kBaseFloatMax, num_clust_states,
        NULL /*actual clusters not needed*/,
        &state_clusters /*get the cluster assignments*/);
    DeletePointers(&states);
  } else {
    state_clusters.resize(num_pdfs);
    for (int32 kj = 0; kj < num_pdfs; kj++) {
      state_clusters[kj] = kj;
    }
  }

  // For each cluster of states, create a pool of all the Gaussians in those
  // states, weighted by the state occupancies. This is done so that initially
  // only the Gaussians corresponding to "similar" states (similarity as
  // determined by the previous clustering) are merged.
  {
    state_clust_gauss.resize(num_clust_states);
    for (int32 kj = 0; kj < num_pdfs; kj++) {
      int32 pdf_index = pdf_list[kj];
      int32 current_cluster = state_clusters[kj];
      for (int32 num_gauss = am.GetPdf(pdf_index).NumGauss(),
          gauss_index = 0; gauss_index < num_gauss; ++gauss_index) {
        am.GetGaussianMean(pdf_index, gauss_index, &tmp_mean);
        am.GetGaussianVariance(pdf_index, gauss_index, &tmp_var);
        tmp_var.AddVec2(1.0, tmp_mean);  // make it x^2 stats.
        /* The naive way is to multiply the state occupation with the 
         * the gaussian prior. But it is possible to get this weight
         * as what it actually is as determined by the accumulated stats. */
        BaseFloat this_weight =  pdf_occs(pdf_index) *
          (am.GetPdf(pdf_index).weights())(gauss_index);
        /*
        BaseFloat this_weight = gmm_accs.GetAcc(pdf_index).occupancy()(pdf_index);
           */
        tmp_mean.Scale(this_weight);
        tmp_var.Scale(this_weight);
        state_clust_gauss[current_cluster].push_back(new GaussClusterable(
              tmp_mean, tmp_var,
              opts.cluster_varfloor, this_weight));
      }
    }
  }

  // This is an unlikely operating scenario, no need to handle this in a more
  // optimized fashion.
  if (opts.intermediate_num_gauss > num_gauss) {
    KALDI_WARN << "Intermediate num_gauss " << opts.intermediate_num_gauss
      << " is more than num-gauss " << num_gauss
      << ", reducing it to " << num_gauss;
    opts.intermediate_num_gauss = num_gauss;
  }

  // The compartmentalized clusterer used below does not merge compartments.
  if (opts.intermediate_num_gauss < num_clust_states) {
    KALDI_WARN << "Intermediate num_gauss " << opts.intermediate_num_gauss
      << " is less than # of preclustered states " << num_clust_states
      << ", increasing it to " << num_clust_states;
    opts.intermediate_num_gauss = num_clust_states;
  }

  KALDI_VLOG(1) << "Merging from " << num_gauss << " Gaussians in the "
    << "acoustic model, down to " << opts.intermediate_num_gauss
    << " Gaussians.";
  std::vector< std::vector<Clusterable*> > gauss_clusters_out;
  ClusterBottomUpCompartmentalized(state_clust_gauss, kBaseFloatMax,
      opts.intermediate_num_gauss,
      &gauss_clusters_out, NULL);

  for (int32 clust_index = 0; clust_index < num_clust_states; clust_index++)
    DeletePointers(&state_clust_gauss[clust_index]);

  // Next, put the remaining clustered Gaussians into a single GMM.
  KALDI_VLOG(1) << "Putting " << opts.intermediate_num_gauss << " Gaussians "
    << "into a single GMM for final merge step.";
  Matrix<BaseFloat> tmp_means(opts.intermediate_num_gauss, dim);
  Matrix<BaseFloat> tmp_vars(opts.intermediate_num_gauss, dim);
  Vector<BaseFloat> tmp_weights(opts.intermediate_num_gauss);
  Vector<BaseFloat> tmp_vec(dim);
  int32 gauss_index = 0;
  for (int32 clust_index = 0; clust_index < num_clust_states; clust_index++) {
    for (int32 i = gauss_clusters_out[clust_index].size()-1; i >=0; --i) {
      GaussClusterable *this_cluster = static_cast<GaussClusterable*>(
          gauss_clusters_out[clust_index][i]);
      BaseFloat weight = this_cluster->count();
      KALDI_ASSERT(weight > 0);
      tmp_weights(gauss_index) = weight;
      tmp_vec.CopyFromVec(this_cluster->x_stats());
      tmp_vec.Scale(1/weight);
      tmp_means.CopyRowFromVec(tmp_vec, gauss_index);
      tmp_vec.CopyFromVec(this_cluster->x2_stats());
      tmp_vec.Scale(1/weight);
      tmp_vec.AddVec2(-1.0, tmp_means.Row(gauss_index));  // x^2 stats to var.
      tmp_vars.CopyRowFromVec(tmp_vec, gauss_index);
      gauss_index++;
    }
    DeletePointers(&(gauss_clusters_out[clust_index]));
  }
  tmp_gmm.Resize(opts.intermediate_num_gauss, dim);
  tmp_weights.Scale(1.0/tmp_weights.Sum());
  tmp_gmm.SetWeights(tmp_weights);
  tmp_vars.InvertElements();  // need inverse vars...
  tmp_gmm.SetInvVarsAndMeans(tmp_vars, tmp_means);

  // Finally, cluster to the desired number of Gaussians in the GMM.
  if (opts.gmm_num_gauss < tmp_gmm.NumGauss()) {
    tmp_gmm.Merge(opts.gmm_num_gauss);
    KALDI_VLOG(1) << "Merged down to " << tmp_gmm.NumGauss() << " Gaussians.";
  } else {
    KALDI_WARN << "Not merging Gaussians since " << opts.gmm_num_gauss
      << " < " << tmp_gmm.NumGauss();
  }
  gmm_out->CopyFromDiagGmm(tmp_gmm);
}

}  // namespace kaldi
