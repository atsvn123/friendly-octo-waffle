#!/bin/bash
export THEOS=/opt/theos
export PATH=/opt/theos/toolchain/linux/iphone/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
cd /tmp/VCAMBUILD/VCAMVIP_theos
make clean 2>&1
make 2>&1
echo EXIT:$?
