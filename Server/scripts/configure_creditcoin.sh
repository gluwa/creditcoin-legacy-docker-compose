#!/bin/bash

[ -z $CREDITCOIN_HOME ]  &&  CREDITCOIN_HOME=~/Server
cd $CREDITCOIN_HOME  ||  exit 1

# allow sudo execution in crontab without tty
cc_user=`whoami`
sudo grep -q "$cc_user ALL" /etc/sudoers  ||  {
  echo "$cc_user ALL=(ALL) NOPASSWD:SETENV: /usr/bin/docker-compose, /bin/sh" | sudo EDITOR='tee -a' visudo >/dev/null
}


# schedule job to periodically run sanity script

crontab -l | grep -q CREDITCOIN_HOME  ||  {
  echo CREDITCOIN_HOME is $CREDITCOIN_HOME
  minutes_after_hour1=$((`date +%s` % 30))
  minutes_after_hour2=$(($minutes_after_hour1 + 30))

  (crontab -l 2>/dev/null;
   echo CREDITCOIN_HOME=$CREDITCOIN_HOME;
   echo "$minutes_after_hour1,$minutes_after_hour2 * * * * \$CREDITCOIN_HOME/check_node_sanity.sh >> \$CREDITCOIN_HOME/check_node_sanity.log 2>>\$CREDITCOIN_HOME/check_node_sanity-error.log") | crontab -
}

exit 0
