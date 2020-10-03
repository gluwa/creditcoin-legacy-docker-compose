#!/bin/bash

[ -x "$(command -v nc)" ]  ||  {
  echo 'netcat' not found.
  exit 1
}

[ -x "$(command -v openssl)" ]  ||  {
  echo 'OpenSSL' not found.
  exit 1
}

[ -x "$(command -v docker-compose)" ]  ||  {
  echo 'docker-compose' not found.
  exit 1
}


function restart_creditcoin_node {
  local docker_compose=`ls -t *.yaml | head -1`
  [ -z $docker_compose ]  &&  return 1

  public_ipv4_address=`curl https://ifconfig.me 2>/dev/null`
  [ -z $public_ipv4_address ]  &&  {
    echo Unable to query public IP address.
    return 1
  }

  sed -i "s/\(endpoint tcp:\/\/\).*\(:\)/\1$public_ipv4_address\2/g" $docker_compose
  validator_endpoint_port=`grep endpoint $docker_compose | cut -d: -f3 | awk '{print $1}'`

  sudo docker-compose -f $docker_compose down 2>/dev/null
  if sudo docker-compose -f $docker_compose up -d
  then
    echo Started Creditcoin node

    # check if Validator endpoint is reachable from internet
    nc -4 -z -w 1  $public_ipv4_address  $validator_endpoint_port  ||  {
      echo -n "TCP port $validator_endpoint_port isn't open. "
      validator=`ps -ef | grep "[u]sr/bin/sawtooth-validator"`
      [[ -z $validator ]]  &&  echo "Validator isn't running."  ||  echo Check firewall rules.
      return 1
    }

    rc=0
  else
    echo Failed to start Creditcoin node
    rc=1
  fi

  return $rc
}


function run_sha256_speed_test {
  local SHA256_SPEED=sha256_speed.txt
  [ -f $SHA256_SPEED ]  ||  {
    echo Checking processing specification of this machine
    local BASELINE=7565854    # measured on Xeon Platinum 8171M CPU @ 2.60GHz
    openssl speed sha256 2>$SHA256_SPEED >/dev/null
    local throughput=`grep "64 size" $SHA256_SPEED | cut -d: -f2 |  awk '{print $1}'`
    if (( throughput < BASELINE ))
    then
      echo This machine lacks sufficient power to run Creditcoin software.
      return 1
    fi
  }
  return 0
}


[ -z $CREDITCOIN_HOME ]  &&  CREDITCOIN_HOME=~/Server
cd $CREDITCOIN_HOME  ||  exit 1
echo CREDITCOIN_HOME is $CREDITCOIN_HOME

run_sha256_speed_test  ||  exit 1
restart_creditcoin_node  ||  exit 1

exit 0
