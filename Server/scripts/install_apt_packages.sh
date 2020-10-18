#!/bin/bash


function import_repository_keys {
  local rc=0
  ubuntu_version=$(lsb_release -cs)
  [ "$ubuntu_version" = "xenial" ]  &&  [ -n "$1" ]  &&  KEYS="$1"  &&  {
    # make APT repository keys trusted
    gpg2 --keyserver keyserver.ubuntu.com --recv-keys $KEYS 2>/dev/null
    gpg2 --no-default-keyring -a --export $KEYS | gpg2 --no-default-keyring --keyring ~/.gnupg/trustedkeys.gpg --import - 2>/dev/null
    rc=$?
  }
  return $rc
}


function install_packages {
  local packages_list="$1"
  for package in "$packages_list"
  do
    sudo apt-get install -y $package  &&
    apt-get source $package      ||  return 1
  done
  return 0
}


os_name="$(uname -s)"
case "${os_name}" in
  Linux*)
    ;;
  *) echo "Unsupported operating system: $os_name"
     exit 1
     ;;
esac


PACKAGES_LIST="$1"
[ -n "$PACKAGES_LIST" ]  ||  {
  echo List of APT package names is required.
  exit 1
}

KEYS_LIST="$2"
[ -n "$KEYS_LIST" ]  &&  {
  for key in $KEYS_LIST
  do
    (( 16#$key ))
    [ $? = 0 ]  ||  {
      echo Invalid hex key: $key
      exit 1
    }
  done
}

rc=0

sudo cp -p /etc/apt/sources.list /etc/apt/sources.list_bak
sudo sed -i 's/# deb-src/deb-src/' /etc/apt/sources.list    # enable download of source archives which contain package signatures
sudo apt-get update                  &&
import_repository_keys "$KEYS_LIST"  &&
install_packages "$PACKAGES_LIST"    ||  rc=1
sudo mv /etc/apt/sources.list_bak /etc/apt/sources.list

exit $rc
