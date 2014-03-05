export G2P=/home/vmanoha1/kaldi-trunk/tools/sequitur
export PATH=$PATH:${G2P}/bin
_site_packages=`readlink -f ${G2P}/lib/python*/site-packages`
export PYTHONPATH=$PYTHONPATH:$_site_packages
