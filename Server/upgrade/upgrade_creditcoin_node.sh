#!/bin/bash

[ -z "$CREDITCOIN_HOME" ]  &&  CREDITCOIN_HOME=~/Server
echo CREDITCOIN_HOME is $CREDITCOIN_HOME
cd $CREDITCOIN_HOME  ||  exit 1


function check_available_disk_space {
  [ -z "$REQUIRED_DISK_SPACE_KB" ]  &&  REQUIRED_DISK_SPACE_KB=$((25 * 1024 * 1024))
  [ -z "$DOWNLOAD_DIRECTORY" ]  &&  DOWNLOAD_DIRECTORY=`pwd`
  echo DOWNLOAD_DIRECTORY is $DOWNLOAD_DIRECTORY

  available_disk_space_kB=`df -Pk $DOWNLOAD_DIRECTORY | tail -1 | awk {'print $4'}`    # df POSIX output format is portable
  (( $available_disk_space_kB >= $REQUIRED_DISK_SPACE_KB ))  ||  {
    echo "Available disk space is less than $(($REQUIRED_DISK_SPACE_KB >> 20)) GB:"
    df -h $DOWNLOAD_DIRECTORY
    return 1
  }
  return 0
}


function download_blockchain_snapshot {
  local rc=0

  [ -z "$MAGNET_URI" ]  &&  {
    MAGNET_URI="magnet:?xt=urn:btih:5b2f2ebf6be7e37e7bdf71c5edf356a7dec87ca2&dn=creditcoin-block-volume.tar.gz&tr=udp%3a%2f%2ftracker.openbittorrent.com%3a80&tr=udp%3a%2f%2ftracker.opentrackr.org%3a1337%2fannounce"
    SHA256_SUM=6a10f081137481aca963d1432228d694948f38361b6980b5c13f30795036a26e    # if not defined, no verification is performed after snapshot download
  }

  local torrent_client
  get_torrent_command_line  torrent_client  ||  return 1
  echo BitTorrent client is $torrent_client

  read -p "Estimated download time is three hours.  Proceed? (y/n) " yn
  case $yn in
    [Yy]*) $torrent_client $MAGNET_URI  ||  return 1
           ;;
    *) return 1
       ;;
  esac

  BLOCK_VOLUME_FILE=`echo $MAGNET_URI | sed -e 's/.*dn=\(.*\)\.tar\.gz.*/\1\.tar\.gz/'`
  [ -f $DOWNLOAD_DIRECTORY/$BLOCK_VOLUME_FILE ]  ||  {
    echo $DOWNLOAD_DIRECTORY/$BLOCK_VOLUME_FILE not found.
    return 1
  }

  [ -n "$SHA256_SUM" ]  &&  {
    echo Verifying SHA-256 digest of blockchain snapshot $BLOCK_VOLUME_FILE ...
    [ $SHA256_SUM = `shasum -a 256 $DOWNLOAD_DIRECTORY/$BLOCK_VOLUME_FILE | awk {'print $1'}` ]  &&  rc=0  ||  {
      echo Verification failed
      rc=1
    }
  }  ||  echo "Warning: Blockchain snapshot $BLOCK_VOLUME_FILE cannot be verified since checksum is unknown"

  return $rc
}


function get_torrent_command_line {
  local torrent_client_reference
  local rc=0

  [ -z "$TORRENT_CLIENT" ]  &&  {
    os_name="$(uname -s)"
    case "${os_name}" in
      Linux*)
        install_torrent_client_on_ubuntu  ||  return 1
        torrent_client_reference=rtorrent
        ;;
      Darwin*)
        install_torrent_client_on_macos  ||  return 1
        torrent_client_reference=rtorrent
        ;;
      *) echo "Unsupported operating system: $os_name"
         return 1
         ;;
    esac

    cat > ~/.rtorrent.rc << EOF
## require incoming encrypted handshake and require encrypted transmission after handshake
encryption = require
EOF
    rc=$?
  }  ||  torrent_client_reference="$TORRENT_CLIENT"

  eval $1=\$torrent_client_reference    # return by reference
  return $rc
}


function get_docker_compose_file_name {
  local docker_compose_reference

  docker_compose_reference=`ls -t *.yaml | head -1`
  [ -z "$docker_compose_reference" ]  &&  return 1
  while :
  do
    read -p "Enter name of Docker compose file ($docker_compose_reference) " user_entered
    [ -z "$user_entered" ]  &&  break
    [ -f $CREDITCOIN_HOME/$user_entered ]  &&  {
      docker_compose_reference=$user_entered
      break
    }  ||  echo $user_entered not found.
  done

  eval $1=\$docker_compose_reference    # return by reference
  return 0
}


function import_repository_key {
  local rc=0
  ubuntu_version=$(lsb_release -cs)
  [ "$ubuntu_version" = "xenial" ]  &&  {
    # make APT repository key trusted
    KEYS="778FA6F5"
    gpg --keyserver keyserver.ubuntu.com --recv-keys $KEYS 2>/dev/null
    gpg --no-default-keyring -a --export $KEYS | gpg --no-default-keyring --keyring ~/.gnupg/trustedkeys.gpg --import - 2>/dev/null
    rc=$?
  }
  return $rc
}


function install_torrent_client_on_ubuntu {
  local rc=0
  [ -x "$(command -v rtorrent)" ]  ||  {
    read -p "'rtorrent' not found.  Install? (y/n) " yn
    case $yn in
      [Yy]*) cp -p /etc/apt/sources.list /etc/apt/sources.list_bak
             sed -i 's/# deb-src/deb-src/' /etc/apt/sources.list  # enable download of source archives which contain package signatures
             apt-get update               &&
             import_repository_key        &&
             apt-get install -y rtorrent  &&
             apt-get source rtorrent      ||  rc=1
             mv /etc/apt/sources.list_bak /etc/apt/sources.list
             ;;
      *) rc=1
         ;;
    esac
  }
  return $rc
}


function install_torrent_client_on_macos {
  [ -x "$(command -v rtorrent)" ]  ||  {
    read -p "'rtorrent' not found.  Install? (y/n) " yn
    case $yn in
      [Yy]*) brew install rtorrent  ||  return 1
             ;;
      *) return 1
         ;;
    esac
  }
  return 0
}


function restart_creditcoin_node {
  local BLOCK_VOLUME_PATH=/var/lib/docker/volumes/server_validator-block-volume
  local docker_compose

  get_docker_compose_file_name  docker_compose  ||  return 1
  docker-compose -f $docker_compose down

  rm $BLOCK_VOLUME_PATH/_data/* 2>/dev/null
  mkdir -p $BLOCK_VOLUME_PATH  ||  return 1
  tar xzvf $DOWNLOAD_DIRECTORY/$BLOCK_VOLUME_FILE --directory $BLOCK_VOLUME_PATH  ||  return 1

  docker-compose -f $docker_compose pull             || return 1
  docker-compose -f $docker_compose build >/dev/null || return 1
  docker-compose -f $docker_compose up -d  &&  {
    ps -ef | grep -q "[s]awtooth-validator"  ||  {
      echo Validator failed to start.
      return 1
    }
  }  ||  return 1

  return 0
}


check_available_disk_space    ||  exit 1
download_blockchain_snapshot  ||  exit 1
restart_creditcoin_node       ||  exit 1

exit 0
