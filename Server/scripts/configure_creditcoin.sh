#!/bin/bash

[ -z $CREDITCOIN_HOME ]  &&  CREDITCOIN_HOME=~/Server
echo CREDITCOIN_HOME is $CREDITCOIN_HOME
cd $CREDITCOIN_HOME  ||  exit 1


function define_login_profile_macos {
  local profile_reference
  local shell=`basename $SHELL`
  case $shell in
    zsh)
      profile_reference=~/.zprofile
      ;;
    bash)
      profile_reference=~/.bash_profile
      ;;
    *) echo "Unsupported shell: $shell"
       return 1
       ;;
  esac
  eval $1=\$profile_reference
  return 0
}


function define_creditcoin_home_in_bashrc {
  grep -q CREDITCOIN_HOME $BASH_RC 2>/dev/null  ||  {
    local user_entered
    while :
    do
      read -p "Enter CREDITCOIN_HOME ($CREDITCOIN_HOME): " user_entered
      [ -z "$user_entered" ]  &&  break
      [ -d $user_entered ]  &&  {
        CREDITCOIN_HOME=$user_entered
        break
      }  ||  echo $user_entered not found.
    done

    cat >> $BASH_RC << EOF
export CREDITCOIN_HOME=$CREDITCOIN_HOME
EOF
  }

  return 0
}


function remove_job_that_runs_sanity_script {
  local SUDOERS=/etc/sudoers

  sed -i.bak "/CREDITCOIN_HOME/d" $BASH_RC  &&  rm ${BASH_RC}.bak
  cc_user=`whoami`
  sudo sed -i.bak "/$cc_user.*Creditcoin$/d" $SUDOERS  &&  sudo rm ${SUDOERS}.bak
  sudo rm /etc/logrotate.d/creditcoin_node_logs 2>/dev/null
  crontab -l | grep -v CREDITCOIN_HOME | crontab -

  return $?
}


function schedule_job_to_run_sanity_script {
  local rc=0

  # allow sudo execution in crontab without tty
  cc_user=`whoami`
  sudo grep -q "$cc_user.*Creditcoin$" /etc/sudoers  ||  {
    local INIT_SERVICE
    [ $(uname -s) = Linux ]  &&  INIT_SERVICE=/usr/sbin/service,
    echo "$cc_user ALL=(ALL) NOPASSWD:SETENV: /usr/bin/docker-compose, $INIT_SERVICE /bin/sh    # Creditcoin" | sudo EDITOR='tee -a' visudo >/dev/null
  }

  crontab -l | grep -q CREDITCOIN_HOME  ||  {
    minutes_after_hour_1=$((`date +%s` % 30))
    minutes_after_hour_2=$(($minutes_after_hour_1 + 30))

    # schedule jobs to:
    #   a) run SHA-256 speed test after host bootup
    #   b) periodically run node sanity script
    (crontab -l 2>/dev/null;
     echo CREDITCOIN_HOME=$CREDITCOIN_HOME;
     echo "@reboot (sleep 60; \$CREDITCOIN_HOME/sha256_speed_test.sh >>\$CREDITCOIN_HOME/sha256_speed.log 2>/dev/null)";
     echo "$minutes_after_hour_1,$minutes_after_hour_2 * * * * \$CREDITCOIN_HOME/check_node_sanity.sh >>\$CREDITCOIN_HOME/check_node_sanity.log 2>>\$CREDITCOIN_HOME/check_node_sanity-error.log") | crontab -    # append to current schedule

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

  $NETCAT -z $udp -w 1 $fqdn $port
  rc=$?
  [ $rc = 1 ]  &&  echo "Warning: RPC port at $rpc_mainnet isn't open"

  return $rc
}


function define_fields_in_gateway_config {
  local GATEWAY_CONFIG=gatewayConfig.json
  echo "Enter RPC mainnet nodes (eg. https://mainnet.infura.io/v3/...  or  http://localhost:8545)."

  # remove any existing RPC URLs
  cp -p $GATEWAY_CONFIG "$GATEWAY_CONFIG"_orig
  sed -i.bak '/"rpc"/d' $GATEWAY_CONFIG  &&  rm ${GATEWAY_CONFIG}.bak

  read -p "Bitcoin RPC: " bitcoin_rpc
  validate_rpc_url $bitcoin_rpc  &&  {
    sed -i.bak "s~<bitcoin_rpc_node_url>~$bitcoin_rpc~w btc_change.txt" $GATEWAY_CONFIG  &&  rm ${GATEWAY_CONFIG}.bak    # delimiter is ~ since RPC URL contains /
    [ -s btc_change.txt ]  ||  {
      # original <bitcoin_..._url> not found; insert new value
      sed -i.bak 's~"bitcoin"[[:blank:]]*:[[:blank:]]*{~&\'$'\n''        "rpc": "'$bitcoin_rpc'",~' $GATEWAY_CONFIG  &&  rm ${GATEWAY_CONFIG}.bak
    }
    rm btc_change.txt 2>/dev/null
  }  ||  {
    mv "$GATEWAY_CONFIG"_orig $GATEWAY_CONFIG
    return 1
  }

  read -p "Ethereum RPC: " ethereum_rpc
  validate_rpc_url $ethereum_rpc  &&  {
    sed -i.bak "s~<ethereum_node_url>~$ethereum_rpc~w eth_change.txt" $GATEWAY_CONFIG  &&  rm ${GATEWAY_CONFIG}.bak
    [ -s eth_change.txt ]  ||  {
      sed -i.bak 's~"ethereum"[[:blank:]]*:[[:blank:]]*{~&\'$'\n''        "rpc": "'$ethereum_rpc'",~' $GATEWAY_CONFIG  &&  rm ${GATEWAY_CONFIG}.bak
      sed -i.bak 's~"ethless"[[:blank:]]*:[[:blank:]]*{~&\'$'\n''        "rpc": "'$ethereum_rpc'",~' $GATEWAY_CONFIG  &&  rm ${GATEWAY_CONFIG}.bak
      sed -i.bak 's~"erc20"[[:blank:]]*:[[:blank:]]*{~&\'$'\n''        "rpc": "'$ethereum_rpc'",~' $GATEWAY_CONFIG  &&  rm ${GATEWAY_CONFIG}.bak
    }
    rm eth_change.txt 2>/dev/null
  }  ||  {
    mv "$GATEWAY_CONFIG"_orig $GATEWAY_CONFIG
    return 1
  }

  rm "$GATEWAY_CONFIG"_orig 2>/dev/null

  return 0
}


os_name="$(uname -s)"
case "${os_name}" in
  Linux*)
    BASH_RC=~/.bashrc
    NETCAT=nc
    ;;
  Darwin*)
    define_login_profile_macos BASH_RC  ||  exit 1
    NETCAT=ncat    # 'nc' isn't reliable on macOS
    ;;
  *) echo "Unsupported operating system: $os_name"
     exit 1
     ;;
esac

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

define_creditcoin_home_in_bashrc   ||  exit 1
schedule_job_to_run_sanity_script  ||  exit 1
define_fields_in_gateway_config    ||  exit 1

[ -s $CREDITCOIN_HOME/sha256_speed.log ]  ||  echo "Reboot this machine before running script 'start_creditcoin.sh'."

exit 0
