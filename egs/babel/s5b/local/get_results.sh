find exp/tri6_nnet_supervised_tuning/decode_dev10h  -name "metrics.txt"   | xargs grep "ATWV" | cut -f 1 -d ',' | sed 's/:.* = / /g' | sort -t ' ' -k 2 -r | head -1
