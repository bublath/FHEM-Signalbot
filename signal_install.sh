#!/bin/bash

PHONE="+49xxxxx"
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

#Get OS data
if [ -e /etc/os-release ]; then
	source /etc/os-release
	cat /etc/os-release >$LOG
else
	echo "Could not find OS release data - are you on Linux?"
	exit
fi

if grep -q docker /proc/1/cgroup; then 
   echo "You seem to run in a docker environment. This installation needs to run on the host machine (FHEM can be in a container later)"
   exit
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
RASPI=0

if [ $OSNAME != "Linux" ]; then
	echo "Only Linux systems are supported (you: $OSNAME), quitting"
	exit
fi

if [ "$ID" = "raspbian" ] || [ "$ID" = "Raspian" ] || [ "$ARCH" = "armv71" ]; then
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
check_and_create_path $DBSYSTEMD
check_and_create_path $DBSYSTEMS
check_and_create_path $SYSTEMD



install_and_check wget wget
install_and_check haveged haveged
install_and_check java default-jre
install_and_check diff diffutils
install_and_check dbus-send dbus
install_and_check cpan cpanminus
install_and_check qrencode qrencode
install_and_check pkg-config pkg-config
install_and_check gcc gcc

#For DBus check a number of Perl modules on file level
install_by_file /usr/include/dbus-1.0/dbus/dbus.h libdbus-1-dev
install_by_file /usr/share/perl5/Test/CPAN/Changes.pm libcpan-changes-perl
install_by_file /usr/include/expat.h libexpat1-dev
install_by_file /usr/share/doc-base/libxml-parser-perl libxml-parser-perl


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
	echo "V$NETBUS found"
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
		if [ -n "$RASPI" ]; then
			echo -n "Removing native x86 since you're on Raspberry..."
			zip -d $SIGNALPATH/signal/lib/zkgroup-java-*.jar libzkgroup.so
			zip -d $SIGNALPATH/signal/lib/signal-client-java-*.jar libsignal_jni.so
			echo "done"
			echo "Downloading native armv71 libraries..."
			cd /tmp
			rm -rf libsignal_jni.so libzkgroup.so
			wget -qN http://bublath.de/signal/libsignal_jni.so http://bublath.de/signal/libzkgroup.so
			mv libsignal_jni.so libzkgroup.so $LIBDIR
			echo "done"
		fi
		rm -rf signal
		mv "signal-cli-$SIGNALVERSION" signal
		echo "done"
		echo -n "Changing file ownership ..."
		echo "done"
		rm -f /tmp/signal-cli-$SIGNALVERSION.tar.gz
	fi
fi

#Updating ownership anyway - just if case
chown -R $SIGNALUSER: $SIGNALVAR
chown -R $SIGNALUSER: $SIGNALPATH/signal


cat >$TMPFILE <<EOF
<?xml version="1.0"?> <!--*-nxml-*-->
	<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
	  "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
	
	<busconfig>
	  <policy user="signal-cli">
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
}

link_device() {
cd $SIGNALPATH/signal/bin
echo "Linking to existing number"
echo
echo "Open PNG in /tmp/qrcode.png that will appear in a couple of seconds and scan with your primary device"
echo "Process will continue after successfully scanning qrcode and accepting link"
echo "If you take too long, it will timeout and needs to be repeated"
echo "Stopping Signal service to get exclusive access to configuration"
sudo service signal stop
sudo -u $SIGNALUSER ./signal-cli --config $SIGNALVAR link -n `hostname` | xargs -L 1 qrencode -o /tmp/qrcode.png

echo "Reading account data"
sudo -u $SIGNALUSER ./signal-cli --config $SIGNALVAR receive
echo "Restarting signal service"
sudo service signal start
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
fi
if [ "$REPLY" = "v" ]; then
	OPTION="--voice"
	echo "Registering $PHONE with Voice call"
fi

if [ -z "$OPTION" ]; then
	echo "Unknown option $OPTION, exiting"
	exit
fi
echo "Stopping Signal service to get exclusive access to configuration"
sudo service signal stop
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
echo "Restarting signal service"
sudo service signal start
}

join_group() {
echo "Please enter the uri link (created share group link, looking like https://signal.group/......"
echo -n "Group:"
read REPLY
RECIPIENT=$REPLY
echo "Stopping Signal service to get exclusive access to configuration"
sudo service signal stop
echo "If you get a 'in use, waiting' message, then stopping of system Signal service did not succeed. Press Ctrl-C and try again"
cd $SIGNALPATH/signal/bin
sudo -u $SIGNALUSER ./signal-cli --config $SIGNALVAR -u $PHONE join --uri $RECIPIENT
echo "Restarting signal service"
sudo service signal start
echo "If the recipient got the messages, your setup looks healthy and you're ready to go to set up Signalbot in FHEM"
}

test_device() {
echo "Please enter the number (+49...) of somebody that you can send a test message to"
echo -n "Number:"
read REPLY
RECIPIENT=$REPLY
echo "Sending a message from command line to $RECIPIENT"
echo "Stopping Signal service to get exclusive access to configuration"
sudo service signal stop
echo "If you get a 'in use, waiting' message, skip by pressing CTRL-C - this is normal when system service is already up and running"
cd $SIGNALPATH/signal/bin
sudo -u $SIGNALUSER ./signal-cli --config $SIGNALVAR -u $PHONE send -m "Test message from the command line" $RECIPIENT
sudo service signal start
echo "Sending a message from via dbus to $RECIPIENT"
dbus-send --system --type=method_call --print-reply --dest="org.asamk.Signal" /org/asamk/Signal org.asamk.Signal.sendMessage string:"Test message via DBus" array:: string:$RECIPIENT
echo "Restarting signal service"
echo "If the recipient got the messages, your setup looks healthy and you're ready to go to set up Signalbot in FHEM"
}

remove_all() {
#just in case paths are wrong to not accidentially remove wrong things
 cd /tmp
echo "Warning. This will remove signal-cli and all related configurations from your system"
echo -n "Continue (y/N)? "
read REPLY
if ! [ "$REPLY" = "y" ]; then
	echo "Abort"
	exit
fi

rm -r $SIGNALVAR
rm -rf $SIGNALPATH/signal
rm $LIBDIR/libsignal_jni.so 
rm $LIBDIR/libzkgroup.so 
rm $DBSYSTEMD/org.asamk.Signal.conf
rm $DBSYSTEMS/org.asamk.Signal.service
rm $SYSTEMD/signal.service

systemctl daemon-reload
systemctl disable signal.service
systemctl reload dbus.service
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
	echo "remove   : Remove signal-cli and all configurations"
	echo "join     : Join current number to an existing group (invite by group link)"
	echo
	echo "!!! Everything needs to run with sudo !!!"
else
	echo "Your chose the following option: $OPERATION"
fi
echo
echo -n "Proceed (Y/n)? "
read REPLY
if [ "$REPLY" = "n" ]; then
	echo "Aborting..."
	exit
fi

# Main flow without option: intall, register
if [ -z "$1" ] || [ $1 = "system" ]; then
	check_and_update
fi

if [ -z "$1" ] || [ $1 = "install" ]; then
	install_signal_cli
fi

if [ -z "$1" ] || [ $1 = "register" ]; then
	register_device
fi

if [ -z "$1" ] || [ $1 = "test" ]; then
	test_device
fi

if [ -z "$1" ]; then
	exit
fi

# Other options
if [ $1 = "remove" ]; then 
	remove_all
fi

if [ $1 = "link" ]; then
	link_device
fi

if [ $1 = "join" ]; then
	join_group
fi

exit
