#!/bin/bash
#    Copyright(c) 2020 Gluwa, Inc.
#
#    This file is part of Creditcoin.
#
#    Creditcoin is free software: you can redistribute it and/or modify
#    it under the terms of the GNU Lesser General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
#    GNU Lesser General Public License for more details.
#
#    You should have received a copy of the GNU Lesser General Public License
#    along with Creditcoin. If not, see <https://www.gnu.org/licenses/>.

function timestamp {
  local ts=`date +"%Y-%m-%d %H:%M:%S"`
  echo -n $ts
}


function check_if_different_ipv4_subnet {
  local candidate=$1
  local seed=$2

  read c_octet1 c_octet2 c_octet3 c_octet4 <<<"${candidate//./ }"
  read s_octet1 s_octet2 s_octet3 s_octet4 <<<"${seed//./ }"
  [ $c_octet1 = $s_octet1 ]  &&  [ $c_octet2 = $s_octet2 ]  &&  return 1

  return 0
}


function check_required_executables {
  [ -x "$(command -v $NETCAT)" ]  ||  {
    echo "'netcat' not found."
    tty -s  &&  {
      read -p "Install? (y/n) " yn
      case $yn in
        [Yy]*) install_netcat  ||  return 1
               ;;
        *) return 1
           ;;
      esac
    }  ||  return 1    # exit with error if crontab job
  }

  [ -x "$(command -v docker-compose)" ]  &&  DOCKER_COMPOSE=`which docker-compose`  ||  {
    echo "'docker-compose' not found."
    tty -s  &&  {
      read -p "Install? (y/n) " yn
      case $yn in
        [Yy]*) install_docker_compose $DOCKER_COMPOSE  ||  return 1
               ;;
        *) return 1
           ;;
      esac
    }  ||  return 1    # exit with error if crontab job
  }

  [ -x "$(command -v curl)" ]  ||  {
    echo "'curl' not found."
    tty -s  &&  {
      read -p "Install? (y/n) " yn
      case $yn in
        [Yy]*) install_curl  ||  return 1
               ;;
        *) return 1
           ;;
      esac
    }  ||  return 1    # exit with error if crontab job
  }
}


function evaluate_candidates_for_dynamic_peering {
  [ -s $CREDITCOIN_HOME/check_node_sanity.log ]  ||  return 1

  local seeds_array_reference
  local seeds_array_length=$2
  local unique_open_peers_by_frequency=`grep "is open" $CREDITCOIN_HOME/check_node_sanity.log | awk '{print $4}' | sort | uniq -c | sort -nr | awk '{print $2}' | tr '\r\n' ' '`
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

    [ $different_subnet = true ]  &&  $NETCAT -z -w 2 $host $port  &&  {
      seeds_array_reference[$s]=$open_peer
      ((++s == $seeds_array_length))  &&  break
    }
  done

  eval $1='("${seeds_array_reference[@]}")'    # construct array and return it by reference

  (($s > 0))  &&  return 0  ||  return 1
}


function get_docker_compose_file_name {
  local docker_compose_reference

  docker_compose_reference=`ls -t *.yaml | head -1`
  [ -z "$docker_compose_reference" ]  &&  return 1

  tty -s  &&  {
    while :
    do
      read -p "Enter name of Docker compose file ($docker_compose_reference) " user_entered
      [ -z "$user_entered" ]  &&  break
      [ -s $CREDITCOIN_HOME/$user_entered ]  &&  {
        docker_compose_reference=$user_entered
        break
      }  ||  echo $user_entered not found.
    done
  }

  eval $1=\$docker_compose_reference    # return by reference
  return 0
}


function install_curl {
  [ $(uname -s) = Linux ]  &&  {
    sudo apt-get install -y curl  ||  return 1
  }
  return 0
}


function install_docker_compose {
  local DESTINATION=$1
  local VERSION=1.26.2

  sudo curl -L https://github.com/docker/compose/releases/download/${VERSION}/docker-compose-$(uname -s)-$(uname -m) -o $DESTINATION  ||  return 1
  sudo chmod 755 $DESTINATION

  return 0
}


function install_netcat {
  [ $(uname -s) = Linux ]  &&  {
    [ -x ./install_apt_packages.sh ]  &&  ./install_apt_packages.sh  netcat-openbsd  ||  return 1
  }  ||  {
    [ $(uname -s) = Darwin ]  &&  {
      brew install nmap 2>/dev/null  ||  brew upgrade nmap  ||  return 1
    }
  }
  return 0
}


function restart_creditcoin_node {
  local docker_compose
  get_docker_compose_file_name  docker_compose  ||  return 1

  local public_ipv4_address=`curl https://checkip.amazonaws.com 2>/dev/null`
  [ -z $public_ipv4_address ]  &&  {
    echo Unable to query public IP address.
    return 1
  }

  [ -s $CREDITCOIN_HOME/check_node_sanity.log ]  &&  {
    local last_public_ipv4_address=`grep "Public IP" $CREDITCOIN_HOME/check_node_sanity.log | tail -1 | awk '{print $NF}'`
    [ -n "$last_public_ipv4_address" ]  &&  [ $last_public_ipv4_address != $public_ipv4_address ]  &&  {
      # write warning to stderr
      >&2 echo "Warning: Public IP address has recently changed.  Creditcoin nodes cannot have dynamic IP addresses."
    }
  }

  # replace advertised Validator endpoint with current public IP address; retain existing port number
  sed -i.bak "s~\(endpoint[[:space:]]\{1,\}tcp://\).*\(:\)~\1$public_ipv4_address\2~g" $docker_compose  &&  rm ${docker_compose}.bak

  if grep -q "peering[[:space:]]\+dynamic" $docker_compose
  then
    local seeds=([0]="" [1]="" [2]="")
    evaluate_candidates_for_dynamic_peering  seeds  ${#seeds[@]}  &&  {
      sed -i.bak '/seeds[[:space:]]\{1,\}tcp:.*$/d' $docker_compose  &&  rm ${docker_compose}.bak    # remove existing seeds
    }

    # insert new seeds into .yaml file
    preamble="                --seeds tcp://"
    for seed in "${seeds[@]}"
    do
                                                                                                     # $'\n' represents a newline
      [ -n "$seed" ]  &&  sed -i.bak '/peering[[:space:]]\{1,\}dynamic.*\\/ s~^~'"$preamble$seed"' \\\'$'\n''~' $docker_compose  &&  rm ${docker_compose}.bak
    done
  fi

  docker ps -q &>/dev/null  ||  start_docker_daemon  ||  return 1

  sudo $DOCKER_COMPOSE -f $docker_compose down 2>/dev/null
  if sudo $DOCKER_COMPOSE -f $docker_compose up -d
  then
    timestamp
    echo " Started Creditcoin node"

    # check if Validator endpoint is reachable from internet
    local validator_endpoint_port=`grep endpoint $docker_compose | cut -d: -f3 | awk '{print $1}'`
    $NETCAT -4 -z -w 1  $public_ipv4_address  $validator_endpoint_port  ||  {
      timestamp
      echo -n " TCP port $validator_endpoint_port isn't open. "
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


function start_docker_daemon {
  [ $(uname -s) = Linux ]  &&  {
    sudo service docker start  ||  return 1
  }  ||  {
    [ $(uname -s) = Darwin ]  &&  {
      open --background -a Docker  &&  {
        # could take up to 20 seconds to start
        while ! docker system info &>/dev/null
        do
          sleep 1
        done
      }  ||  return 1
    }
  }
  return 0
}


function stop_creditcoin_node {
  local docker_compose
  get_docker_compose_file_name  docker_compose  ||  return 1
  sudo $DOCKER_COMPOSE -f $docker_compose down 2>/dev/null
  return $?
}


function check_sha256_throughput {
  [ -s $CREDITCOIN_HOME/sha256_speed.log ]  ||  {
    echo "No processing specification found for this machine.  Ensure script sha256_speed_test.sh is scheduled in crontab."
    return 1
  }

  local sorted_throughputs=`tail -9 $CREDITCOIN_HOME/sha256_speed.log | awk '{print $3}' | sort | tr '\r\n' ' '`
  local arr=($sorted_throughputs)
  local arr_length=${#arr[@]}
  local median_throughput="${arr[ $(($arr_length/2)) ]}"
  local BASELINE=7565854    # measured on Azure VM running Xeon Platinum 8171M CPU @ 2.60GHz

  (( median_throughput < BASELINE ))  &&  {
    echo Warning: this machine lacks sufficient power to run Creditcoin software.
#    return 1
  }
  return 0
}


[ -z $CREDITCOIN_HOME ]  &&  CREDITCOIN_HOME=~/Server
echo CREDITCOIN_HOME is $CREDITCOIN_HOME
cd $CREDITCOIN_HOME  ||  exit 1

os_name="$(uname -s)"
case "${os_name}" in
  Linux*)
    DOCKER_COMPOSE=/usr/bin/docker-compose
    NETCAT=nc
    ;;
  Darwin*)
    DOCKER_COMPOSE=/usr/local/bin/docker-compose  # /usr/bin has no write permission
    NETCAT=ncat                                   # 'nc' isn't reliable on macOS
    ;;
  *) echo "Unsupported operating system: $os_name"
     exit 1
     ;;
esac

check_required_executables  ||  exit 1

for i in "$@"
do
case $i in
  -s*|--stop*)
    stop_creditcoin_node  &&  exit 0  ||  exit 1
    ;;
  *)
    ;;
esac
done

check_sha256_throughput  ||  exit 1
restart_creditcoin_node  ||  exit 1

exit 0
