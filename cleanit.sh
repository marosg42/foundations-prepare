#!/bin/bash

# very DIRTY cleanup, not checking anything, just trying to remove all possible things created by runit script
# many errors are expected

# goal is to 
# - remove all virsh VMs and directory where their qcow2s stay
# - remove maasbr0 and iptables related to it
# - remove bind9
# - remove xml, yaml, sh and other files created by runit.sh
# - remove infra hosts from known hosts file

# directory where qcows2 files for VMs will be located
VMs=~/VMs

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


cd
logit "echo \"*** Start cleaning ***\"" 

logit "sudo virsh list --all"

for i in $(sudo virsh list --all|grep -v State|grep -v "\-\-\-\-\-\-\-"|awk '{print $2}'); do
   sudo virsh destroy ${i}
done
sleep 10
for i in $(sudo virsh list --all|grep -v State|grep -v "\-\-\-\-\-\-\-"|awk '{print $2}'); do
   sudo virsh undefine ${i}
done

logit "sudo virsh list --all"

sudo rm -rf ${VMs}
sudo rm *xml

logit "echo \"*** Bind ***\""

sudo systemctl stop bind9
sudo apt remove bind9 bind9utils -y
sudo rm /etc/bind/named.conf.options 

logit "echo \"*** networking ***\""
sudo ip l set maasbr0 down
sudo brctl delbr maasbr0
sudo iptables -t nat -D POSTROUTING -s 192.168.210.0/24 ! -d 192.168.210.0/24 -m comment --comment "network maasbr0" -j MASQUERADE
sudo iptables -t filter -D INPUT -i maasbr0 -p tcp -m tcp --dport 53 -m comment --comment "network maasbr0" -j ACCEPT
sudo iptables -t filter -D INPUT -i maasbr0 -p udp -m udp --dport 53 -m comment --comment "network maasbr0" -j ACCEPT
sudo iptables -t filter -D FORWARD -o maasbr0 -m comment --comment "network maasbr0" -j ACCEPT
sudo iptables -t filter -D FORWARD -i maasbr0 -m comment --comment "network maasbr0" -j ACCEPT

logit "echo \"*** keys ***\""

ssh-keygen -f "/home/ubuntu/.ssh/known_hosts" -R "192.168.210.4"
ssh-keygen -f "/home/ubuntu/.ssh/known_hosts" -R "192.168.210.5"
ssh-keygen -f "/home/ubuntu/.ssh/known_hosts" -R "192.168.210.6"

logit "echo \"*** files ***\""

rm define_infra.sh
rm ubuntukeyinfra
rm define_VMs.sh
rm id_rsa_persistent*
rm sshconfig

echo