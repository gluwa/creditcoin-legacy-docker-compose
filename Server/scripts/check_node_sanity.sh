#!/bin/bash


[ -x "$(command -v nc)" ]  ||  {
  echo 'netcat' not found.
  exit 1
}


function timestamp {
  local ts=`date +"%Y-%m-%d %H:%M:%S"`
  echo -n $ts
}


function get_block_tip {
  curl http://$REST_API_ENDPOINT/blocks 2>/dev/null | grep -o '"block_num": "[^"]*' | head -1 | cut -d'"' -f4
  return $?
}


function check_if_stagnant_state {
  local block_tip=$(get_block_tip)
  [ -z $block_tip ]  &&  return 1

  local previous_block_tip=`cat $CREDITCOIN_HOME/.last_block_tip 2>/dev/null`  &&  {
    [ $block_tip = $previous_block_tip ]  &&  {
      rm $CREDITCOIN_HOME/.last_block_tip 2>/dev/null
      return 1    # Validator is stagnant since block tip hasn't changed since last run
    }
  }

  echo $block_tip > $CREDITCOIN_HOME/.last_block_tip

  return 0
}


# find open descriptors for all Validator processes
function log_number_of_open_descriptors {
  local validator_pids=`ps -ef | grep "[u]sr/bin/sawtooth-validator" | awk '{print $2}'`
  for v in $validator_pids; do
    open_this_vpid=`sudo vpid=$v sh -c 'lsof -p $vpid | wc -l'`
    open_descriptors=$((open_descriptors + open_this_vpid))
  done
  timestamp
  echo " Open file descriptors: $open_descriptors"

  return 0
}


# log public IP address daily to confirm it's static
function log_public_ip_address {
  # crontab job is scheduled to run twice an hour; use first one
  (( $(date +%H) == 3 ))  &&  (( $(date +%M) < 30 ))  &&  {
    local public_ipv4_address=`curl https://ifconfig.me 2>/dev/null`
    timestamp
    [ -n "$public_ipv4_address" ]  &&  {
      echo " Public IP address is $public_ipv4_address"
    } || {
      echo " Unable to query public IP address."
      return 1
    }
  }
  return 0
}


# For dynamic peering, need to log 'netcat' probe results to view history of connected peers over time.
function probe_endpoints_of_validator_peers {
  local peers=`curl http://$REST_API_ENDPOINT/peers 2>/dev/null | grep tcp:// | cut -d \" -f2 | sed 's/^.*\///'`
  local -n return_open_peers=$1
  local open=0

  for p in $peers; do
    local ipv4_address=`echo $p | cut -d: -f1`
    local port=`echo $p | cut -d: -f2`
    local preamble=" Peer $ipv4_address:$port is"

    if nc -4 -z -w 1 $ipv4_address $port
    then
      timestamp
      echo "$preamble open"
      open=$((open + 1))
    else
      timestamp
      echo "$preamble closed"
    fi
  done

  return_open_peers=$open

  return 0
}


max_peers=`ps -ef | grep -oP '(?<=maximum-peer-connectivity )[0-9]+' | head -1`
[ -z $max_peers ]  &&  {
  timestamp
  echo " Validator is not running"
  exit 1
}

log_public_ip_address

[ -z $CREDITCOIN_HOME ]  &&  CREDITCOIN_HOME=~/Server
[ -z $REST_API_ENDPOINT ]  &&  REST_API_ENDPOINT=localhost:8008

open_peers=0
probe_endpoints_of_validator_peers open_peers  ||  exit 1

log_number_of_open_descriptors || exit 1

if (($open_peers < 2))
then
  tty -s  &&  {
    read -p "Number of open Validator peers is $open_peers.  Restart Creditcoin node? (y/n) " yn
    case $yn in
    [Yy]*) $CREDITCOIN_HOME/start_creditcoin.sh  ||  exit 1
           ;;
    *) ;;
    esac
  } || {
    # crontab job
    if (($open_peers == 0))
    then
      $CREDITCOIN_HOME/start_creditcoin.sh  ||  exit 1
    else
      check_if_stagnant_state  ||  $CREDITCOIN_HOME/start_creditcoin.sh  ||  exit 1
    fi
  }
fi

exit 0
