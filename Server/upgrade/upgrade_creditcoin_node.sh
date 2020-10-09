#!/bin/bash

[ -z "$CREDITCOIN_HOME" ]  &&  CREDITCOIN_HOME=~/Server
echo CREDITCOIN_HOME is $CREDITCOIN_HOME
cd $CREDITCOIN_HOME  ||  exit 1

[ -x "$(command -v transmission-cli)" ]  ||  {
  echo 'transmission-cli' not found.
  read -p "Install? (y/n) " yn
  case $yn in
    [Yy]*) apt-get update                       ||  exit 1
           apt-get install -y transmission-cli  ||  exit 1    # BitTorrent client
           ;;
    *) exit 1
       ;;
  esac
}

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

transmission-cli $MAGNET_LINK -w /  ||  exit 1

BLOCK_VOLUME_FILE=`echo $MAGNET_LINK | sed -e 's/.*dn=\(.*\)\.tar\.gz.*/\1\.tar\.gz/'`
BLOCK_VOLUME_PATH=/var/lib/docker/volumes/validator_validator-block-volume

[ -f /$BLOCK_VOLUME_FILE ]  ||  exit 1

docker-compose -f $docker_compose down

rm $BLOCK_VOLUME_PATH/_data/* 2>/dev/null
tar xzvf /$BLOCK_VOLUME_FILE --directory $BLOCK_VOLUME_PATH

docker-compose -f $docker_compose pull
docker-compose -f $docker_compose build
docker-compose -f $docker_compose up -d

exit 0
