grep "ATWV" $1/kws_*/metrics.txt | cut -f 1 -d ',' | sed 's/:.* = / /g' | sort -t ' ' -k 2 -r | head -1 | awk '{print $2" "$1}'
