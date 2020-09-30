#!/bin/bash

[ -x "$(command -v nc)" ]  ||  {
  echo 'netcat' not found.
  exit 1
}


timestamp() {
  local ts=`date +"%Y-%m-%d %H:%M:%S"`
  echo -n $ts
}


function get_block_tip {
  curl http://$REST_API_ENDPOINT/blocks 2>/dev/null | grep -o '"block_num": "[^"]*' | head -1 | cut -d'"' -f4
}


function check_if_stagnant_state {
  local block_tip=$(get_block_tip)
  [ -z $block_tip ]  &&  return 1

  previous_block_tip=`cat $CREDITCOIN_HOME/.last_block_tip.txt 2>/dev/null`  &&  {
    [ $block_tip = $previous_block_tip ]  &&  {
      rm $CREDITCOIN_HOME/.last_block_tip.txt
      return 1    # Validator is stagnant since block tip hasn't changed since last run
    }
  }

  echo $block_tip > $CREDITCOIN_HOME/.last_block_tip.txt

  return 0
}


function restart_creditcoin_node {
  cd $CREDITCOIN_HOME  ||  return 1
  docker_compose=`ls -t *.yaml | head -1`
  [ -z $docker_compose ]  &&  return 1

  [ -x "$(command -v docker-compose)" ]  ||  {
    echo 'docker-compose' not found.
    return 1
  }

  timestamp
  echo " Resetting Creditcoin node"
  sudo docker-compose -f $docker_compose down 2>/dev/null
  sudo docker-compose -f $docker_compose up -d  &&  {
    timestamp
    echo " Restarted Creditcoin node"
  }

  return 0
}


max_peers=`ps -ef | grep -oP '(?<=maximum-peer-connectivity )[0-9]+' | head -1`
[ -z $max_peers ]  &&  {
  timestamp
  echo " Validator is not running"
  exit 1
}

[ -z $CREDITCOIN_HOME ]  &&  CREDITCOIN_HOME=~/Server
[ -z $REST_API_ENDPOINT ]  &&  REST_API_ENDPOINT=localhost:8008

peers=`curl http://$REST_API_ENDPOINT/peers 2>/dev/null | grep tcp:// | cut -d \" -f2 | sed 's/^.*\///'`


# For dynamic peering, need to log 'netcat' probe results to view history of connected peers over time.

open_peers=0
for p in $peers; do
  ipv4_address=`echo $p | cut -d: -f1`
  port=`echo $p | cut -d: -f2`
  preamble=" Peer $ipv4_address:$port is"

  if nc -4 -z -w 1 $ipv4_address $port
  then
    timestamp
    echo "$preamble open"
    open_peers=$((open_peers + 1))
  else
    timestamp
    echo "$preamble closed"
  fi
done


# find open descriptors for all Validator processes

validator_pids=`ps -ef | grep "[u]sr/bin/sawtooth-validator" | awk '{print $2}'`
for v in $validator_pids; do
  open_this_vpid=`sudo vpid=$v sh -c 'lsof -p $vpid | wc -l'`
  open_descriptors=$((open_descriptors + open_this_vpid))
done
timestamp
echo " Open file descriptors: $open_descriptors"


if (($open_peers < 2))
then
  if (($open_peers == 0))
  then
    restart_creditcoin_node  ||  exit 1
  else
    tty -s  &&  {
      restart_creditcoin_node  ||  exit 1
    } || {
      # crontab job
      check_if_stagnant_state  ||  restart_creditcoin_node  ||  exit 1
    }
  fi
fi

exit 0
