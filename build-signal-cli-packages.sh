#!/bin/bash
echo "This script expects that signal-cli is freshly build"
LIBSOURCE=~/src/FHEM-Signalbot
SIGNALSOURCE=~/src/signal-cli-main/build/install/signal-cli
VERSION=0.9.0
echo "Version $VERSION , signal-cli in $SIGNALSOURCE , binary libs in $LIBSOURCE"

make_package() {
	cd $LIBSOURCE
	ARCH=$1
	GLIB=$2
	DIR=signal-cli-dbus_$VERSION-1_$GLIB\_$ARCH
	echo "Creating archive for $DIR"
	rm -r ~/$DIR
	mkdir ~/$DIR
	cp -r package/* ~/$DIR
	if [ $ARCH = "amd64" ]; then
		sed -i 's/armhf/amd64/' ~/$DIR/DEBIAN/control
	fi
	cp -r $SIGNALSOURCE/* ~/$DIR/opt/signal
	cp $ARCH-$GLIB-$VERSION/*.so ~/$DIR/opt/signal/lib
	cd ~/$DIR/opt/signal/lib
	zip -u signal-client-java-*.jar libsignal_jni.so
	zip -u zkgroup-java-*.jar libzkgroup.so
	rm *.so
	cd ~/
	dpkg-deb --build --root-owner-group $DIR
}

if [ $1 == "amd64" ] || [ $1 == "armhf" ]; then
   make_package $1 $2
   exit
fi

make_package amd64 glibc2.28
make_package amd64 glibc2.27
make_package amd64 glibc2.31
make_package armhf glibc2.28
