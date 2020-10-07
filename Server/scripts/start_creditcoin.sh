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


function check_if_different_ipv4_subnet {
  local candidate=$1
  local seed=$2

  read c_octet1 c_octet2 c_octet3 c_octet4 <<<"${candidate//./ }"
  read s_octet1 s_octet2 s_octet3 s_octet4 <<<"${seed//./ }"
  [ $c_octet1 = $s_octet1 ]  &&  [ $c_octet2 = $s_octet2 ]  &&  return 1

  return 0
}


function evaluate_candidates_for_dynamic_peering {
  [ -f $CREDITCOIN_HOME/check_node_sanity.log ]  ||  return 1

  local -n seeds_array_reference=$1
  local seeds_array_length=${#seeds_array_reference[@]}
  local unique_open_peers_by_frequency=`grep open $CREDITCOIN_HOME/check_node_sanity.log | awk '{print $4}' | sort | uniq -c | sort -nr | awk '{print $2}' | tr '\r\n' ' '`
  local s=0

  # iterate over open peers from most to least frequent
  for open_peer in $unique_open_peers_by_frequency; do
    host=`echo $open_peer | cut -d: -f1`
    port=`echo $open_peer | awk -F: '{print $2}'`

    different_subnet=true
    ((s > 0))  &&  {
      # select candidates from different subnets
      for seed in "${seeds_array_reference[@]}"
      do
        [ -n "$seed" ]  &&  {
          check_if_different_ipv4_subnet $host $seed  ||  {
            different_subnet=false
            break
          }
        }
      done
    }

    [ $different_subnet = true ]  &&  nc -z -w 1 $host $port  &&  {
      seeds_array_reference[$s]=$open_peer
      ((++s == $seeds_array_length))  &&  break
    }
  done

  return 0
}


function restart_creditcoin_node {
  local docker_compose=`ls -t *.yaml | head -1`
  [ -z $docker_compose ]  &&  return 1

  local public_ipv4_address=`curl https://ifconfig.me 2>/dev/null`
  [ -z $public_ipv4_address ]  &&  {
    echo Unable to query public IP address.
    return 1
  }

  local last_public_ipv4_address=`grep "Public IP" $CREDITCOIN_HOME/check_node_sanity.log | tail -1 | awk '{print $NF}'`
  [ -n "$last_public_ipv4_address" ]  &&  [ $last_public_ipv4_address != $public_ipv4_address ]  &&  {
    # write warning to stderr
    >&2 echo "Warning: Public IP address has recently changed.  Creditcoin nodes cannot have dynamic IP addresses."
  }

  # replace advertised Validator endpoint with current public IP address; retain existing port number
  sed -i "s~\(endpoint tcp://\).*\(:\)~\1$public_ipv4_address\2~g" $docker_compose

  if grep -q "peering dynamic" $docker_compose
  then
    local seeds=([0]="" [1]="" [2]="")
    evaluate_candidates_for_dynamic_peering seeds  &&  sed -i '/seeds tcp:.*\\/d' $docker_compose    # remove existing seeds

    # insert new seeds into .yaml file
    preamble="                --seeds tcp://"
    for seed in "${seeds[@]}"
    do
      [ -n "$seed" ]  &&  sed -i '/peering dynamic.*\\/ s~^~'"$preamble$seed"' \\\n~' $docker_compose
    done
  fi

  sudo docker-compose -f $docker_compose down 2>/dev/null
  if sudo docker-compose -f $docker_compose up -d
  then
    echo Started Creditcoin node

    # check if Validator endpoint is reachable from internet
    local validator_endpoint_port=`grep endpoint $docker_compose | cut -d: -f3 | awk '{print $1}'`
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
  local days_since_epoch=`expr $(date +%s) / 86400`
  local run_test=false
  local sha256_speed_file=`ls -t sha256_speed.* 2>/dev/null | head -1`

  [ -z "$sha256_speed_file" ]  &&  run_test=true  ||  {
    local last_speed_test="${sha256_speed_file##*.}"    # file extension is days since epoch
    (($days_since_epoch - $last_speed_test >= 30))  &&  run_test=true  ||  run_test=false
  }

  [ $run_test = true ]  &&  {
    echo Checking processing specification of this machine
    local BASELINE=7565854    # measured on Xeon Platinum 8171M CPU @ 2.60GHz
    sha256_speed_file=sha256_speed.$days_since_epoch
    openssl speed sha256 2>$sha256_speed_file >/dev/null
    local throughput=`grep "64 size" $sha256_speed_file | cut -d: -f2 |  awk '{print $1}'`
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
