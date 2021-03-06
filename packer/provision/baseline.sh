#!/bin/bash

set -x

# vim: ts=4 sw=4 sts=4 et tw=72 :

rh_systems() {
    # Handle the occurance where SELINUX is actually disabled
    SELINUX=$(grep -E '^SELINUX=(disabled|permissive|enforcing)$' /etc/selinux/config)
    MODE=$(echo "$SELINUX" | cut -f 2 -d '=')
    case "$MODE" in
        permissive)
            echo "************************************"
            echo "** SYSTEM ENTERING ENFORCING MODE **"
            echo "************************************"
            # make sure that the filesystem is properly labelled.
            # it could be not fully labeled correctly if it was just switched
            # from disabled, the autorelabel misses some things
            # skip relabelling on /dev as it will generally throw errors
            restorecon -R -e /dev /

            # enable enforcing mode from the very start
            setenforce enforcing

            # configure system for enforcing mode on next boot
            sed -i 's/SELINUX=permissive/SELINUX=enforcing/' /etc/selinux/config
        ;;
        disabled)
            sed -i 's/SELINUX=disabled/SELINUX=permissive/' /etc/selinux/config
            touch /.autorelabel

            echo "*******************************************"
            echo "** SYSTEM REQUIRES A RESTART FOR SELINUX **"
            echo "*******************************************"
        ;;
        enforcing)
            echo "*********************************"
            echo "** SYSTEM IS IN ENFORCING MODE **"
            echo "*********************************"
        ;;
    esac

    echo "---> Updating operating system"
    yum clean all -q
    yum install -y -q deltarpm
    yum update -y -q

    # add in components we need or want on systems
    echo "---> Installing base packages"
    yum install -y -q @base https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
    # separate group installs from package installs since a non-existing
    # group with dnf based systems (F21+) will fail the install if such
    # a group does not exist
    yum install -y -q unzip xz puppet git perl-XML-XPath wget make

    # All of our systems require Java (because of Jenkins)
    # Install all versions of the OpenJDK devel but force 1.7.0 to be the
    # default

    echo "---> Configuring OpenJDK"
    yum install -y -q 'java-*-openjdk-devel'

    FACTER_OS=$(/usr/bin/facter operatingsystem)
    FACTER_OSVER=$(/usr/bin/facter operatingsystemrelease)
    case "$FACTER_OS" in
        Fedora)
            if [ "$FACTER_OSVER" -ge "21" ]
            then
                echo "---> not modifying java alternatives as OpenJDK 1.7.0 does not exist"
            else
                alternatives --set java /usr/lib/jvm/jre-1.7.0-openjdk.x86_64/bin/java
                alternatives --set java_sdk_openjdk /usr/lib/jvm/java-1.7.0-openjdk.x86_64
            fi
        ;;
        *)
            alternatives --set java /usr/lib/jvm/jre-1.7.0-openjdk.x86_64/bin/java
            alternatives --set java_sdk_openjdk /usr/lib/jvm/java-1.7.0-openjdk.x86_64
        ;;
    esac
}

ubuntu_systems() {
    # Ignore SELinux since slamming that onto Ubuntu leads to
    # frustration

    export DEBIAN_FRONTEND=noninteractive
    cat <<EOF >> /etc/apt/apt.conf
APT {
  Get {
    Assume-Yes "true";
    allow-change-held-packages "true";
    allow-downgrades "true";
    allow-remove-essential "true";
  };
};

Dpkg::Options {
  "--force-confdef";
  "--force-confold";
};

EOF

    # Make sure that we aren't using the vexxhost mirrors as they have issues
    echo "---> Removing Vexxhost Ubuntu mirrors"
    sed -i 's/ubuntu.mirror.vexxhost.com/us.archive.ubuntu.com/g' /etc/apt/sources.list

    echo "---> printing sources.list <---"
    cat /etc/apt/sources.list
    echo "---> printing sources.list <---"

    echo "---> printing resolv.conf <---"
    cat /etc/resolv.conf || true
    echo "---> printing resolv.conf <---"

    ping -c 2 172.30.0.254
    ping -c 2 172.30.0.253

    echo "---> Updating operating system"
    apt-get update
    apt-get dist-upgrade -y

    # add in stuff we know we need
    echo "---> Installing base packages"
    apt-get install -y unzip xz-utils puppet git libxml-xpath-perl make wget

    # install Java 7
    echo "---> Configuring OpenJDK"
    apt-get install -y default-jre-headless default-jdk-headless

}

all_systems() {
    # Allow jenkins access to update-alternatives command to switch java version
    cat <<EOF >/etc/sudoers.d/89-jenkins-user-defaults
Defaults:jenkins !requiretty
jenkins ALL = NOPASSWD: /usr/bin/update-alternatives
EOF

    # The following installs hashicorp's packer binary which is required  for
    # ci-management-{verify,merge}-packer jobs
    mkdir /tmp/packer
    cd /tmp/packer
    wget https://releases.hashicorp.com/packer/1.0.0/packer_1.0.0_linux_amd64.zip
    unzip packer_1.0.0_linux_amd64.zip -d /usr/local/bin/
    # rename packer to avoid conflict with binary in cracklib
    mv /usr/local/bin/packer /usr/local/bin/packer.io

    # Do any Distro specific installations here
    echo "Checking distribution"
    FACTER_OS=$(/usr/bin/facter operatingsystem)
    case "$FACTER_OS" in
        *)
            echo "---> $FACTER_OS found"
            echo "No extra steps for $FACTER_OS"
        ;;
    esac
}

echo "---> Attempting to detect OS"
# upstream cloud images use the distro name as the initial user
ORIGIN=$(if [ -e /etc/redhat-release ]
    then
        echo redhat
    else
        echo ubuntu
    fi)
#ORIGIN=$(logname)

case "${ORIGIN}" in
    fedora|centos|redhat)
        echo "---> RH type system detected"
        rh_systems
    ;;
    ubuntu)
        echo "---> Ubuntu system detected"
        ubuntu_systems
    ;;
    *)
        echo "---> Unknown operating system"
    ;;
esac

# execute steps for all systems
all_systems
