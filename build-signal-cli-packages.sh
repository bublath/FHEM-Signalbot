#!/bin/bash
echo "This script expects that signal-cli is freshly build and has the x86 libraries included"
SIGNALSOURCE=~/src/signal-cli-main
VERSION=0.9.0

cp -r package ~/signal-cli-dbus_$VERSION-1_amd64
cp -r package ~/signal-cli-dbus_$VERSION-1_armhf

#change Architectur in amd64 version
sed -i 's/armhf/amd64/' ~/signal-cli-dbus_$VERSION-1_amd64/DEBIAN/control

#Copy signal-cli files
cp -r $SIGNALSOURCE/build/install/signal-cli/* ~/signal-cli-dbus_$VERSION-1_amd64/opt/signal
cp -r $SIGNALSOURCE//build/install/signal-cli/* ~/signal-cli-dbus_$VERSION-1_armhf/opt/signal

#Copy ARM specific libraries
cp armv7l-$VERSION//*.so ~/signal-cli-dbus_$VERSION-1_armhf/opt/signal/lib
cd ~/signal-cli-dbus_$VERSION-1_armhf/opt/signal/lib
zip -u signal-client-java-*.jar libsignal_jni.so
zip -u zkgroup-java-*.jar libzkgroup.so
rm *.so
cd ~/
dpkg-deb --build --root-owner-group signal-cli-dbus_0.9.0-1_armhf
dpkg-deb --build --root-owner-group signal-cli-dbus_0.9.0-1_amd64
