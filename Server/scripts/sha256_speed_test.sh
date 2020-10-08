#!/bin/bash

[ -x "$(command -v openssl)" ]  ||  {
  echo 'OpenSSL' not found.
  exit 1
}


function timestamp {
  local ts=`date +"%Y-%m-%d %H:%M:%S"`
  echo -n $ts
}


[ -z $CREDITCOIN_HOME ]  &&  CREDITCOIN_HOME=~/Server
cd $CREDITCOIN_HOME  ||  exit 1

throughput=`openssl speed sha256 2>&1 | grep "64 size" | cut -d: -f2 |  awk '{print $1}'`
[ -n "$throughput" ]  &&  {
  timestamp
  echo " $throughput"
}  ||  exit 1

exit 0
