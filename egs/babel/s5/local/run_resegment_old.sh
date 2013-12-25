#!/bin/bash

set -o pipefail
#set -e

. cmd.sh
[ -f local.conf ] && . ./local.conf

nj=10         # nj for training subset of whole ali
train_nj=30   # nj for full training set
type=dev10h
segmentation_opts="--remove-noise-only-segments false" 
data_in=data
data_out=data_reseg
augmented=false
plpdir=exp/plp_reseg
. utils/parse_options.sh

tri4=tri4
tri4b=tri4b
if $augmented; then
  tri4=tri4_augmented
  tri4b=tri4b_augmented
fi

if [ ! -f exp/${tri4}_whole_ali_sub3/.done ]; then
  steps/align_fmllr.sh --nj $nj --cmd "$train_cmd" \
    $data_in/train_whole_sub3 $data_in/lang exp/$tri4 exp/${tri4}_whole_ali_sub3 || exit 1;
  touch exp/${tri4}_whole_ali_sub3/.done
fi

if [ ! -f exp/${tri4b}_whole_seg/.done ]; then
  steps/train_lda_mllt.sh --cmd "$train_cmd" --realign-iters "" \
    1000 10000 $data_in/train_whole_sub3 $data_in/lang exp/${tri4}_whole_ali_sub3 exp/${tri4b}_whole_seg || exit 1;
  touch exp/${tri4b}_whole_seg/.done
fi

if [ ! -f exp/${tri4}_whole_ali_all/.done ]; then
  steps/align_fmllr.sh --nj $train_nj --cmd "$train_cmd" \
    $data_in/train_whole $data_in/lang exp/${tri4} exp/${tri4}_whole_ali_all || exit 1;
  touch exp/${tri4}_whole_ali_all/.done
fi

if [ ! -f exp/${tri4b}_whole_seg/graph.done ]; then
  # Make the phone decoding-graph.
  steps/make_phone_graph.sh $data_in/lang exp/${tri4}_whole_ali_all exp/${tri4b}_whole_seg || exit 1;
  touch exp/${tri4b}_whole_seg/graph.done
fi

mkdir -p data_reseg

for data in train dev10h dev2h eval; do
  if [ "$data" != "$type" ]; then
    continue
  fi

  if [ "$data" == "train" ]; then
    my_nj=$train_nj
  else
    my_nj=$nj
  fi

  if [ ! -f $data_out/${data}_orig/.done ]; then
    mkdir -p $data_out/${data}_orig
    mkdir -p $data_out/${data}
    cp -rT $data_in/${data} $data_out/${data}_orig; rm -r $data_out/${data}_orig/split*
    for f in text utt2spk spk2utt feats.scp cmvn.scp segments; do rm $data_out/${data}_orig/$f; done
    cat $data_out/${data}_orig/wav.scp  | awk '{print $1, $1;}' | \
      tee $data_out/${data}_orig/spk2utt > $data_out/${data}_orig/utt2spk
    # dir, we'll overwrite the old data.
    mkdir -p $plpdir

    steps/make_plp.sh --cmd "$train_cmd" --nj $my_nj $data_out/${data}_orig exp/make_plp/${data}_orig $plpdir || exit 1
    # caution: the new speakers don't correspond to the old ones, since they now have "sw0" at the start..
    steps/compute_cmvn_stats.sh $data_out/${data}_orig exp/make_plp/${data}_orig $plpdir || exit 1
    touch $data_out/${data}_orig/.done
  fi

  total_time=0
  if [ ! -f exp/${tri4b}_whole_seg/decode_${data}_orig/.done ]; then
    t1=$(date +%s)
    steps/decode_nolats.sh --write-words false --write-alignments true \
      --cmd "$decode_cmd" --nj $my_nj --beam 7.0 --max-active 1000 \
      exp/${tri4b}_whole_seg/phone_graph $data_out/${data}_orig exp/${tri4b}_whole_seg/decode_${data}_orig || exit 1
    touch exp/${tri4b}_whole_seg/decode_${data}_orig/.done
    t2=$(date +%s)
    total_time=$((total_time + t2 - t1))
    echo "Phone decoding done in $((t2-t1)) seconds" 
  fi
  
  if [ ! -f exp/${tri4b}_whole_resegment_${data}/.done ]; then
    t1=$(date +%s)
    [ -f $data_out/$data/segments ] && rm $data_out/$data/segments
    sh -x steps/resegment_data.sh --segmentation_opts "$segmentation_opts" --cmd "$train_cmd" $data_out/${data}_orig $data_in/lang \
      exp/${tri4b}_whole_seg/decode_${data}_orig $data_out/$data exp/${tri4b}_whole_resegment_${data} || exit 1
    [ ! -f $data_out/$data/segments ] && exit 1
    cp $data_out/$data/segments exp/${tri4b}_whole_resegment_${data}
    touch exp/${tri4b}_whole_resegment_${data}/.done
    t2=$(date +%s)
    total_time=$((total_time + t2 - t1))
    echo "Resegment data done in $((t2-t1)) seconds" 
  fi

  if [ "$data" == "train" ]; then
    # Here: resegment.
    # Note: it would be perfectly possible to use exp/tri3b_ali_train here instead
    # of exp/tri4b_seg/decode_train_orig.  In this case we'd be relying on the transcripts.
    # I chose not to do this for more consistency with what happens in test time.

    # We need all the training data to be aligned (not just "train_nodup"), in order
    # to get the resegmented "text".
    if [ ! -f exp/${tri4}_whole_ali_train/.done ]; then
      steps/align_fmllr.sh --nj $my_nj --cmd "$train_cmd" \
        $data_in/train $data_in/lang exp/${tri4} exp/${tri4}_whole_ali_train || exit 1;
      touch exp/${tri4}_whole_ali_train/.done
    fi
    
    if [ ! -f $data_out/train/text ]; then
      # Get the file $data_out/train/text
      steps/resegment_text.sh --cmd "$train_cmd" $data_in/train $data_in/lang \
        exp/${tri4}_whole_ali_train $data_out/train exp/${tri4b}_whole_resegment_train
    fi
  fi
  
  if [ ! -f $data_out/${data}/.done ]; then
    t1=$(date +%s)
    utils/fix_data_dir.sh $data_out/${data}
    utils/validate_data_dir.sh --no-feats --no-text $data_out/${data}

    steps/make_plp.sh --cmd "$train_cmd" --nj $my_nj $data_out/${data} exp/make_plp/${data} $plpdir 
    # caution: the new speakers don't correspond to the old ones, since they now have "sw0" at the start..
    steps/compute_cmvn_stats.sh $data_out/${data} exp/make_plp/${data} $plpdir 
    utils/fix_data_dir.sh $data_out/${data} || exit 1;

    evaluate_segmentation.pl ${data_in}/$data/segments ${data_out}/$data/segments &> exp/${tri4b}_whole_resegment_$data/segment_evaluation.log

    t2=$(date +%s)
    total_time=$((total_time + t2 - t1))
    echo "Feature extraction done in $((t2-t1)) seconds" 
    
    touch $data_out/${data}/.done
  fi
  echo "Resegmentation of $data took $total_time seconds"
done

echo ---------------------------------------------------------------------
echo "Resegment data Finished successfully on" `date`
echo ---------------------------------------------------------------------

exit 0
