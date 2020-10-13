#!/bin/bash

[ -z "$CREDITCOIN_HOME" ]  &&  CREDITCOIN_HOME=~/Server
echo CREDITCOIN_HOME is $CREDITCOIN_HOME
cd $CREDITCOIN_HOME  ||  exit 1


function check_available_disk_space {
  local download_directory=$1
  local required_disk_space_kb=$2

  available_disk_space_kB=`df -Pk $download_directory | tail -1 | awk {'print $4'}`    # df POSIX output format is portable
  (( $available_disk_space_kB >= $required_disk_space_kb ))  ||  {
    echo "Available disk space is less than $(($required_disk_space_kb >> 20)) GB:"
    df -h $download_directory
    return 1
  }
  return 0
}


function download_blockchain_snapshot {
  local rc=0

  [ -z "$MAGNET_URI" ]  &&  {
    MAGNET_URI="magnet:?xt=urn:btih:5b2f2ebf6be7e37e7bdf71c5edf356a7dec87ca2&dn=creditcoin-block-volume.tar.gz&tr=udp%3a%2f%2ftracker.openbittorrent.com%3a80&tr=udp%3a%2f%2ftracker.opentrackr.org%3a1337%2fannounce"
    SHA256_SUM=6a10f081137481aca963d1432228d694948f38361b6980b5c13f30795036a26e  # if not defined, no verification is performed after snapshot download
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
      echo Verification failed.
      rc=1
    }
  }  ||  echo "Warning: Blockchain snapshot $BLOCK_VOLUME_FILE cannot be verified since checksum is unknown."

  return $rc
}


function get_block_volume_path {
  ps -ef | grep -q "[s]awtooth-validator"  ||  {
    local docker_compose=$1
    docker-compose -f $docker_compose up -d validator  &&  {
      ps -ef | grep -q "[s]awtooth-validator"  ||  {
        echo Validator failed to start.
        return 1
      }
    }  ||  return 1
  }

  local CONTAINER=`docker ps | grep [s]awtooth-validator | awk {'print $NF'}`
  local block_volume_path_reference=`docker inspect $CONTAINER | grep _data | grep block`
  local rc=$?

  [ $rc = 0 ]  &&  {
    [ -z "$block_volume_path_reference" ]  &&  {
      echo "Block volume path not found for container $CONTAINER ."
      return 1
    }
    block_volume_path_reference=/var/lib`echo $block_volume_path_reference | cut -d \" -f4`
  }

  eval $2=\$block_volume_path_reference    # return by reference
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

    # empty configuration file suppresses log message
    cat > ~/.rtorrent.rc << EOF
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


# create symbolic links to restored files if name digits are different from those in production
function create_symbolic_links_to_generic_lmdb_names {
  local production_lmdb_digits=$1
  [ -n "$production_lmdb_digits" ]  ||  return 0

  local restored_lmdb_names=(`ls -l | egrep '\-[[:digit:]]{2}\.' | awk {'print $NF'} | tr '\r\n' ' '`)

  for index in ${!restored_lmdb_names[*]}
  do
    local production_name=`echo ${restored_lmdb_names[$index]} | sed "s/[0-9]\{2\}/$production_lmdb_digits/"`
    sudo ln -s ${restored_lmdb_names[$index]} $production_name 2>/dev/null
  done

  return 0
}


function restart_creditcoin_node {
  local docker_compose
  get_docker_compose_file_name  docker_compose  ||  return 1

  local block_volume_path
  get_block_volume_path  $docker_compose  block_volume_path  ||  return 1

  docker-compose -f $docker_compose down

  # symbolic links have top precedence; if none are found, use file names
  local production_lmdb_digits=`find $block_volume_path -maxdepth 1 -type l | head -1 | xargs basename | grep -o -E '[0-9]+'`
  [ -z "$production_lmdb_digits" ]  &&  {
    production_lmdb_digits=`find $block_volume_path -maxdepth 1 -type f | head -1 | xargs basename | grep -o -E '[0-9]+'`
  }

  echo Superuser privilege is required to upgrade database.
  sudo rm $block_volume_path/* 2>/dev/null

  # need this check especially for brand new installation
  local REQUIRED_DISK_SPACE_KB=$((100 * 1024 * 1024))
  check_available_disk_space $block_volume_path $REQUIRED_DISK_SPACE_KB  ||  return 1

  block_volume_path=`dirname $block_volume_path`    # trim trailing '/_data'
  sudo mkdir -p $block_volume_path
  sudo tar xzvf $DOWNLOAD_DIRECTORY/$BLOCK_VOLUME_FILE --directory $block_volume_path  ||  return 1

  pushd $block_volume_path/_data >/dev/null
  create_symbolic_links_to_generic_lmdb_names  $production_lmdb_digits  ||  return 1
  popd >/dev/null

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


[ -z "$REQUIRED_DISK_SPACE_KB" ]  &&  REQUIRED_DISK_SPACE_KB=$((25 * 1024 * 1024))    # required disk space for BitTorrent download
[ -z "$DOWNLOAD_DIRECTORY" ]  &&  DOWNLOAD_DIRECTORY=`pwd`
echo DOWNLOAD_DIRECTORY is $DOWNLOAD_DIRECTORY

check_available_disk_space $DOWNLOAD_DIRECTORY $REQUIRED_DISK_SPACE_KB  ||  exit 1
download_blockchain_snapshot  ||  exit 1
restart_creditcoin_node       ||  exit 1

exit 0
