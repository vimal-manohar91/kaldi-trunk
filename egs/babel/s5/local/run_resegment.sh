#!/bin/bash

set -o pipefail
#set -e

. cmd.sh
. lang.conf

nj=10         # nj for training subset of whole ali
train_nj=30   # nj for full training set
type=dev10h
remove_oov=false
segmentation_opts="--remove-noise-only-segments false" 
data=data
initial=false

. utils/parse_options.sh

data_in=$data
data_out=$data

tri4=tri4
tri4b=tri4b

if $initial; then
  tri4=tri4_initial
  tri4b=tri4b_initial
fi

function make_plp {
  t=$1
  data=$2
  plpdir=$3

  if [ "$use_pitch" = "false" ] && [ "$use_ffv" = "false" ]; then
   steps/make_plp.sh --cmd "$decode_cmd" --nj $my_nj ${data}/${t} exp/make_plp/${t} ${plpdir}
  elif [ "$use_pitch" = "true" ] && [ "$use_ffv" = "true" ]; then
    cp -rT ${data}/${t} ${data}/${t}_plp; cp -rT ${data}/${t} ${data}/${t}_pitch; cp -rT ${data}/${t} ${data}/${t}_ffv
    steps/make_plp.sh --cmd "$decode_cmd" --nj $my_nj ${data}/${t}_plp exp/make_plp/${t} plp_tmp_${t}
    local/make_pitch.sh --cmd "$decode_cmd" --nj $my_nj ${data}/${t}_pitch exp/make_pitch/${t} pitch_tmp_${t}
    local/make_ffv.sh --cmd "$decode_cmd"  --nj $my_nj ${data}/${t}_ffv exp/make_ffv/${t} ffv_tmp_${t}
    steps/append_feats.sh --cmd "$decode_cmd" --nj $my_nj ${data}/${t}{_plp,_pitch,_plp_pitch} exp/make_pitch/append_${t}_pitch plp_tmp_${t}
    steps/append_feats.sh --cmd "$decode_cmd" --nj $my_nj ${data}/${t}{_plp_pitch,_ffv,} exp/make_ffv/append_${t}_pitch_ffv ${plpdir}
    rm -rf {plp,pitch,ffv}_tmp_${t} ${data}/${t}_{plp,pitch,plp_pitch}
  elif [ "$use_pitch" = "true" ]; then
    cp -rT ${data}/${t} ${data}/${t}_plp; cp -rT ${data}/${t} ${data}/${t}_pitch
    steps/make_plp.sh --cmd "$decode_cmd" --nj $my_nj ${data}/${t}_plp exp/make_plp/${t} plp_tmp_${t}
    local/make_pitch.sh --cmd "$decode_cmd" --nj $my_nj ${data}/${t}_pitch exp/make_pitch/${t} pitch_tmp_${t}
    steps/append_feats.sh --cmd "$decode_cmd" --nj $my_nj ${data}/${t}{_plp,_pitch,} exp/make_pitch/append_${t} ${plpdir}
    rm -rf {plp,pitch}_tmp_${t} ${data}/${t}_{plp,pitch}
  elif [ "$use_ffv" = "true" ]; then
    cp -rT ${data}/${t} ${data}/${t}_plp; cp -rT ${data}/${t} ${data}/${t}_ffv
    steps/make_plp.sh --cmd "$decode_cmd" --nj $my_nj ${data}/${t}_plp exp/make_plp/${t} plp_tmp_${t}
    local/make_ffv.sh --cmd "$decode_cmd" --nj $my_nj ${data}/${t}_ffv exp/make_ffv/${t} ffv_tmp_${t}
    steps/append_feats.sh --cmd "$decode_cmd" --nj $my_nj ${data}/${t}{_plp,_ffv,} exp/make_ffv/append_${t} ${plpdir}
    rm -rf {plp,ffv}_tmp_${t} ${data}/${t}_{plp,ffv}
  fi
  steps/compute_cmvn_stats.sh ${data}/${t} exp/make_plp/${t} ${plpdir}
  utils/fix_data_dir.sh ${data}/${t}
}

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

mkdir -p $data_out

for d in train dev10h dev2h eval; do
  if [ "$d" != "$type" ]; then
    continue
  fi

  if [ "$d" == "train" ]; then
    my_nj=$train_nj
  else
    my_nj=$nj
  fi

  dirid=${d}.seg

  if [ ! -f $data_out/${dirid}.orig/.done ]; then
    mkdir -p $data_out/${dirid}.orig
    mkdir -p $data_out/${dirid}
    cp -rT $data_in/${d} $data_out/${dirid}.orig; rm -r $data_out/${dirid}.orig/split*
    for f in text utt2spk spk2utt feats.scp cmvn.scp segments; do rm $data_out/${dirid}.orig/$f; done
    cat $data_out/${dirid}.orig/wav.scp  | awk '{print $1, $1;}' | \
      tee $data_out/${dirid}.orig/spk2utt > $data_out/${dirid}.orig/utt2spk
    plpdir=exp/plp.seg.orig # don't use plp because of the way names are assigned within that
    # dir, we'll overwrite the old data.
    mkdir -p $plpdir
  
    make_plp ${dirid}.orig $data_out $plpdir || exit 1

    touch $data_out/${dirid}.orig/.done
  fi

  total_time=0
  if [ ! -f exp/${tri4b}_whole_seg/decode_${dirid}.orig/.done ]; then
    t1=$(date +%s)
    steps/decode_nolats.sh --write-words false --write-alignments true \
      --cmd "$decode_cmd" --nj $my_nj --beam 7.0 --max-active 1000 \
      exp/${tri4b}_whole_seg/phone_graph $data_out/${dirid}.orig exp/${tri4b}_whole_seg/decode_${dirid}.orig || exit 1
    touch exp/${tri4b}_whole_seg/decode_${dirid}.orig/.done
    t2=$(date +%s)
    total_time=$((total_time + t2 - t1))
    echo "Phone decoding done in $((t2-t1)) seconds" 
  fi
  
  if [ ! -f exp/${tri4b}_whole_resegment_${d}/.done ]; then
    t1=$(date +%s)
    [ -f $data_out/$dirid/segments ] && rm $data_out/$dirid/segments
    sh -x steps/resegment_data.sh --segmentation_opts "$segmentation_opts" --cmd "$train_cmd" $data_out/${dirid}.orig $data_in/lang \
      exp/${tri4b}_whole_seg/decode_${dirid}.orig $data_out/$dirid exp/${tri4b}_whole_resegment_${d} || exit 1
    [ ! -f $data_out/$d/segments ] && exit 1
    cp $data_out/$d/segments exp/${tri4b}_whole_resegment_${d}
    touch exp/${tri4b}_whole_resegment_${d}/.done
    t2=$(date +%s)
    total_time=$((total_time + t2 - t1))
    echo "Resegment data done in $((t2-t1)) seconds" 
  fi

  if [ "$d" == "train" ]; then
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
        exp/${tri4}_whole_ali_train $data_out/train.seg exp/${tri4b}_whole_resegment_train
    fi
  fi
  
  if [ ! -f $data_out/${dirid}/.done ]; then
    t1=$(date +%s)
    utils/fix_data_dir.sh $data_out/${dirid}
    utils/validate_data_dir.sh --no-feats --no-text $data_out/${dirid}
    plpdir=exp/plp.seg # don't use plp because of the way names are assigned within that
    # dir, we'll overwrite the old data.
    mkdir -p $plpdir

    make_plp $dirid $data_out $plpdir

    utils/evaluate_segmentation.pl ${data_in}/$d/segments ${data_out}/$dirid/segments &> exp/${tri4b}_whole_resegment_$d/segment_evaluation.log

    t2=$(date +%s)
    total_time=$((total_time + t2 - t1))
    echo "Feature extraction done in $((t2-t1)) seconds" 
    
    touch $data_out/${dirid}/.done
  fi
  echo "Resegmentation of $d took $total_time seconds"
done

echo ---------------------------------------------------------------------
echo "Resegment data Finished successfully on" `date`
echo ---------------------------------------------------------------------

exit 0
