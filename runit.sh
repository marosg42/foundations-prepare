#!/bin/bash

# directories are not created ot checked for existence

# location of log file
LOG=./output.txt
# directory where qcows2 files for VMs will be located
VMs=~/VMs
# whether do deploy single node or three node high availability MaaS. 
# HA="1" means 3 infra nodes
HA="0"  # single infra node

# wait till avgload goes under $1
# if $1 is not provided, 5 is default
wait_for_load() {
  d1=5
  if [ "$#" -lt 1 ]; then
    d2=5
  else
    d2=$1
  fi

  while true; do
    d1=$(uptime|sed "s/.*average://"|awk '{print $1}'|sed "s/,//")
    echo $d1 
    if (( $(awk 'BEGIN {print ("'$d1'" < "'$d2'")}') )); then
      break
    fi
    sleep 30
  done
}

# logging commands and their output
# $1 is a command to execute
logit() {
 echo "***************************************************************************" | tee -a $LOG
 date | tee -a $LOG
 echo $1 | tee -a $LOG
 eval ${1} | tee -a $LOG
 uptime | tee -a $LOG
 echo "" | tee -a $LOG
}



logit "echo \"*** Start ***\"" 
set -e
if [ ${USER} != 'ubuntu' ]; then
  logit "echo This is just a dumb script which assumes it runs under user ubuntu"
  return 1
fi

mkdir -p ${VMs}

logit "echo \"*** Bind ***\""
# DNS server (just a forwarder, should be replaced by dnsmasq) to listen on 192.168.210.1
sudo apt install bind9 bind9utils -y
cat <<EOF | sudo tee /etc/bind/named.conf.options 
options {
       directory "/var/cache/bind";
       forwarders {
             127.0.0.53;
       };
       dnssec-validation no;
       auth-nxdomain no;    # conform to RFC1035
       listen-on {192.168.210.1;};
       listen-on-v6 { any; };
};
EOF

sudo systemctl restart bind9

# install needed packages
logit "echo \"*** packages ***\""
sudo apt install bridge-utils libvirt-bin qemu-utils virtinst qemu-kvm -y
sleep 30
# it happened ONCE nested KVM was not allowed, so these three lines are just in case
sudo modprobe -r kvm_intel
sudo modprobe kvm_intel nested=1
echo "options kvm_intel nested=1" | sudo tee -a /etc/modprobe.d/kvm.conf 
logit "cat /sys/module/kvm_intel/parameters/nested"

# create maasbr0 and setup iptable for NAT and forward
logit "echo \"*** networking ***\""
sudo brctl addbr maasbr0
sudo ip a add 192.168.210.1/24 dev maasbr0
sudo ip l set maasbr0 up

sudo iptables -t nat -A POSTROUTING -s 192.168.210.0/24 ! -d 192.168.210.0/24 -m comment --comment "network maasbr0" -j MASQUERADE
sudo iptables -t filter -A INPUT -i maasbr0 -p tcp -m tcp --dport 53 -m comment --comment "network maasbr0" -j ACCEPT
sudo iptables -t filter -A INPUT -i maasbr0 -p udp -m udp --dport 53 -m comment --comment "network maasbr0" -j ACCEPT
sudo iptables -t filter -A FORWARD -o maasbr0 -m comment --comment "network maasbr0" -j ACCEPT
sudo iptables -t filter -A FORWARD -i maasbr0 -m comment --comment "network maasbr0" -j ACCEPT

# generate keypair
printf 'y\n'|ssh-keygen -t rsa -f ~/.ssh/id_rsa -t rsa -N ''

# install multipass, prepare script for creating infra nodes in multipass
logit "echo \"*** multipass ***\""
sudo snap install multipass --classic --beta
sleep 30
sudo snap set multipass driver=LIBVIRT

# multipass cloudinit
logit "echo \"*** create cloudinit ***\""
PUBKEY=$(cat ~/.ssh/id_rsa.pub)
cat <<EOF | tee cloudinit.yaml
package_update: true
package_upgrade: true
packages:
 - bridge-utils
 - qemu-kvm
 - libvirt-bin
ssh_authorized_keys:
 - ${PUBKEY}
users:
 - name: ubuntu
   sudo: ALL=(ALL) NOPASSWD:ALL
   home: /home/ubuntu
   shell: /bin/bash
   groups: [adm, audio, cdrom, dialout, floppy, video, plugdev, dip, netdev, libvirtd]
   lock_passwd: True
   gecos: Ubuntu
   ssh_authorized_keys:
     - ${PUBKEY}
EOF

logit  "cat cloudinit.yaml"

logit "echo \"*** create define_infra script ***\""

cat <<EOF | tee define_infra.sh
#!/bin/bash
# \$1 name
# \$2 IP

# trick to avoid multipass asking interactive question about statistics at random times
exec 0<&-

HOST=\$1
multipass launch 18.04 -c 4 -d 50G -m 8G --cloud-init cloudinit.yaml -n \${HOST}
sleep 5
multipass.virsh attach-interface \${HOST} bridge maasbr0 --config --live
interface=\$(multipass exec \${HOST} -- ip l|grep ens|grep DOWN|head -n 1|awk '{print \$2}'|sed "s/\://")
multipass exec \${HOST} -- bash -c "echo \"network: {config: disabled}\"| sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg"
multipass exec \${HOST} -- bash -c "echo \"network:
 version: 2
 renderer: networkd
 ethernets:
   \${interface}:
     dhcp4: False
 bridges:   
   broam:   
     interfaces: [\${interface}]   
     dhcp4: False   
     dhcp6: False   
     addresses: [\${2}/24]
     gateway4: 192.168.210.1
     nameservers:
       addresses: [192.168.210.1]
     parameters:   
       stp: false   
       forward-delay: 0
\"|sudo tee /etc/netplan/51-fce.yaml"  

multipass exec \${HOST} -- sudo netplan apply
sleep 10
ping -c 5 \$2
multipass.virsh reboot \${HOST}
sleep 30
ping -c 5 \$2
EOF

logit "cat define_infra.sh"
chmod +x define_infra.sh

# call the script to create three infra nodes
logit "echo \"*** define infras ***\""
sleep 30
logit "echo \"*** define infra1 ***\""
./define_infra.sh infra1 192.168.210.4
logit "echo return code $?"
wait_for_load 4
if [ ${HA} -eq "1" ]; then
  logit "echo \"*** define infra2 ***\""
  ./define_infra.sh infra2 192.168.210.5
  logit "echo return code $?"
  wait_for_load 4
  logit "echo \"*** define infra3 ***\""
  ./define_infra.sh infra3 192.168.210.6
  logit "echo return code $?"
  wait_for_load 4
fi

logit "multipass list"

logit "echo running ssh-keygen"
set +e
ssh-keygen -f "/home/ubuntu/.ssh/known_hosts" -R "192.168.210.4"
if [ ${HA} -eq "1" ]; then
  ssh-keygen -f "/home/ubuntu/.ssh/known_hosts" -R "192.168.210.5"
  ssh-keygen -f "/home/ubuntu/.ssh/known_hosts" -R "192.168.210.6"
fi
set -e
# setup ssh keys as needed
PUBKEY=$(cat .ssh/id_rsa.pub)

if [ ${HA} -eq "1" ]; then
  INFRAS="4 5 6"
else
  INFRAS="4"
fi

logit "echo allow connection from host to ubuntu on infras"
# allow connection from host to ubuntu on infras
for i in ${INFRAS}  ; do echo "${PUBKEY}" |ssh -o StrictHostKeyChecking=no 192.168.210.${i} "cat - >> /home/ubuntu/.ssh/authorized_keys"; done
logit "echo allow connection from host to root on infras"
# allow connection from host to root on infras (TODO - needed?)
for i in ${INFRAS} ; do echo "${PUBKEY}" |ssh -o StrictHostKeyChecking=no 192.168.210.${i} "cat - |sudo tee -a /root/.ssh/authorized_keys"; done
logit "echo get ubuntu public key from infras"
# get ubuntu public key from infras
for i in ${INFRAS} ; do ssh -o StrictHostKeyChecking=no 192.168.210.${i} "printf 'y\n'|ssh-keygen -t rsa -f /home/ubuntu/.ssh/id_rsa -t rsa -N '' >>/dev/null 2>&1  ; cat /home/ubuntu/.ssh/id_rsa.pub"; done > ubuntukeyinfra
logit "echo allow ubuntu from infras to logon to host"
# allow ubuntu from infras to logon to host
cat ubuntukeyinfra >> ~/.ssh/authorized_keys
logit "echo establish first conection from infras to host so that it does not ask next time"
# establish first conection from infras to host so that it does not ask next time
for i in ${INFRAS} ; do ssh 192.168.210.${i} "printf 'yes\n'|ssh -o StrictHostKeyChecking=no ubuntu@192.168.210.1 hostname"; done

# define four VMs for FCE
logit "echo \"*** define VMs ***\""

cat <<EOF |tee define_VMs.sh
#!/bin/bash
define() {
# \$1 name
# \$2 id
# \$3 memory
# \$4 - \$8 unique MAC

virsh undefine \${1}\${2}

sleep 3

CPUOPTS="--cpu host"
GRAPHICS="--graphics vnc --video=cirrus"
CONTROLLER="--controller scsi,model=virtio-scsi,index=0"
DISKOPTS="format=qcow2,bus=scsi,cache=writeback"
export CPUOPTS GRAPHICS CONTROLLER DISKOPTS

qemu-img create -f qcow2 ${VMs}/\${1}\${2}d1.qcow2 60G
qemu-img create -f qcow2 ${VMs}/\${1}\${2}d2.qcow2 20G
qemu-img create -f qcow2 ${VMs}/\${1}\${2}d3.qcow2 20G

virt-install --noautoconsole --print-xml --boot network,hd,menu=on \
\$GRAPHICS \$CONTROLLER --name \${1}\${2} --ram \$3 --vcpus 2 \$CPUOPTS \
--disk path=${VMs}/\${1}\${2}d1.qcow2,size=60,\$DISKOPTS \
--disk path=${VMs}/\${1}\${2}d2.qcow2,size=20,\$DISKOPTS \
--disk path=${VMs}/\${1}\${2}d3.qcow2,size=20,\$DISKOPTS \
--network=bridge=maasbr0,mac=18:\${5}:\${6}:\${7}:\${8}:1\${2},model=virtio \
--network=bridge=maasbr0,mac=18:\${5}:\${6}:\${7}:\${8}:2\${2},model=virtio \
--network=bridge=maasbr0,mac=18:\${5}:\${6}:\${7}:\${8}:3\${2},model=virtio \
--network=bridge=maasbr0,mac=18:\${5}:\${6}:\${7}:\${8}:4\${2},model=virtio \
--network=bridge=maasbr0,mac=18:\${5}:\${6}:\${7}:\${8}:5\${2},model=virtio \
> \${1}\${2}.xml

virsh define \${1}\${2}.xml
}

for i in \$(seq 1 9); do
  define fe \${i} 4096 \$(date +"%y %m %H %M %S")
done
EOF

logit "cat define_VMs.sh"
chmod +x define_VMs.sh

# sudo becasue some weird change in libvirt in 18.04
sudo ./define_VMs.sh
logit "echo return code $?"
sleep 30

logit "ls -l"

printf 'y\n'|ssh-keygen -t rsa -f id_rsa_persistent -t rsa -N ''
cat id_rsa_persistent.pub >> ~/.ssh/authorized_keys
echo "IdentityFile ~/.ssh/id_rsa" > sshconfig; echo "IdentityFile ~/.ssh/id_rsa_persistent" >> sshconfig

ssh-keyscan -H 192.168.210.4 >> ~/.ssh/known_hosts
if [ ${HA} -eq "1" ]; then
  ssh-keyscan -H 192.168.210.5 >> ~/.ssh/known_hosts
  ssh-keyscan -H 192.168.210.6 >> ~/.ssh/known_hosts
fi

echo "*******************************************************************************************************"
echo "* When you clone cpe-deployments, copy ssh config and id_rsa_persistent* to that directory            *"
echo "* Also run git config user.name \"Chuck Norris\"; git config user.email chuck.norris@norris.chuck there *"
echo "*******************************************************************************************************"
echo