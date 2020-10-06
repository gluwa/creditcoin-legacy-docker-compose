#!/bin/bash

[ -z $CREDITCOIN_HOME ]  &&  CREDITCOIN_HOME=~/Server
cd $CREDITCOIN_HOME  ||  exit 1


function remove_job_that_runs_sanity_script {
  sudo rm /etc/logrotate.d/creditcoin_node_logs 2>/dev/null
  crontab -l | grep -v CREDITCOIN_HOME | crontab -
  return $?
}


function schedule_job_to_run_sanity_script {
  local rc=0

  # allow sudo execution in crontab without tty
  cc_user=`whoami`
  sudo grep -q "$cc_user ALL" /etc/sudoers  ||  {
    echo "$cc_user ALL=(ALL) NOPASSWD:SETENV: /usr/bin/docker-compose, /bin/sh" | sudo EDITOR='tee -a' visudo >/dev/null
  }


  crontab -l | grep -q CREDITCOIN_HOME  ||  {
    # schedule job to periodically run sanity script by appending to current schedule

    echo CREDITCOIN_HOME is $CREDITCOIN_HOME
    minutes_after_hour1=$((`date +%s` % 30))
    minutes_after_hour2=$(($minutes_after_hour1 + 30))

    (crontab -l 2>/dev/null;
     echo CREDITCOIN_HOME=$CREDITCOIN_HOME;
     echo "$minutes_after_hour1,$minutes_after_hour2 * * * * \$CREDITCOIN_HOME/check_node_sanity.sh >> \$CREDITCOIN_HOME/check_node_sanity.log 2>>\$CREDITCOIN_HOME/check_node_sanity-error.log") | crontab -

    rc=$?
    schedule_rotation_of_node_sanity_logs
  }

  return $rc
}


function schedule_rotation_of_node_sanity_logs {
  sudo cc_user=`whoami` CREDITCOIN_HOME=$CREDITCOIN_HOME sh -c 'cat > /etc/logrotate.d/creditcoin_node_logs << EOF
$CREDITCOIN_HOME/check_node_sanity.log {
       su $cc_user $cc_user
       daily
       rotate 30
       delaycompress
       compress
       notifempty
       missingok
       create 644 $cc_user $cc_user
}
$CREDITCOIN_HOME/check_node_sanity-error.log {
       su $cc_user $cc_user
       daily
       rotate 30
       delaycompress
       compress
       notifempty
       missingok
       create 644 $cc_user $cc_user
}
EOF'

  return 0
}


function validate_rpc_url {
  local rpc_mainnet=$1
  [ -z $rpc_mainnet ]  &&  return 1

  fqdn_port=`echo $rpc_mainnet | awk -F/ '{print $3}'`
  fqdn=`echo $fqdn_port | cut -d: -f1`
  port=`echo $fqdn_port | awk -F: '{print $2}'`    # initially assume user specified UDP port number of an RPC proxy

  udp="-u"
  [ -z $port ]  &&  {
    # no UDP port was specified; transport is HTTP/S, ie, TCP
    udp=
    transport=`echo $rpc_mainnet | cut -d: -f1`
    [ $transport = https ]  &&  port=443  ||  {
      [ $transport = http ]  &&  port=80
    }
  }

  nc -z $udp -w 1 $fqdn $port
  rc=$?
  [ $rc = 1 ]  &&  echo "Warning: RPC port at $rpc_mainnet isn't open"

  return $rc
}


function define_fields_in_gateway_config {
  local GATEWAY_CONFIG=gatewayConfig.json
  echo "Enter RPC mainnet nodes (eg. https://mainnet.infura.io/v3/...  or  http://localhost:8545)."

  # remove any existing RPC URLs
  cp -p $GATEWAY_CONFIG "$GATEWAY_CONFIG"_orig
  sed -i '/"rpc"/d' $GATEWAY_CONFIG

  read -p "Bitcoin RPC: " bitcoin_rpc
  validate_rpc_url $bitcoin_rpc  &&  {
    sed -i "s~<bitcoin_rpc_node_url>~$bitcoin_rpc~w btc_change.txt" $GATEWAY_CONFIG    # delimiter is ~ since RPC URL contains /
    [ -s btc_change.txt ]  ||  {
      # original <bitcoin_..._url> not found; insert new value
      sed -i 's~"bitcoin"[[:blank:]]*:[[:blank:]]*{~&\n        "rpc": "'$bitcoin_rpc'",~' $GATEWAY_CONFIG
    }
    rm btc_change.txt 2>/dev/null
  }  ||  {
    mv "$GATEWAY_CONFIG"_orig $GATEWAY_CONFIG
    return 1
  }

  read -p "Ethereum RPC: " ethereum_rpc
  validate_rpc_url $ethereum_rpc  &&  {
    sed -i "s~<ethereum_node_url>~$ethereum_rpc~w eth_change.txt" $GATEWAY_CONFIG
    [ -s eth_change.txt ]  ||  {
      sed -i 's~"ethereum"[[:blank:]]*:[[:blank:]]*{~&\n        "rpc": "'$ethereum_rpc'",~' $GATEWAY_CONFIG
      sed -i 's~"ethless"[[:blank:]]*:[[:blank:]]*{~&\n        "rpc": "'$ethereum_rpc'",~' $GATEWAY_CONFIG
      sed -i 's~"erc20"[[:blank:]]*:[[:blank:]]*{~&\n        "rpc": "'$ethereum_rpc'",~' $GATEWAY_CONFIG
    }
    rm eth_change.txt 2>/dev/null
  }  ||  {
    mv "$GATEWAY_CONFIG"_orig $GATEWAY_CONFIG
    return 1
  }

  rm "$GATEWAY_CONFIG"_orig 2>/dev/null

  return 0
}


for i in "$@"
do
case $i in
    -r*|--remove*)
    remove_job_that_runs_sanity_script  &&  exit 0  ||  exit 1
    ;;
    *)
    ;;
esac
done

schedule_job_to_run_sanity_script  ||  exit 1
define_fields_in_gateway_config  ||  exit 1

exit 0
