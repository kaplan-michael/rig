#!/usr/bin/env bash

RET=0
set -e

color_echo() {
  echo -e "\033[1;31m$@\033[0m"
}

ssh_port() {
	footloose show $1 -o json|grep hostPort|grep -oE "[0-9]+"
}

sanity_check() {
  color_echo "- Testing footloose machine connection"
  make create-host
  echo "* Footloose status"
  footloose status
  echo "* Docker ps"
  docker ps
  echo "* SSH port: $(ssh_port node0)"
  echo "* Testing stock ssh"
  retry ssh -vvv -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i .ssh/identity -p $(ssh_port node0) root@127.0.0.1 echo "test-conn" || return $?
  set +e
  echo "* Testing footloose ssh"
  footloose ssh root@node0 echo test-conn | grep -q test-conn
  local exit_code=$?
  set -e
  make clean
  RET=$exit_code
}


rig_test_agent_with_public_key() {
  color_echo "- Testing connection using agent and providing a path to public key"
  make create-host
  eval $(ssh-agent -s)
  ssh-add .ssh/identity
  rm -f .ssh/identity
  set +e
  HOME=$(pwd) SSH_AUTH_SOCK=$SSH_AUTH_SOCK ./rigtest -host 127.0.0.1:$(ssh_port node0) -user root -keypath .ssh/identity.pub -connect
  local exit_code=$?
  set -e
  kill $SSH_AGENT_PID
  export SSH_AGENT_PID=
  export SSH_AUTH_SOCK=
  RET=$exit_code
}

rig_test_agent_with_private_key() {
  color_echo "- Testing connection using agent and providing a path to protected private key"
  make create-host KEY_PASSPHRASE=testPhrase
  eval $(ssh-agent -s)
  expect -c '
    spawn ssh-add .ssh/identity
    expect "?:"
    send "testPhrase\n"
    expect eof"
  '
  set +e
  # path points to a private key, rig should try to look for the .pub for it 
  HOME=$(pwd) SSH_AUTH_SOCK=$SSH_AUTH_SOCK ./rigtest -host 127.0.0.1:$(ssh_port node0) -user root -keypath .ssh/identity -connect
  local exit_code=$?
  set -e
  kill $SSH_AGENT_PID
  export SSH_AGENT_PID=
  export SSH_AUTH_SOCK=
  RET=$exit_code
}

rig_test_agent() {
  color_echo "- Testing connection using any key from agent (empty keypath)"
  make create-host
  eval $(ssh-agent -s)
  ssh-add .ssh/identity
  rm -f .ssh/identity
  set +e
  ssh-add -l
  HOME=. SSH_AUTH_SOCK=$SSH_AUTH_SOCK ./rigtest -host 127.0.0.1:$(ssh_port node0) -user root -keypath "" -connect
  local exit_code=$?
  set -e
  kill $SSH_AGENT_PID
  export SSH_AGENT_PID=
  export SSH_AUTH_SOCK=
  RET=$exit_code
}

rig_test_ssh_config() {
  color_echo "- Testing getting identity path from ssh config"
  make create-host
  mv .ssh/identity .ssh/identity2
  echo "Host 127.0.0.1:$(ssh_port node0)" > .ssh/config
  echo "  IdentityFile .ssh/identity2" >> .ssh/config
  set +e
  HOME=. SSH_CONFIG=.ssh/config ./rigtest -host 127.0.0.1:$(ssh_port node0) -user root -connect
  local exit_code=$?
  set -e
  RET=$exit_code
}

rig_test_ssh_config_strict() {
  color_echo "- Testing StrictHostkeyChecking=yes in ssh config"
  make create-host
  local addr="127.0.0.1:$(ssh_port node0)"
  echo "Host ${addr}" > .ssh/config
  echo "  IdentityFile .ssh/identity" >> .ssh/config
  echo "  UserKnownHostsFile $(pwd)/.ssh/known" >> .ssh/config
  cat .ssh/config
  set +e
  HOME=. SSH_CONFIG=.ssh/config ./rigtest -host "${addr}" -user root -connect
  local exit_code=$?
  set -e
  if [ $exit_code -ne 0 ]; then
    echo "  * Failed first checkpoint"
    RET=1
    return
  fi
  echo "  * Passed first checkpoint"
  cat .ssh/known
  # modify the known hosts file to make it mismatch
  echo "${addr} ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBBgejI9UJnRY/i4HNM/os57oFcRjE77gEbVfUkuGr5NRh3N7XxUnnBKdzrAiQNPttUjKmUm92BN7nCUxbwsoSPw=" > .ssh/known
  cat .ssh/known
  set +e
  HOME=. SSH_CONFIG=.ssh/config ./rigtest -host "${addr}" -user root -connect
  exit_code=$?
  set -e

  if [ $exit_code -eq 0 ]; then
    echo "  * Failed second checkpoint"
    # success is a failure
    RET=1
    return
  fi
  echo "  * Passed second checkpoint"
}

rig_test_ssh_config_no_strict() {
  color_echo "- Testing StrictHostkeyChecking=no in ssh config"
  make create-host
  local addr="127.0.0.1:$(ssh_port node0)"
  echo "Host ${addr}" > .ssh/config
  echo "  UserKnownHostsFile $(pwd)/.ssh/known" >> .ssh/config
  echo "  StrictHostKeyChecking no" >> .ssh/config
  set +e
  HOME=. SSH_CONFIG=.ssh/config ./rigtest -host "${addr}" -user root -connect
  local exit_code=$?
  set -e
  if [ $? -ne 0 ]; then
    RET=1
    return
  fi
  # modify the known hosts file to make it mismatch
  echo "${addr} ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBBgejI9UJnRY/i4HNM/os57oFcRjE77gEbVfUkuGr5NRh3N7XxUnnBKdzrAiQNPttUjKmUm92BN7nCUxbwsoSPw=" > .ssh/known
  set +e
  HOME=. SSH_CONFIG=.ssh/config ./rigtest -host "${addr}" -user root -connect
  exit_code=$?
  set -e
  RET=$exit_code
}


rig_test_key_from_path() {
  color_echo "- Testing regular keypath and host functions"
  make create-host
  mv .ssh/identity .ssh/identity2
  set +e
  ./rigtest -host 127.0.0.1:$(ssh_port node0) -user root -keypath .ssh/identity2 
  local exit_code=$?
  set -e
  RET=$exit_code
}

rig_test_key_from_memory() {
  color_echo "- Testing connecting using a key from string"
  make create-host
  mv .ssh/identity .ssh/identity2
  set +e
  ./rigtest -host 127.0.0.1:$(ssh_port node0) -user root -ssh-private-key "$(cat .ssh/identity2)" -connect
  local exit_code=$?
  set -e
  RET=$exit_code
}

rig_test_key_from_default_location() {
  color_echo "- Testing keypath from default location"
  make create-host
  mv .ssh/identity .ssh/id_ecdsa
  set +e
  HOME=$(pwd) ./rigtest -host 127.0.0.1:$(ssh_port node0) -user root
  local exit_code=$?
  set -e
  RET=$exit_code
}

rig_test_protected_key_from_path() {
  color_echo "- Testing regular keypath to encrypted key, two hosts"
  make create-host KEY_PASSPHRASE=testPhrase REPLICAS=2
  set +e
  ssh_port node0 > .ssh/port_A
  ssh_port node1 > .ssh/port_B
  expect -c '
  
    set fp [open .ssh/port_A r]
    set PORTA [read -nonewline $fp]
    close $fp
    set fp [open .ssh/port_B r]
    set PORTB [read -nonewline $fp]
    close $fp

    spawn ./rigtest -host 127.0.0.1:$PORTA,127.0.0.1:$PORTB -user root -keypath .ssh/identity -askpass true -connect
    expect "Password:"
    send "testPhrase\n"
    expect eof"
  ' $port1 $port2
  local exit_code=$?
  set -e
  rm footloose.yaml
  make delete-host REPLICAS=2
  RET=$exit_code
}

rig_test_regular_user() {
  color_echo "- Testing regular user"
  make create-host
  sshPort=$(ssh_port node0)

  set -- -T -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i .ssh/identity -p "$sshPort"
  retry ssh "$@" root@127.0.0.1 true || {
    RET=$?
    color_echo failed to SSH into machine >&2
    return 0
  }

  ssh "$@" root@127.0.0.1 sh -euxC - <<EOF
    groupadd --system rig-wheel
    useradd -d /var/lib/rigtest-user -G rig-wheel -p '*' rigtest-user
    mkdir -p /var/lib/rigtest-user/
    cp -r /root/.ssh /var/lib/rigtest-user/.
    chown -R rigtest-user:rigtest-user /var/lib/rigtest-user/
    [ ! -d /etc/sudoers.d/ ] || {
      echo '%rig-wheel ALL=(ALL)NOPASSWD:ALL' >/etc/sudoers.d/rig-wheel
      chmod 0440 /etc/sudoers.d/rig-wheel
    }
    [ ! -d /etc/doas.d/ ] || {
      echo 'permit nopass :rig-wheel' >/etc/doas.d/rig-wheel.conf
      chmod 0440 /etc/doas.d/rig-wheel.conf
    }
EOF
  RET=$?
  [ $RET -eq 0 ] || {
    color_echo failed to provision new user rigtest-user >&2
    return 0
  }

  ssh "$@" rigtest-user@127.0.0.1 true || {
    RET=$?
    color_echo failed to SSH into machine as rigtest-user >&2
    return 0
  }

  env -i HOME="$(pwd)" ./rigtest -host 127.0.0.1:"$sshPort" -user rigtest-user -keypath .ssh/identity
}

retry() {
  local i
  for i in 1 2 3 4 5; do
    ! "$@" || return 0
    sleep $i
  done
  "$@"
}

if ! sanity_check; then
  color_echo Sanity check failed >&2
  exit 1
fi

for test in $(declare -F|grep rig_test_|cut -d" " -f3); do
  if [ "$FOCUS" != "" ] && [ "$FOCUS" != "$test" ]; then
    continue
  fi
  make clean
  make rigtest
  color_echo "\n###########################################################"
  RET=0
  $test || RET=$?
  if [ $RET -ne 0 ]; then
    color_echo "Test $test failed" >&2
    exit 1
  fi
  echo -e "\n\n\n"
done
