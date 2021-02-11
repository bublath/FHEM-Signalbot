#!/bin/bash
SCRIPTVERSION="$Id:1.3$"
# Author: Adimarantis
# License: GPL
#Install script for signal-cli 
if [ -z "$PHONE" ]; then
	PHONE="+49xxxx"
fi
SIGNALPATH=/opt
SIGNALUSER=signal-cli
LIBPATH=/usr/lib
SIGNALVERSION="0.7.4"
SIGNALVAR=/var/lib/$SIGNALUSER
DBSYSTEMD=/etc/dbus-1/system.d
DBSYSTEMS=/usr/share/dbus-1/system-services
SYSTEMD=/etc/systemd/system
LOG=/tmp/signal_install.log
TMPFILE=/tmp/signal$$.tmp
DBVER=1.2.0
OPERATION=$1

if [ -n "$2" ]; then
	PHONE=$2
fi

#Get OS data
if [ -e /etc/os-release ]; then
	source /etc/os-release
	cat /etc/os-release >$LOG
else
	echo "Could not find OS release data - are you on Linux?"
	exit
fi

if grep -q docker /proc/1/cgroup; then 
   echo "You seem to run in a docker environment. Warning: This is experimental"
   export LC_ALL=C
   export DEBIAN_FRONTEND=noninteractive
	USER=`id | grep root`
	if [ -z "$USER" ]; then
		echo "Docker Installation needs to run under root"
		exit
	fi
   DOCKER=yes
   if [ -n "$FHEMUSER" ]; then
		SIGNALUSER=$FHEMUSER
	fi
	#overide path so its in the "real" world
	SIGNALPATH=/opt/fhem
fi

echo "This script will help you to install signal-cli as system dbus service"
echo "and prepare the use of the FHEM Signalbot module"
echo
echo "Please verify that these settigns are correct:"
echo "Signal-cli User:              $SIGNALUSER"
echo "Signal-cli Install directory: $SIGNALPATH"
echo "Signal config storage:        $SIGNALVAR"
echo "Signal version:               $SIGNALVERSION"
echo "System library path:          $LIBPATH"
echo "Phone number to be used:      $PHONE"

#
install_and_check() {
#Check availability of tools and install via apt if missing
	TOOL=$1
	PACKAGE=$2
	echo -n "Checking for $TOOL..."
	WHICH=`which $TOOL`
	if [ -z "$WHICH" ]; then
		echo -n "installing ($PACKAGE)"
		apt-get -q -y install $PACKAGE >>$LOG
		WHICH=`which $TOOL`
		if [ -z "$TOOL" ]; then
			echo "Failed to install $TOOL"
			exit
		else
			echo "done"
		fi
	else
		echo "available"
	fi
}

install_by_file() {
#Check availability of tools and install via apt if missing
	FILE=$1
	PACKAGE=$2
	echo -n "Checking for $FILE..."
	if ! [ -e "$FILE" ]; then
		echo -n "installing ($PACKAGE)"
		apt-get -q -y install $PACKAGE >>$LOG
		if ! [ -e "$FILE" ]; then
			echo "Failed to install $FILE"
			exit
		else
			echo "done"
		fi
	else
		echo "available"
	fi
}


check_and_create_path() {
#Check if path is available and create of not
	CHECK=$1
	echo -n "Checking for $CHECK..."
	if ! [ -d $CHECK ]; then
		mkdir $1
		if ! [ -d $CHECK ]; then
			echo "Failed to create $CHECK - did you run on sudo?"
			exit
		else
			echo "created"
		fi
	else
		echo "found"
	fi
	if ! [ -w $CHECK ]; then
		echo "Cannot write to $CHECK - did you start this script with sudo?"
		exit
	fi
}

check_and_compare_file() {
#Check if a file exists and compare if its the same as our internal reference file
	CHECK=$1
	COMPARE=$2
	echo -n "Checking for $CHECK..."
	if [ -e $CHECK ]; then
		echo "found"
		diff $CHECK $COMPARE
		DIFF=`diff -q $CHECK $COMPARE`
		if ! [ -z "$DIFF" ]; then
			echo "$CHECK differs, update (Y/n)? "
			read REPLY
			if [ "$REPLY" = "y" ]; then
				cp $COMPARE $CHECK
				echo "$CHECK updated"
			else 
			echo "$CHECK left untouched"
			fi
		fi
	else
		cp $COMPARE $CHECK
		echo "$CHECK installed"
	fi
}

#Main part - do always, check basic system requirements like OS, packages etc - does not install any signal specific stuff

ARCH=`arch`
OSNAME=`uname`
RASPI=""

if [ $OSNAME != "Linux" ]; then
	echo "Only Linux systems are supported (you: $OSNAME), quitting"
	exit
fi

if [ "$ID" = "raspbian" ] || [ "$ID" = "Raspian" ] || [ "$ARCH" = "armv7l" ]; then
	echo "You seem to be on a Raspberry pi with $ARCH"
	RASPI=1
else 
	if [ "$ID" = "ubuntu" ] || [ "$ID" = "Ubuntu" ]; then
		echo "You seem to run Ubuntu on $ARCH"
	else
		echo "Your configuration"
		uname -a
		echo "has not been tested, continue at own risk"
	fi
fi

check_and_update() {

APT=`which apt`

if [ -z "$APT" ]; then
	echo "Can't find apt command - are you on a supported system?"
	exit
fi

check_and_create_path $LIBPATH
check_and_create_path /etc/dbus-1
check_and_create_path $DBSYSTEMD
check_and_create_path /usr/share/dbus-1
check_and_create_path $DBSYSTEMS
check_and_create_path $SYSTEMD
check_and_create_path /run/dbus

if [ -n "$DOCKER" ]; then
	echo -n "Running in Docker, performing apt update/upgrade..."
	apt-get -q -y update
	apt-get -q -y upgrade
	echo "done"
fi

install_and_check apt-ftparchive apt-utils
install_and_check wget wget
install_and_check sudo sudo
install_and_check haveged haveged
install_and_check java default-jre
install_and_check diff diffutils
install_and_check dbus-send dbus
install_and_check cpan cpanminus
install_and_check qrencode qrencode
install_and_check pkg-config pkg-config
install_and_check gcc gcc
install_and_check zip zip
if [ -z "$BASH" ]; then
	echo "This script requires bash for some functions. Check if bash is installed."
	install_and_check bash bash
	echo "Please re-run using bash"
	exit
fi

#For DBus check a number of Perl modules on file level
install_by_file /usr/include/dbus-1.0/dbus/dbus.h libdbus-1-dev
install_by_file /usr/share/perl5/Test/CPAN/Changes.pm libcpan-changes-perl
install_by_file /usr/include/expat.h libexpat1-dev
install_by_file /usr/share/doc-base/libxml-parser-perl libxml-parser-perl
install_by_file /usr/share/doc/libtemplate-perl libtemplate-perl
install_by_file /usr/share/doc/libxml-xpath-perl libxml-xpath-perl
install_by_file /usr/share/build-essential/essential-packages-list build-essential
install_by_file /usr/share/doc/libxml-twig-perl xml-twig-tools
install_by_file /usr/share/doc/libimage-librsvg-perl libimage-librsvg-perl

cat >$TMPFILE <<EOF
#!/usr/bin/perl -w
use strict;
use warnings;

use Net::DBus;
print \$Net::DBus::VERSION."\n";
EOF

echo -n "Checking for Net::DBus..."
NETDBUS=`perl $TMPFILE`

if [ "$NETDBUS" = "$DBVER" ]; then
	echo "V$NETDBUS found"
else
	export PERL_MM_USE_DEFAULT=1
	echo -n "Installing latest NET::DBus..."
	cpan install -f Net::DBus >>$LOG 2>>$LOG
	echo "done"
fi

echo -n "Checking user $SIGNALUSER ..."
if id "$SIGNALUSER" &>/dev/null; then
    echo 'found'
else
	adduser --disabled-password --gecos none $SIGNALUSER
    echo 'created'
fi
}


#Check, install the signal-cli package as system dbus
#After this, signal-cli should be running and ready to use over dbus
install_signal_cli() {

check_and_create_path $SIGNALPATH
check_and_create_path $SIGNALVAR

NEEDINSTALL=0
echo -n "Checking for existing signal-cli installation..."
if [ -x "$SIGNALPATH/signal/bin/signal-cli" ]; then
	echo "found"
	echo -n "Checking signal-cli version..."
	CHECKVER=`$SIGNALPATH/signal/bin/signal-cli -v`
	echo $CHECKVER
	if [ "$CHECKVER" = "signal-cli $SIGNALVERSION" ]; then
		echo "signal-cli matches target version...ok"
	else 
		echo -n "Update to current version (y/N)? "
		read REPLY
		if [ "$REPLY" = "y" ]; then
			NEEDINSTALL=1
		fi
	fi
else
	echo "not found"
	NEEDINSTALL=1
fi

if [ $NEEDINSTALL = 1 ]; then
	echo "Proceed with signal cli installation"
	cd /tmp
	echo -n "Downloading signal-cli $SIGNALVERSION..."
	wget -qN https://github.com/AsamK/signal-cli/releases/download/v$SIGNALVERSION/signal-cli-$SIGNALVERSION.tar.gz
	if ! [ -e signal-cli-$SIGNALVERSION.tar.gz ]; then
		echo "failed"
		exit
	else
		echo "done"
		echo "Unpacking ..."
		cd $SIGNALPATH
		tar xf /tmp/signal-cli-$SIGNALVERSION.tar.gz
		rm -rf signal
		mv "signal-cli-$SIGNALVERSION" signal
		if [ -n "$RASPI" ]; then
			echo "Downloading native armv7l libraries..."
			cd /tmp
			rm -rf libsignal_jni.so libzkgroup.so
			wget -qN http://bublath.de/signal/libsignal_jni.so http://bublath.de/signal/libzkgroup.so
			echo "done"
			echo -n "Updating native x86 since you're on Raspberry..."
			zip -u $SIGNALPATH/signal/lib/zkgroup-java-*.jar libzkgroup.so
			#Disable for now since that is only required for 0.7.5+
			#zip -u $SIGNALPATH/signal/lib/signal-client-java-*.jar libsignal_jni.so
			mv libsignal_jni.so libzkgroup.so $LIBPATH
			echo "done"
		fi
		echo "done"
		echo -n "Changing file ownership ..."
		echo "done"
		rm -f /tmp/signal-cli-$SIGNALVERSION.tar.gz
	fi
fi

#Updating ownership anyway - just if case
chown -R $SIGNALUSER: $SIGNALVAR
chown -R $SIGNALUSER: $SIGNALPATH/signal

if [ -z "$DOCKER" ]; then
	#Don't do this in Docker environment

cat >$TMPFILE <<EOF
<?xml version="1.0"?> <!--*-nxml-*-->
	<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
	  "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
	
	<busconfig>
	  <policy user="$SIGNALUSER">
	          <allow own="org.asamk.Signal"/>
	          <allow send_destination="org.asamk.Signal"/>
	          <allow receive_sender="org.asamk.Signal"/>
	  </policy>
	
	  <policy context="default">
	          <allow send_destination="org.asamk.Signal"/>
	          <allow receive_sender="org.asamk.Signal"/>
	  </policy>
	</busconfig>

EOF

check_and_compare_file $DBSYSTEMD/org.asamk.Signal.conf $TMPFILE

cat >$TMPFILE <<EOF
[D-BUS Service]
Name=org.asamk.Signal
Exec=/bin/false
User=$SIGNALUSER
SystemdService=dbus-org.asamk.Signal.service
EOF

check_and_compare_file  $DBSYSTEMS/org.asamk.Signal.service $TMPFILE

cat >$TMPFILE <<EOF
[Unit]
Description=Send secure messages to Signal clients
Requires=dbus.socket
After=dbus.socket
Wants=network-online.target
After=network-online.target
	
[Service]
Type=dbus
Environment="SIGNAL_CLI_OPTS=-Xms2m"
ExecStart=$SIGNALPATH/signal/bin/signal-cli --config $SIGNALVAR -u "$PHONE" daemon --system
User=$SIGNALUSER
BusName=org.asamk.Signal
	
[Install]
Alias=dbus-org.asamk.Signal.service
EOF

	check_and_compare_file  $SYSTEMD/signal.service $TMPFILE

	#Reload config after change
	systemctl daemon-reload
	systemctl enable signal.service
	systemctl reload dbus.service
fi
}

#stop service depeding on Docker or not
stop_service() {
  if [ -z "$DOCKER" ]; then
	echo "Stopping signal-cli service"
	service signal stop
  else
	SIGSERVICE=`ps -eo pid,command | grep $SIGNALVAR | grep -v grep`
	if [ -n "$SIGSERVICE" ]; then
		echo "Stopping signal-cli daemon for Docker"
		ARRAY=($SIGSERVICE)
		PID=${ARRAY[0]}
		kill $PID
	fi
  fi
}

#start service depending on Docker or not
start_service() {
	if [ -z "$DOCKER" ]; then
		echo "Start signal-cli service"
		service signal start
	else
		DBDAEMON=`ps -eo command | grep dbus-daemon | grep -v grep`
		if [ -z "$DBDAEMON" ]; then
			rm /run/dbus/pid
			echo "Starting dbus daemon for Docker"
			dbus-daemon --system --address=unix:path=/run/dbus/system_bus_socket >/var/log/dbus.log 2>/var/log/dbus.err &
		fi
		echo -n "Waiting for dbus to become ready."
		WAIT=""
		while [ -z "$WAIT" ]
		do
			WAIT=`ps -eo pid,command | grep dbus-daemon | grep -v grep`
			echo -n "."
			sleep 1
		done
		echo "running"
		SIGSERVICE=`ps -eo pid,command | grep $SIGNALVAR | grep -v grep`
		WAITCHECK="ps -eo pid,command | grep $SIGNALVAR | grep java | grep -v grep"
		if [ -z "$SIGSERVICE" ]; then
			cd $SIGNALPATH/signal/bin
			echo "Starting signal-cli daemon for Docker"
			sudo -u $SIGNALUSER ./signal-cli --config $SIGNALVAR -u $PHONE daemon --system >/var/log/signal.log 2>/var/log/signal.err &
			WAITCHECK="grep dbus /var/log/signal.err"
		fi
		echo -n "Waiting for signal-cli to become ready."
		WAIT=""
		while [ -z "$WAIT" ]
		do
			WAIT=`$WAITCHECK`
			echo -n "."
			sleep 1
		done
		echo "running"
	fi
}


link_device() {
cd $SIGNALPATH/signal/bin
echo "Linking to existing number"
echo
echo "Open PNG in /tmp/qrcode.png that will appear in a couple of seconds and scan with your primary device"
echo "Process will continue after successfully scanning qrcode and accepting link"
echo "If you take too long, it will timeout and needs to be repeated"
stop_service
sudo -u $SIGNALUSER ./signal-cli --config $SIGNALVAR link -n `hostname` | xargs -L 1 qrencode -o /tmp/qrcode.png

echo "Reading account data"
sudo -u $SIGNALUSER ./signal-cli --config $SIGNALVAR receive
start_service
echo "done"
}

register_device() {
cd $SIGNALPATH/signal/bin

echo "Registering for $PHONE"
echo
echo -n "Receive registration code for $PHONE by (S)MS or (V)oice (s/v)? "
read REPLY
OPTION="";
if [ "$REPLY" = "s" ]; then
	OPTION=""
	echo "Registering $PHONE with SMS"
elif [ "$REPLY" = "v" ]; then
	OPTION="--voice"
	echo "Registering $PHONE with Voice call"
else 
	echo "Unknown option $REPLY, exiting"
	exit
fi
stop_service
sudo -u $SIGNALUSER ./signal-cli --config $SIGNALVAR -u $PHONE register $OPTION 2>$TMPFILE
CAPTCHA=`cat $TMPFILE | grep Captcha`
if [ -n "$CAPTCHA" ]; then
echo "*** Signal requires a CAPTCHA , use any browser to go to:" 
echo "*** https://signalcaptchas.org/registration/generate.html"
echo "*** Solve the captcha there (might also just be an empty page) then press F12"
echo "*** On Chrome go to Network, press Ctrl+R, look into the 'name' column of the table"
echo "*** On Firefox Go to console"
echo "*** Now find the name starting with signalcaptcha://"
echo "*** copy that string with out the signalcaptcha:// (right click -> copy link adress)"
echo -n "Paste it here:"
read REPLY
sudo -u $SIGNALUSER ./signal-cli --config $SIGNALVAR -u $PHONE register $OPTION --captcha $REPLY
fi

echo "You should get a call or SMS now providing a 6 digit code"
echo -n "Enter this code here:"
read REPLY
sudo -u $SIGNALUSER ./signal-cli --config $SIGNALVAR -u $PHONE verify $REPLY

echo "checking and receiving"
sudo -u $SIGNALUSER ./signal-cli --config $SIGNALVAR -u $PHONE receive
start_service
}

join_group() {
echo "Please enter the uri link (created share group link, looking like https://signal.group/......"
echo -n "Group:"
read REPLY
RECIPIENT=$REPLY
stop_service
echo "If you get a 'in use, waiting' message, then stopping of system Signal service did not succeed. Press Ctrl-C and try again"
cd $SIGNALPATH/signal/bin
sudo -u $SIGNALUSER ./signal-cli --config $SIGNALVAR -u $PHONE join --uri $RECIPIENT
start_service
echo "If the recipient got the messages, your setup looks healthy and you're ready to go to set up Signalbot in FHEM"
}

name_user() {
echo "Please are name for your Signal User with number $PHONE (You have to update the name if you want to set a picture!)"
echo -n "Name:"
read REPLY
NAME=$REPLY
echo "Please provide a filename to a picture to be used as avatar for your user (press return to keep unchanged)"
echo -n "File:"
read REPLY
AVATAR=`pwd`/$REPLY
if [ -n "$AVATAR" ]; then
	if ! [ -e "$AVATAR" ]; then
		echo "File $AVATAR was not found"
		return
	fi
fi
	
if [ -z "$NAME" ]; then
	echo "Nothing to do (you need a name to change the picture)"
	return;
fi

stop_service
echo "If you get a 'in use, waiting' message, then stopping of system Signal service did not succeed. Press Ctrl-C and try again"
cd $SIGNALPATH/signal/bin
if [ -n "$AVATAR" ]; then
	SETAVATAR="--avatar $AVATAR"
fi
if [ -n "$NAME" ]; then
	sudo -u $SIGNALUSER ./signal-cli --config $SIGNALVAR -u $PHONE updateProfile --name "$NAME" $SETAVATAR
fi
#Make sure local config is updated
sudo -u $SIGNALUSER ./signal-cli --config $SIGNALVAR -u $PHONE receive
stop_service
echo "Your profile has been updated"
}

test_device() {
echo "Please enter the number (+49...) of somebody that you can send a test message to"
echo -n "Number:"
read REPLY
RECIPIENT=$REPLY
if [ -z "$REPLY" ]; then
	return
fi
echo "Sending a message from command line to $RECIPIENT"
stop_service
echo "If you get a 'in use, waiting' message, skip by pressing CTRL-C - this is normal when system service is already up and running"
cd $SIGNALPATH/signal/bin
sudo -u $SIGNALUSER ./signal-cli --config $SIGNALVAR -u $PHONE send -m "Test message from the command line" "$RECIPIENT"
echo "checking and receiving"
sudo -u $SIGNALUSER ./signal-cli --config $SIGNALVAR -u $PHONE receive
start_service
echo "Sending a message via dbus-send command"
dbus-send --system --type=method_call --print-reply --dest="org.asamk.Signal" /org/asamk/Signal org.asamk.Signal.sendMessage string:"Test message via DBus" array:: string:$RECIPIENT
cat <<EOF >$TMPFILE
#!/usr/bin/perl -w
use strict;
use warnings;

use Net::DBus;

my @attachment =();
my @recipients=("$RECIPIENT");
my \$bus = Net::DBus->system(); 

my \$service = \$bus->get_service("org.asamk.Signal");
my \$object = \$service->get_object("/org/asamk/Signal");

my \$retcode = \$object->sendMessage("Testmessage from DBUS-Perl",\\@attachment,\\@recipients);
print "return timestamp:".\$retcode."\n";
EOF
echo "Sending a message via perl Net::DBus"
perl $TMPFILE
echo "If the recipient got all three messages, your setup looks healthy and you're ready to go to set up Signalbot in FHEM"
}

remove_all() {
#just in case paths are wrong to not accidentially remove wrong things
 cd /tmp
echo "Warning. This will remove signal-cli and all related configurations from your system"
echo "Your configuration will be archived to $HOME/signalconf.tar.gz"
echo -n "Continue (y/N)? "
read REPLY
if ! [ "$REPLY" = "y" ]; then
	echo "Abort"
	exit
fi

stop_service

echo "Archiving config"
tar czf ~/signalconf.tar.gz $SIGNALVAR
echo "Removing files"
rm -rf $SIGNALVAR
rm -rf $SIGNALPATH/signal
rm -f $LIBPATH/libsignal_jni.so 
rm -f $LIBPATH/libzkgroup.so 
rm -f $DBSYSTEMD/org.asamk.Signal.conf
rm -f $DBSYSTEMS/org.asamk.Signal.service
rm -f $SYSTEMD/signal.service
echo "Disabling services"
if [ -z "$DOCKER" ]; then
	systemctl daemon-reload
	systemctl disable signal.service
	systemctl reload dbus.service
else
	DBDAEMON=`ps -eo pid,command | grep dbus-daemon | grep -v grep`
	if [ -n "$DBDAEMON" ]; then
		echo "Stopping dbus daemon for Docker"
		ARRAY=($DBDAEMON)
		PID=${ARRAY[0]}
		kill $PID
	fi
fi

}


if [ -z $OPERATION ]; then
	echo "This will update system packages, install signal-cli and help to register with Signal service"
	echo
	echo "To do this rather step by step use the command line arguments or just proceed to do system,install,register:"
	echo "system   : prepare required system package (except signal-cli) - make sure you ran this before you do anything else!"
	echo "install  : install signal-cli and setup as dbus system service"
	echo "register : register a NEW number with Signal"
	echo "link     : link an EXISTING number with Signal (e.g. you Smartphone)"
	echo "test     : run a basic test if everything is installed and registered correctly"
	echo "remove   : Remove signal-cli and all configurations (will be archived)"
	echo "join     : Join current number to an existing group (invite by group link)"
	echo "name     : set or change Signal user name and/or avatar picture"
	echo "start    : Start the signal-cli service (or respective docker processes)"
	echo
	echo "!!! Everything needs to run with sudo/root !!!"
else
	echo "Your chose the following option: $OPERATION"
fi
echo
if [ -z "$OPERATION" ] || [ "$OPERATION" = "system" ] || [ "$OPERATION" = "install" ] || [ "$OPERATION" = "all" ]; then
  echo -n "Proceed (Y/n)? "
  read REPLY
  if [ "$REPLY" = "n" ]; then
	echo "Aborting..."
	exit
  fi
fi

# Main flow without option: intall, register
if [ -z "$OPERATION" ] || [ $OPERATION = "all" ] || [ $OPERATION = "system" ]; then
	check_and_update
fi

if [ -z "$OPERATION" ] || [ $OPERATION = "all" ] || [ $OPERATION = "install" ]; then
	install_signal_cli
fi

if [ -z "$OPERATION" ] || [ $OPERATION = "all" ]; then
	cd $SIGNALPATH/signal/bin
	if [ -d $SIGNALVAR/data ]; then
		if [ -e $SIGNALVAR/data/$PHONE ]; then
			echo "Your device $PHONE is already configured, do want to run through registration again?"
		else
			echo "You already seem to have a device configured, add $PHONE instead?"
		fi
		echo -n "Continue (y) or skip (N)?"
		read REPLY	
		if [ "$REPLY" = "y" ]; then
			echo "You can either"
			echo "(r) register a new device (if that device is already registered e.g. to a smartphone that will be removed)"
			echo "(l) link to an already registered device (both device will get the messages)"
			echo "It is recommended to register a new device e.g. a land-line for usage with FHEM"
			echo -n "register or link (r/l)"
			read REPLY
			if [ "$REPLY" = "r" ]; then
				register_device
			elif [ "$REPLY" = "l" ]; then
				link_device
			fi
		fi
	fi
fi

if [ "$OPERATION" = "register" ]; then
	register_device
fi

if [ -z "$OPERATION" ] || [ $OPERATION = "all" ] || [ $OPERATION = "test" ]; then
	test_device
fi

if [ -z "$OPERATION" ]; then
	exit
fi

# Other options
if [ $OPERATION = "remove" ]; then 
	remove_all
fi

if [ $OPERATION = "link" ]; then
	link_device
fi

if [ $OPERATION = "start" ]; then
	start_service
fi

if [ $OPERATION = "name" ]; then
	name_user
fi

if [ $OPERATION = "join" ]; then
	join_group
fi

rm -f $TMPFILE

exit
