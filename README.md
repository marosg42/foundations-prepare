# foundations-prepare

Contains two scripts

## runit.sh

This script will prepare environment for VM only foundations setup.

- install and configure local DNS forwarder
- create internal maasbr0 bridge
- install multipass
- install infra node(s)
- setup ssh keys as needed by foundations

It is just a dumb script, not checking many things. It assumes it is started on a fresh 18.04 installation,
running under ubuntu user.

There are several variables at the beginning of the script which can be set

- `HA` if `true`, three infra nodes will be created, default is `false` which means just one infra node
- `PROXY` if `true`, `PROXY_HTTP` and `PROXY_HTTPS` are used in appropriate places. Default is `false`
- `LOG` - text file which will contain logs from the run
- `VMs` - path to a directory which will contain qcow2 files

Script will set internal network of `192.168.210.0/24`. It is possible to change it with set of variables in the script, but it is not required to.

Two things which are not set permanently and will disappear after a reboot

- maasbr0 is not in netplan files
- iptables changes are not saved

## cleanit.sh

Even dumber than previous, it just tries to clean up what runit.sh as much as possible, absoliutely no checking, error messages are expected.
I use it during development just to have a clean(-ish) slate to avoid redeploying the server.
