#!/bin/bash

cd $(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# determine ethernet device and host ipv4 address
ETH_DEV=$(ifconfig | grep eth | awk '{print $1}' | head -n 1)
HOST_IPv4=$(ifconfig $ETH_DEV | grep "inet addr" | awk -F: '{print $2}' | awk '{print $1}')

# keep $min $max and $nr_vnodes persistent
HELP_FILE="./HELP_FILE.txt"
if [ -e $HELP_FILE ]; then
    min=$(cat $HELP_FILE | grep MIN | awk '{print $2}')
    max=$(cat $HELP_FILE | grep MAX | awk '{print $2}')
    nr_vnodes=$(cat $HELP_FILE | grep NR_VNODES | awk '{print $2}')
else
    echo -e "MIN x\nMAX x\nNR_VNODES x" > $HELP_FILE
fi

# configuration file paths
NODE_EJABBERD_CONFIG="./config/ejabberd.yml"
EJABBERD_CONFIG='/etc/ejabberd/ejabberd.yml'

NODE_TURNSERVER_CONFIG="./config/turnserver.conf"
TURNSERVER_CONFIG='/etc/turnserver/turnserver.conf'
TURNSERVER_USERS='/etc/turnserver/turnusers.txt'

DEFAULT_LXC_CONFIG='/var/lib/lxc/default/config'

FORWARDER_PROGRAM="./cv_forwarder.py"
IPOP_PATH="./ipop"
LXC_IPOP_SCRIPT='/home/ubuntu/ipop/ipop.bash'

case $1 in

    ("install")
        ### install LXC
        # install LXC package
        sudo apt-get update
        sudo apt-get -y install lxc

        # create default container
        sudo lxc-create -n default -t ubuntu

        # install additional packages (python and psmisc); allow tap device
        sudo chroot /var/lib/lxc/default/rootfs apt-get update
        sudo chroot /var/lib/lxc/default/rootfs apt-get install -y python psmisc
        echo 'lxc.cgroup.devices.allow = c 10:200 rwm' | sudo tee --append $DEFAULT_LXC_CONFIG

        ### install ejabberd
        # install ejabberd package
        sudo apt-get update
        sudo apt-get -y install ejabberd

        # prepare ejabberd server config file
        sudo cp $NODE_EJABBERD_CONFIG $EJABBERD_CONFIG

        # restart ejabberd service
        sudo systemctl restart ejabberd.service
        sudo ejabberdctl restart

        # wait for ejabberd service to start
        sleep 15

        # create admin user
        sudo ejabberdctl register admin ejabberd password

        ### install turnserver
        # install libconfuse0 and turnserver packages
        sudo apt-get update
        sudo apt-get -y install libconfuse0 turnserver

        # use IP aliasing to bind turnserver to this ipv4 address
        sudo ifconfig $ETH_DEV:0 $HOST_IPv4 up

        # prepare turnserver config file
        sudo sed -i "s/listen_address = .*/listen_address = { \"$HOST_IPv4\" }/g" $NODE_TURNSERVER_CONFIG
        sudo cp $NODE_TURNSERVER_CONFIG $TURNSERVER_CONFIG

        ### configure network
        # replace symmetric NATs (MASQUERAGE) with full-cone NATs (SNAT)
        for i in $(sudo iptables -L POSTROUTING -t nat --line-numbers | awk '$2=="MASQUERADE" {print $1}'); do
            sudo iptables -t nat -D POSTROUTING $i
        done
        sudo iptables -t nat -A POSTROUTING -o $ETH_DEV -j SNAT --to-source $HOST_IPv4

        # open TCP ports (for ejabberd)
        for i in 5222 5269 5280; do
            sudo iptables -A INPUT -p tcp --dport $i -j ACCEPT
            sudo iptables -A OUTPUT -p tcp --dport $i -j ACCEPT
        done

        # open UDP ports (for STUN and TURN)
        for i in 3478 19302; do
            sudo iptables -A INPUT -p udp --sport $i -j ACCEPT
            sudo iptables -A OUTPUT -p udp --sport $i -j ACCEPT
        done
        ;;
    ("init-containers")
        min=$2
        max=$3

        # keep $min and $max persistent
        sed -i "s/MIN.*/MIN $min/g" $HELP_FILE
        sed -i "s/MAX.*/MAX $max/g" $HELP_FILE

        # clone and start N containers from default container; create tap device
        for i in $(seq $min $max); do
            sudo bash -c "
                lxc-clone default node$i;
                sudo lxc-start -n node$i --daemon;
                sudo lxc-attach -n node$i -- bash -c 'sudo mkdir /dev/net; sudo mknod /dev/net/tun c 10 200; sudo chmod 0666 /dev/net/tun';
            " &
        done
        wait 
        ;;
    ("init-server")
        nr_vnodes=$2

        ### initialize XMPP/STUN services
        # keep $nr_vnodes persistent
        sed -i "s/NR_VNODES.*/NR_VNODES $nr_vnodes/g" $HELP_FILE

        # register IPOP users (username: node#@ejabberd, password: password)
        for i in $(seq 0 $(($nr_vnodes - 1))); do
            sudo ejabberdctl register "node$i" ejabberd password
        done

        # define user links
        sudo ejabberdctl srg_create ipop_vpn ejabberd ipop_vpn ipop_vpn ipop_vpn
        sudo ejabberdctl srg_user_add @all@ ejabberd ipop_vpn ejabberd

        ### initialize TURN service
        # keep $nr_vnodes persistent
        sed -i "s/NR_VNODES.*/NR_VNODES $nr_vnodes/g" $HELP_FILE

        # add users to turnserver userlist
        for i in $(seq 0 $(($nr_vnodes - 1))); do
            echo "node$i:password:socialvpn.org:authorized" | sudo tee --append $TURNSERVER_USERS
        done

        # run turnserver
        turnserver -c $TURNSERVER_CONFIG
        ;;
    ("restart-server")
        ### restart services
        # restart ejabberd
        sudo systemctl restart ejabberd.service
        sudo ejabberdctl restart

        # restart turnserver
        ps aux | grep -v grep | grep turnserver | awk '{print $2}' | xargs sudo kill -9
        turnserver -c $TURNSERVER_CONFIG
        ;;
    ("exit-containers")
        # stop and delete N containers
        for i in $(seq $min $max); do
            sudo lxc-stop -n "node$i"; sudo lxc-destroy -n "node$i" &
        done
        wait
        ;;
    ("exit-server")
        ### exit XMPP/STUN services
        # undefine user links
        sudo ejabberdctl srg_delete ipop_vpn ejabberd

        # unregister IPOP users
        for i in $(seq 0 $(($nr_vnodes - 1))); do
            sudo ejabberdctl unregister "node$i" ejabberd
        done

        ### exit TURN service
        # kill turnserver
        ps aux | grep -v grep | grep turnserver | awk '{print $2}' | xargs sudo kill -9

        # remove users from turnserver userlist
        echo "" | sudo tee $TURNSERVER_USERS
        ;;
    ("source")
        # update sources of each vnode
        for i in $(seq $min $max); do
            sudo cp -r $IPOP_PATH "/var/lib/lxc/node$i/rootfs/home/ubuntu/" &
        done
        wait
        ;;
    ("config")
        # create config file for each node
        for i in $(seq $min $max); do
            # parse and prepare arguments
            xmpp_username="node$i@ejabberd"
            xmpp_password="password"
            xmpp_host=$2
            stun=$3
            turn='{"server": "'$4'", "user": "node'$i'", "pass": "password"}'
            ipv4='172.31.'$(($i / 256))'.'$(($i % 256))
            ipv4_mask=16
            central_visualizer=$5
            central_visualizer_ipv4=$6
            central_visualizer_port=$7
            num_bootstrap_links=$8
            num_successors=$9
            min_num_chords=${10}
            max_num_chords=${11}

            sudo lxc-attach -n "node$i" -- bash -c "bash $LXC_IPOP_SCRIPT config $xmpp_username $xmpp_password $xmpp_host $stun '$turn' $ipv4 $ipv4_mask $central_visualizer $central_visualizer_ipv4 $central_visualizer_port $num_bootstrap_links $num_successors $min_num_chords $max_num_chords" &
        done
        wait
        ;;
    ("forward")
        dbg_visual_ipv4=$2
        dbg_visual_port=$3
        forward_port=$4

        ps aux | grep -v grep | grep $FORWARDER_PROGRAM | awk '{print $2}' | xargs sudo kill -9
        python3 $FORWARDER_PROGRAM $dbg_visual_ipv4 $dbg_visual_port $forward_port
        ;;
    ("run")
        vnode_list=($2)

        for vnode in ${vnode_list[@]}; do
            sudo lxc-attach -n "node$vnode" -- bash -c "bash $LXC_IPOP_SCRIPT run"
        done
        ;;
    ("kill")
        vnode_list=($2)

        for vnode in ${vnode_list[@]}; do
            sudo lxc-attach -n "node$vnode" -- bash -c "bash $LXC_IPOP_SCRIPT kill"
        done
        ;;
    (*)
        echo "invalid operation"
        ;;

esac

exit 0

