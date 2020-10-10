#!/bin/bash

[ -z "$CREDITCOIN_HOME" ]  &&  CREDITCOIN_HOME=~/Server
echo CREDITCOIN_HOME is $CREDITCOIN_HOME
cd $CREDITCOIN_HOME  ||  exit 1


function install_torrent_client_on_ubuntu {
  [ -x "$(command -v transmission-cli)" ]  ||  {
    echo 'transmission-cli' not found.
    read -p "Install? (y/n) " yn
    case $yn in
      [Yy]*) apt-get update                       ||  return 1
             apt-get install -y transmission-cli  ||  return 1    # BitTorrent client
             ;;
      *) return 1
         ;;
    esac
  }
  return 0
}


function install_torrent_client_on_macos {
  [ -x "$(command -v transmission-daemon)" ]  ||  {
    echo 'transmission-daemon' not found.
    read -p "Install? (y/n) " yn
    case $yn in
      [Yy]*) brew install transmission  ||  return 1
             ;;
      *) return 1
         ;;
    esac
  }
  return 0
}


os_name="$(uname -s)"
case "${os_name}" in
    Linux*)
      install_torrent_client_on_ubuntu  ||  exit 1
      TRANSMISSION_CLIENT=transmission-cli
      ;;
    Darwin*)
      install_torrent_client_on_macos  ||  exit 1
      lsof -i :51413 >/dev/null  ||  transmission-daemon -c .  ||  exit 1
      TRANSMISSION_CLIENT="transmission-remote -a"
      ;;
    *) echo "Unsupported operating system: $os_name"
       exit 1
       ;;
esac

[ -z "$MAGNET_LINK" ]  &&  {
  MAGNET_LINK="magnet:?xt=urn:btih:5b2f2ebf6be7e37e7bdf71c5edf356a7dec87ca2&dn=creditcoin-block-volume.tar.gz&tr=udp%3a%2f%2ftracker.openbittorrent.com%3a80&tr=udp%3a%2f%2ftracker.opentrackr.org%3a1337%2fannounce"
}

docker_compose=`ls -t *.yaml | head -1`
[ -z "$docker_compose" ]  &&  return 1

while :
do
  read -p "Enter name of Docker compose file ($docker_compose) " user_entered
  [ -z "$user_entered" ]  &&  docker_compose=$docker_compose  &&  break
  [ -f $CREDITCOIN_HOME/$user_entered ]  &&  {
    docker_compose=$user_entered
    break
  }  ||  echo $user_entered not found.
done

$TRANSMISSION_CLIENT $MAGNET_LINK -w /  ||  exit 1

BLOCK_VOLUME_FILE=`echo $MAGNET_LINK | sed -e 's/.*dn=\(.*\)\.tar\.gz.*/\1\.tar\.gz/'`
BLOCK_VOLUME_PATH=/var/lib/docker/volumes/validator_validator-block-volume

[ -f /$BLOCK_VOLUME_FILE ]  ||  exit 1

docker-compose -f $docker_compose down

rm $BLOCK_VOLUME_PATH/_data/* 2>/dev/null
mkdir -p $BLOCK_VOLUME_PATH  ||  exit 1
tar xzvf /$BLOCK_VOLUME_FILE --directory $BLOCK_VOLUME_PATH

docker-compose -f $docker_compose pull             || exit 1
docker-compose -f $docker_compose build >/dev/null || exit 1
docker-compose -f $docker_compose up -d  &&  {
  validator=`ps -ef | grep "[u]sr/bin/sawtooth-validator"`
  [[ -z $validator ]]  &&  echo "Validator failed to start."  &&  exit 1
}  ||  exit 1

exit 0
