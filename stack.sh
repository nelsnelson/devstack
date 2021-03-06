#!/usr/bin/env bash

# ``stack.sh`` is an opinionated OpenStack developer installation.  It
# installs and configures various combinations of **Ceilometer**, **Cinder**,
# **Glance**, **Heat**, **Horizon**, **Keystone**, **Nova**, **Neutron**,
# and **Swift**

# This script's options can be changed by setting appropriate environment
# variables.  You can configure things like which git repositories to use,
# services to enable, OS images to use, etc.  Default values are located in the
# ``stackrc`` file. If you are crafty you can run the script on multiple nodes
# using shared settings for common resources (eg., mysql or rabbitmq) and build
# a multi-node developer install.

# To keep this script simple we assume you are running on a recent **Ubuntu**
# (12.04 Precise or newer) or **Fedora** (F18 or newer) machine.  (It may work
# on other platforms but support for those platforms is left to those who added
# them to DevStack.)  It should work in a VM or physical server.  Additionally
# we maintain a list of ``apt`` and ``rpm`` dependencies and other configuration
# files in this repo.

# Learn more and get the most recent version at http://devstack.org

# Make sure custom grep options don't get in the way
unset GREP_OPTIONS

# Sanitize language settings to avoid commands bailing out
# with "unsupported locale setting" errors.
unset LANG
unset LANGUAGE
LC_ALL=C
export LC_ALL

# Make sure umask is sane
umask 022

# Not all distros have sbin in PATH for regular users.
PATH=$PATH:/usr/local/sbin:/usr/sbin:/sbin

# Keep track of the devstack directory
TOP_DIR=$(cd $(dirname "$0") && pwd)

# Sanity Checks
# -------------

# Clean up last environment var cache
if [[ -r $TOP_DIR/.stackenv ]]; then
    rm $TOP_DIR/.stackenv
fi

# ``stack.sh`` keeps the list of ``apt`` and ``rpm`` dependencies and config
# templates and other useful files in the ``files`` subdirectory
FILES=$TOP_DIR/files
if [ ! -d $FILES ]; then
    die $LINENO "missing devstack/files"
fi

# ``stack.sh`` keeps function libraries here
# Make sure ``$TOP_DIR/lib`` directory is present
if [ ! -d $TOP_DIR/lib ]; then
    die $LINENO "missing devstack/lib"
fi

# Check if run as root
# OpenStack is designed to be run as a non-root user; Horizon will fail to run
# as **root** since Apache will not serve content from **root** user).
# ``stack.sh`` must not be run as **root**.  It aborts and suggests one course of
# action to create a suitable user account.

if [[ $EUID -eq 0 ]]; then
    echo "You are running this script as root."
    echo "Cut it out."
    echo "Really."
    echo "If you need an account to run DevStack, do this (as root, heh) to create a non-root account:"
    echo "$TOP_DIR/tools/create-stack-user.sh"
    exit 1
fi

# Prepare the environment
# -----------------------

# Import common functions
source $TOP_DIR/functions

# Import config functions
source $TOP_DIR/lib/config

# Determine what system we are running on.  This provides ``os_VENDOR``,
# ``os_RELEASE``, ``os_UPDATE``, ``os_PACKAGE``, ``os_CODENAME``
# and ``DISTRO``
GetDistro

# Global Settings
# ---------------

# Check for a ``localrc`` section embedded in ``local.conf`` and extract if
# ``localrc`` does not already exist

# Phase: local
rm -f $TOP_DIR/.localrc.auto
if [[ -r $TOP_DIR/local.conf ]]; then
    LRC=$(get_meta_section_files $TOP_DIR/local.conf local)
    for lfile in $LRC; do
        if [[ "$lfile" == "localrc" ]]; then
            if [[ -r $TOP_DIR/localrc ]]; then
                warn $LINENO "localrc and local.conf:[[local]] both exist, using localrc"
            else
                echo "# Generated file, do not edit" >$TOP_DIR/.localrc.auto
                get_meta_section $TOP_DIR/local.conf local $lfile >>$TOP_DIR/.localrc.auto
            fi
        fi
    done
fi


# ``stack.sh`` is customizable by setting environment variables.  Override a
# default setting via export::
#
#     export DATABASE_PASSWORD=anothersecret
#     ./stack.sh
#
# or by setting the variable on the command line::
#
#     DATABASE_PASSWORD=simple ./stack.sh
#
# Persistent variables can be placed in a ``localrc`` file::
#
#     DATABASE_PASSWORD=anothersecret
#     DATABASE_USER=hellaroot
#
# We try to have sensible defaults, so you should be able to run ``./stack.sh``
# in most cases.  ``localrc`` is not distributed with DevStack and will never
# be overwritten by a DevStack update.
#
# DevStack distributes ``stackrc`` which contains locations for the OpenStack
# repositories, branches to configure, and other configuration defaults.
# ``stackrc`` sources ``localrc`` to allow you to safely override those settings.

if [[ ! -r $TOP_DIR/stackrc ]]; then
    die $LINENO "missing $TOP_DIR/stackrc - did you grab more than just stack.sh?"
fi
source $TOP_DIR/stackrc

# Warn users who aren't on an explicitly supported distro, but allow them to
# override check and attempt installation with ``FORCE=yes ./stack``
if [[ ! ${DISTRO} =~ (precise|trusty|7.0|wheezy|sid|testing|jessie|f19|f20|f21|rhel6|rhel7) ]]; then
    echo "WARNING: this script has not been tested on $DISTRO"
    if [[ "$FORCE" != "yes" ]]; then
        die $LINENO "If you wish to run this script anyway run with FORCE=yes"
    fi
fi

# Check to see if we are already running DevStack
# Note that this may fail if USE_SCREEN=False
if type -p screen > /dev/null && screen -ls | egrep -q "[0-9]\.$SCREEN_NAME"; then
    echo "You are already running a stack.sh session."
    echo "To rejoin this session type 'screen -x stack'."
    echo "To destroy this session, type './unstack.sh'."
    exit 1
fi


# Local Settings
# --------------

# Make sure the proxy config is visible to sub-processes
export_proxy_variables

# Remove services which were negated in ENABLED_SERVICES
# using the "-" prefix (e.g., "-rabbit") instead of
# calling disable_service().
disable_negated_services

# Look for obsolete stuff
if [[ ,${ENABLED_SERVICES}, =~ ,"swift", ]]; then
    echo "FATAL: 'swift' is not supported as a service name"
    echo "FATAL: Use the actual swift service names to enable them as required:"
    echo "FATAL: s-proxy s-object s-container s-account"
    exit 1
fi

# Configure sudo
# --------------

# We're not **root**, make sure ``sudo`` is available
is_package_installed sudo || install_package sudo

# UEC images ``/etc/sudoers`` does not have a ``#includedir``, add one
sudo grep -q "^#includedir.*/etc/sudoers.d" /etc/sudoers ||
    echo "#includedir /etc/sudoers.d" | sudo tee -a /etc/sudoers

# Set up devstack sudoers
TEMPFILE=`mktemp`
echo "$STACK_USER ALL=(root) NOPASSWD:ALL" >$TEMPFILE
# Some binaries might be under /sbin or /usr/sbin, so make sure sudo will
# see them by forcing PATH
echo "Defaults:$STACK_USER secure_path=/sbin:/usr/sbin:/usr/bin:/bin:/usr/local/sbin:/usr/local/bin" >> $TEMPFILE
echo "Defaults:$STACK_USER !requiretty" >> $TEMPFILE
chmod 0440 $TEMPFILE
sudo chown root:root $TEMPFILE
sudo mv $TEMPFILE /etc/sudoers.d/50_stack_sh


# Configure Distro Repositories
# -----------------------------

# For debian/ubuntu make apt attempt to retry network ops on it's own
if is_ubuntu; then
    echo 'APT::Acquire::Retries "20";' | sudo tee /etc/apt/apt.conf.d/80retry  >/dev/null
fi

# Some distros need to add repos beyond the defaults provided by the vendor
# to pick up required packages.

if is_fedora && [[ $DISTRO == "rhel6" || $DISTRO == "rhel7" ]]; then
    # RHEL requires EPEL for many Open Stack dependencies

    # note we always remove and install latest -- some environments
    # use snapshot images, and if EPEL version updates they break
    # unless we update them to latest version.
    if sudo yum repolist enabled epel | grep -q 'epel'; then
        uninstall_package epel-release || true
    fi

    # This trick installs the latest epel-release from a bootstrap
    # repo, then removes itself (as epel-release installed the
    # "real" repo).
    #
    # you would think that rather than this, you could use
    # $releasever directly in .repo file we create below.  However
    # RHEL gives a $releasever of "6Server" which breaks the path;
    # see https://bugzilla.redhat.com/show_bug.cgi?id=1150759
    if [[ $DISTRO == "rhel7" ]]; then
        epel_ver="7"
    elif [[ $DISTRO == "rhel6" ]]; then
        epel_ver="6"
    fi

    cat <<EOF | sudo tee /etc/yum.repos.d/epel-bootstrap.repo
[epel-bootstrap]
name=Bootstrap EPEL
mirrorlist=http://mirrors.fedoraproject.org/mirrorlist?repo=epel-$epel_ver&arch=\$basearch
failovermethod=priority
enabled=0
gpgcheck=0
EOF
    # bare yum call due to --enablerepo
    sudo yum --enablerepo=epel-bootstrap -y install epel-release || \
        die $LINENO "Error installing EPEL repo, cannot continue"
    # epel rpm has installed it's version
    sudo rm -f /etc/yum.repos.d/epel-bootstrap.repo

    # ... and also optional to be enabled
    is_package_installed yum-utils || install_package yum-utils
    if [[ $DISTRO == "rhel7" ]]; then
        OPTIONAL_REPO=rhel-7-server-optional-rpms
    elif [[ $DISTRO == "rhel6" ]]; then
        OPTIONAL_REPO=rhel-6-server-optional-rpms
    fi
    sudo yum-config-manager --enable ${OPTIONAL_REPO}

    # Installing Open vSwitch on RHEL requires enabling the RDO repo.
    # Note no juno packages for rhel6
    if [[ $DISTRO == "rhel6" ]]; then
        RHEL_RDO_REPO_RPM=${RHEL6_RDO_REPO_RPM:-"https://repos.fedorapeople.org/repos/openstack/openstack-icehouse/rdo-release-icehouse-4.noarch.rpm"}
        RHEL_RDO_REPO_ID=${RHEL6_RDO_REPO_ID:-"openstack-icehouse"}
    elif [[ $DISTRO == "rhel7" ]]; then
        RHEL_RDO_REPO_RPM=${RHEL7_RDO_REPO_RPM:-"https://repos.fedorapeople.org/repos/openstack/openstack-juno/rdo-release-juno-1.noarch.rpm"}
        RHEL_RDO_REPO_ID=${RHEL7_RDO_REPO_ID:-"openstack-juno"}
    fi

    if ! sudo yum repolist enabled $RHEL_RDO_REPO_ID | grep -q $RHEL_RDO_REPO_ID; then
        echo "RDO repo not detected; installing"
        yum_install $RHEL_RDO_REPO_RPM || \
            die $LINENO "Error installing RDO repo, cannot continue"
    fi

fi


# Configure Target Directories
# ----------------------------

# Destination path for installation ``DEST``
DEST=${DEST:-/opt/stack}

# Create the destination directory and ensure it is writable by the user
# and read/executable by everybody for daemons (e.g. apache run for horizon)
sudo mkdir -p $DEST
safe_chown -R $STACK_USER $DEST
safe_chmod 0755 $DEST

# a basic test for $DEST path permissions (fatal on error unless skipped)
check_path_perm_sanity ${DEST}

# Destination path for service data
DATA_DIR=${DATA_DIR:-${DEST}/data}
sudo mkdir -p $DATA_DIR
safe_chown -R $STACK_USER $DATA_DIR

# Configure proper hostname
# Certain services such as rabbitmq require that the local hostname resolves
# correctly.  Make sure it exists in /etc/hosts so that is always true.
LOCAL_HOSTNAME=`hostname -s`
if [ -z "`grep ^127.0.0.1 /etc/hosts | grep $LOCAL_HOSTNAME`" ]; then
    sudo sed -i "s/\(^127.0.0.1.*\)/\1 $LOCAL_HOSTNAME/" /etc/hosts
fi


# Configure Logging
# -----------------

# Set up logging level
VERBOSE=$(trueorfalse True $VERBOSE)

# Draw a spinner so the user knows something is happening
function spinner {
    local delay=0.75
    local spinstr='/-\|'
    printf "..." >&3
    while [ true ]; do
        local temp=${spinstr#?}
        printf "[%c]" "$spinstr" >&3
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b" >&3
    done
}

function kill_spinner {
    if [ ! -z "$LAST_SPINNER_PID" ]; then
        kill >/dev/null 2>&1 $LAST_SPINNER_PID
        printf "\b\b\bdone\n" >&3
    fi
}

# Echo text to the log file, summary log file and stdout
# echo_summary "something to say"
function echo_summary {
    if [[ -t 3 && "$VERBOSE" != "True" ]]; then
        kill_spinner
        echo -n -e $@ >&6
        spinner &
        LAST_SPINNER_PID=$!
    else
        echo -e $@ >&6
    fi
}

# Echo text only to stdout, no log files
# echo_nolog "something not for the logs"
function echo_nolog {
    echo $@ >&3
}

if is_fedora && [ $DISTRO == "rhel6" ]; then
    # poor old python2.6 doesn't have argparse by default, which
    # outfilter.py uses
    is_package_installed python-argparse || install_package python-argparse
fi

# Set up logging for ``stack.sh``
# Set ``LOGFILE`` to turn on logging
# Append '.xxxxxxxx' to the given name to maintain history
# where 'xxxxxxxx' is a representation of the date the file was created
TIMESTAMP_FORMAT=${TIMESTAMP_FORMAT:-"%F-%H%M%S"}
if [[ -n "$LOGFILE" || -n "$SCREEN_LOGDIR" ]]; then
    LOGDAYS=${LOGDAYS:-7}
    CURRENT_LOG_TIME=$(date "+$TIMESTAMP_FORMAT")
fi

if [[ -n "$LOGFILE" ]]; then
    # First clean up old log files.  Use the user-specified ``LOGFILE``
    # as the template to search for, appending '.*' to match the date
    # we added on earlier runs.
    LOGDIR=$(dirname "$LOGFILE")
    LOGFILENAME=$(basename "$LOGFILE")
    mkdir -p $LOGDIR
    find $LOGDIR -maxdepth 1 -name $LOGFILENAME.\* -mtime +$LOGDAYS -exec rm {} \;
    LOGFILE=$LOGFILE.${CURRENT_LOG_TIME}
    SUMFILE=$LOGFILE.${CURRENT_LOG_TIME}.summary

    # Redirect output according to config

    # Set fd 3 to a copy of stdout. So we can set fd 1 without losing
    # stdout later.
    exec 3>&1
    if [[ "$VERBOSE" == "True" ]]; then
        # Set fd 1 and 2 to write the log file
        exec 1> >( $TOP_DIR/tools/outfilter.py -v -o "${LOGFILE}" ) 2>&1
        # Set fd 6 to summary log file
        exec 6> >( $TOP_DIR/tools/outfilter.py -o "${SUMFILE}" )
    else
        # Set fd 1 and 2 to primary logfile
        exec 1> >( $TOP_DIR/tools/outfilter.py -o "${LOGFILE}" ) 2>&1
        # Set fd 6 to summary logfile and stdout
        exec 6> >( $TOP_DIR/tools/outfilter.py -v -o "${SUMFILE}" >&3 )
    fi

    echo_summary "stack.sh log $LOGFILE"
    # Specified logfile name always links to the most recent log
    ln -sf $LOGFILE $LOGDIR/$LOGFILENAME
    ln -sf $SUMFILE $LOGDIR/$LOGFILENAME.summary
else
    # Set up output redirection without log files
    # Set fd 3 to a copy of stdout. So we can set fd 1 without losing
    # stdout later.
    exec 3>&1
    if [[ "$VERBOSE" != "True" ]]; then
        # Throw away stdout and stderr
        exec 1>/dev/null 2>&1
    fi
    # Always send summary fd to original stdout
    exec 6> >( $TOP_DIR/tools/outfilter.py -v >&3 )
fi

# Set up logging of screen windows
# Set ``SCREEN_LOGDIR`` to turn on logging of screen windows to the
# directory specified in ``SCREEN_LOGDIR``, we will log to the the file
# ``screen-$SERVICE_NAME-$TIMESTAMP.log`` in that dir and have a link
# ``screen-$SERVICE_NAME.log`` to the latest log file.
# Logs are kept for as long specified in ``LOGDAYS``.
if [[ -n "$SCREEN_LOGDIR" ]]; then

    # We make sure the directory is created.
    if [[ -d "$SCREEN_LOGDIR" ]]; then
        # We cleanup the old logs
        find $SCREEN_LOGDIR -maxdepth 1 -name screen-\*.log -mtime +$LOGDAYS -exec rm {} \;
    else
        mkdir -p $SCREEN_LOGDIR
    fi
fi


# Configure Error Traps
# ---------------------

# Kill background processes on exit
trap exit_trap EXIT
function exit_trap {
    local r=$?
    jobs=$(jobs -p)
    # Only do the kill when we're logging through a process substitution,
    # which currently is only to verbose logfile
    if [[ -n $jobs && -n "$LOGFILE" && "$VERBOSE" == "True" ]]; then
        echo "exit_trap: cleaning up child processes"
        kill 2>&1 $jobs
    fi

    # Kill the last spinner process
    kill_spinner

    if [[ $r -ne 0 ]]; then
        echo "Error on exit"
        if [[ -z $LOGDIR ]]; then
            $TOP_DIR/tools/worlddump.py
        else
            $TOP_DIR/tools/worlddump.py -d $LOGDIR
        fi
    fi

    exit $r
}

# Exit on any errors so that errors don't compound
trap err_trap ERR
function err_trap {
    local r=$?
    set +o xtrace
    if [[ -n "$LOGFILE" ]]; then
        echo "${0##*/} failed: full log in $LOGFILE"
    else
        echo "${0##*/} failed"
    fi
    exit $r
}

# Begin trapping error exit codes
set -o errexit

# Print the commands being run so that we can see the command that triggers
# an error.  It is also useful for following along as the install occurs.
set -o xtrace


# Common Configuration
# --------------------

# Set ``OFFLINE`` to ``True`` to configure ``stack.sh`` to run cleanly without
# Internet access. ``stack.sh`` must have been previously run with Internet
# access to install prerequisites and fetch repositories.
OFFLINE=`trueorfalse False $OFFLINE`

# Set ``ERROR_ON_CLONE`` to ``True`` to configure ``stack.sh`` to exit if
# the destination git repository does not exist during the ``git_clone``
# operation.
ERROR_ON_CLONE=`trueorfalse False $ERROR_ON_CLONE`

# Whether to enable the debug log level in OpenStack services
ENABLE_DEBUG_LOG_LEVEL=`trueorfalse True $ENABLE_DEBUG_LOG_LEVEL`

# Set fixed and floating range here so we can make sure not to use addresses
# from either range when attempting to guess the IP to use for the host.
# Note that setting FIXED_RANGE may be necessary when running DevStack
# in an OpenStack cloud that uses either of these address ranges internally.
FLOATING_RANGE=${FLOATING_RANGE:-172.24.4.0/24}
FIXED_RANGE=${FIXED_RANGE:-10.0.0.0/24}
FIXED_NETWORK_SIZE=${FIXED_NETWORK_SIZE:-256}

HOST_IP=$(get_default_host_ip $FIXED_RANGE $FLOATING_RANGE "$HOST_IP_IFACE" "$HOST_IP")
if [ "$HOST_IP" == "" ]; then
    die $LINENO "Could not determine host ip address.  See local.conf for suggestions on setting HOST_IP."
fi

# Allow the use of an alternate hostname (such as localhost/127.0.0.1) for service endpoints.
SERVICE_HOST=${SERVICE_HOST:-$HOST_IP}

# Configure services to use syslog instead of writing to individual log files
SYSLOG=`trueorfalse False $SYSLOG`
SYSLOG_HOST=${SYSLOG_HOST:-$HOST_IP}
SYSLOG_PORT=${SYSLOG_PORT:-516}

# Use color for logging output (only available if syslog is not used)
LOG_COLOR=`trueorfalse True $LOG_COLOR`

# Reset the bundle of CA certificates
SSL_BUNDLE_FILE="$DATA_DIR/ca-bundle.pem"
rm -f $SSL_BUNDLE_FILE

# Import common services (database, message queue) configuration
source $TOP_DIR/lib/database
source $TOP_DIR/lib/rpc_backend

# Make sure we only have one rpc backend enabled,
# and the specified rpc backend is available on your platform.
check_rpc_backend

# Use native SSL for servers in SSL_ENABLED_SERVICES
USE_SSL=$(trueorfalse False $USE_SSL)

# Service to enable with SSL if USE_SSL is True
SSL_ENABLED_SERVICES="key,nova,cinder,glance,s-proxy,neutron"

if is_service_enabled tls-proxy && [ "$USE_SSL" == "True" ]; then
    die $LINENO "tls-proxy and SSL are mutually exclusive"
fi

# Configure Projects
# ==================

# Import apache functions
source $TOP_DIR/lib/apache

# Import TLS functions
source $TOP_DIR/lib/tls

# Source project function libraries
source $TOP_DIR/lib/infra
source $TOP_DIR/lib/oslo
source $TOP_DIR/lib/stackforge
source $TOP_DIR/lib/horizon
source $TOP_DIR/lib/keystone
source $TOP_DIR/lib/glance
source $TOP_DIR/lib/nova
source $TOP_DIR/lib/cinder
source $TOP_DIR/lib/swift
source $TOP_DIR/lib/ceilometer
source $TOP_DIR/lib/heat
source $TOP_DIR/lib/neutron
source $TOP_DIR/lib/ldap
source $TOP_DIR/lib/dstat

# Extras Source
# --------------

# Phase: source
if [[ -d $TOP_DIR/extras.d ]]; then
    for i in $TOP_DIR/extras.d/*.sh; do
        [[ -r $i ]] && source $i source
    done
fi

# Interactive Configuration
# -------------------------

# Do all interactive config up front before the logging spew begins

# Generic helper to configure passwords
function read_password {
    XTRACE=$(set +o | grep xtrace)
    set +o xtrace
    var=$1; msg=$2
    pw=${!var}

    if [[ -f $RC_DIR/localrc ]]; then
        localrc=$TOP_DIR/localrc
    else
        localrc=$TOP_DIR/.localrc.auto
    fi

    # If the password is not defined yet, proceed to prompt user for a password.
    if [ ! $pw ]; then
        # If there is no localrc file, create one
        if [ ! -e $localrc ]; then
            touch $localrc
        fi

        # Presumably if we got this far it can only be that our localrc is missing
        # the required password.  Prompt user for a password and write to localrc.
        echo ''
        echo '################################################################################'
        echo $msg
        echo '################################################################################'
        echo "This value will be written to your localrc file so you don't have to enter it "
        echo "again.  Use only alphanumeric characters."
        echo "If you leave this blank, a random default value will be used."
        pw=" "
        while true; do
            echo "Enter a password now:"
            read -e $var
            pw=${!var}
            [[ "$pw" = "`echo $pw | tr -cd [:alnum:]`" ]] && break
            echo "Invalid chars in password.  Try again:"
        done
        if [ ! $pw ]; then
            pw=$(generate_hex_string 10)
        fi
        eval "$var=$pw"
        echo "$var=$pw" >> $localrc
    fi
    $XTRACE
}


# Database Configuration

# To select between database backends, add the following to ``localrc``:
#
#    disable_service mysql
#    enable_service postgresql
#
# The available database backends are listed in ``DATABASE_BACKENDS`` after
# ``lib/database`` is sourced. ``mysql`` is the default.

initialize_database_backends && echo "Using $DATABASE_TYPE database backend" || echo "No database enabled"


# Queue Configuration

# Rabbit connection info
# In multi node devstack, second node needs RABBIT_USERID, but rabbit
# isn't enabled.
RABBIT_USERID=${RABBIT_USERID:-stackrabbit}
if is_service_enabled rabbit; then
    RABBIT_HOST=${RABBIT_HOST:-$SERVICE_HOST}
    read_password RABBIT_PASSWORD "ENTER A PASSWORD TO USE FOR RABBIT."
fi


# Keystone

if is_service_enabled key; then
    # The ``SERVICE_TOKEN`` is used to bootstrap the Keystone database.  It is
    # just a string and is not a 'real' Keystone token.
    read_password SERVICE_TOKEN "ENTER A SERVICE_TOKEN TO USE FOR THE SERVICE ADMIN TOKEN."
    # Services authenticate to Identity with servicename/``SERVICE_PASSWORD``
    read_password SERVICE_PASSWORD "ENTER A SERVICE_PASSWORD TO USE FOR THE SERVICE AUTHENTICATION."
    # Horizon currently truncates usernames and passwords at 20 characters
    read_password ADMIN_PASSWORD "ENTER A PASSWORD TO USE FOR HORIZON AND KEYSTONE (20 CHARS OR LESS)."

    # Keystone can now optionally install OpenLDAP by enabling the ``ldap``
    # service in ``localrc`` (e.g. ``enable_service ldap``).
    # To clean out the Keystone contents in OpenLDAP set ``KEYSTONE_CLEAR_LDAP``
    # to ``yes`` (e.g. ``KEYSTONE_CLEAR_LDAP=yes``) in ``localrc``.  To enable the
    # Keystone Identity Driver (``keystone.identity.backends.ldap.Identity``)
    # set ``KEYSTONE_IDENTITY_BACKEND`` to ``ldap`` (e.g.
    # ``KEYSTONE_IDENTITY_BACKEND=ldap``) in ``localrc``.

    # only request ldap password if the service is enabled
    if is_service_enabled ldap; then
        read_password LDAP_PASSWORD "ENTER A PASSWORD TO USE FOR LDAP"
    fi
fi


# Swift

if is_service_enabled s-proxy; then
    # We only ask for Swift Hash if we have enabled swift service.
    # ``SWIFT_HASH`` is a random unique string for a swift cluster that
    # can never change.
    read_password SWIFT_HASH "ENTER A RANDOM SWIFT HASH."

    if [[ -z "$SWIFT_TEMPURL_KEY" ]] && [[ "$SWIFT_ENABLE_TEMPURLS" == "True" ]]; then
        read_password SWIFT_TEMPURL_KEY "ENTER A KEY FOR SWIFT TEMPURLS."
    fi
fi


# Install Packages
# ================

# OpenStack uses a fair number of other projects.

# Install package requirements
# Source it so the entire environment is available
echo_summary "Installing package prerequisites"
source $TOP_DIR/tools/install_prereqs.sh

# Configure an appropriate python environment
if [[ "$OFFLINE" != "True" ]]; then
    PYPI_ALTERNATIVE_URL=$PYPI_ALTERNATIVE_URL $TOP_DIR/tools/install_pip.sh
fi

# Do the ugly hacks for broken packages and distros
source $TOP_DIR/tools/fixup_stuff.sh


# Extras Pre-install
# ------------------

# Phase: pre-install
if [[ -d $TOP_DIR/extras.d ]]; then
    for i in $TOP_DIR/extras.d/*.sh; do
        [[ -r $i ]] && source $i stack pre-install
    done
fi


install_rpc_backend

if is_service_enabled $DATABASE_BACKENDS; then
    install_database
fi

if is_service_enabled neutron; then
    install_neutron_agent_packages
fi

TRACK_DEPENDS=${TRACK_DEPENDS:-False}

# Install python packages into a virtualenv so that we can track them
if [[ $TRACK_DEPENDS = True ]]; then
    echo_summary "Installing Python packages into a virtualenv $DEST/.venv"
    pip_install -U virtualenv

    rm -rf $DEST/.venv
    virtualenv --system-site-packages $DEST/.venv
    source $DEST/.venv/bin/activate
    $DEST/.venv/bin/pip freeze > $DEST/requires-pre-pip
fi

# Check Out and Install Source
# ----------------------------

echo_summary "Installing OpenStack project source"

# Install required infra support libraries
install_infra

# Install oslo libraries that have graduated
install_oslo

# Install stackforge libraries for testing
if is_service_enabled stackforge_libs; then
    install_stackforge
fi

# Install clients libraries
install_keystoneclient
install_glanceclient
install_cinderclient
install_novaclient
if is_service_enabled swift glance horizon; then
    install_swiftclient
fi
if is_service_enabled neutron nova horizon; then
    install_neutronclient
fi
if is_service_enabled heat horizon; then
    install_heatclient
fi

# Install middleware
install_keystonemiddleware

# install the OpenStack client, needed for most setup commands
if use_library_from_git "python-openstackclient"; then
    git_clone_by_name "python-openstackclient"
    setup_dev_lib "python-openstackclient"
else
    pip_install 'python-openstackclient>=1.0.0'
fi


if is_service_enabled key; then
    if [ "$KEYSTONE_AUTH_HOST" == "$SERVICE_HOST" ]; then
        install_keystone
        configure_keystone
    fi
fi

if is_service_enabled s-proxy; then
    install_swift
    configure_swift

    # swift3 middleware to provide S3 emulation to Swift
    if is_service_enabled swift3; then
        # replace the nova-objectstore port by the swift port
        S3_SERVICE_PORT=8080
        git_clone $SWIFT3_REPO $SWIFT3_DIR $SWIFT3_BRANCH
        setup_develop $SWIFT3_DIR
    fi
fi

if is_service_enabled g-api n-api; then
    # image catalog service
    install_glance
    configure_glance
fi

if is_service_enabled cinder; then
    install_cinder
    configure_cinder
fi

if is_service_enabled neutron; then
    install_neutron
    install_neutron_third_party
fi

if is_service_enabled nova; then
    # compute service
    install_nova
    cleanup_nova
    configure_nova
fi

if is_service_enabled horizon; then
    # django openstack_auth
    install_django_openstack_auth
    # dashboard
    install_horizon
    configure_horizon
fi

if is_service_enabled ceilometer; then
    install_ceilometerclient
    install_ceilometer
    echo_summary "Configuring Ceilometer"
    configure_ceilometer
fi

if is_service_enabled heat; then
    install_heat
    install_heat_other
    cleanup_heat
    configure_heat
fi

if is_service_enabled tls-proxy || [ "$USE_SSL" == "True" ]; then
    configure_CA
    init_CA
    init_cert
    # Add name to /etc/hosts
    # don't be naive and add to existing line!
fi


# Extras Install
# --------------

# Phase: install
if [[ -d $TOP_DIR/extras.d ]]; then
    for i in $TOP_DIR/extras.d/*.sh; do
        [[ -r $i ]] && source $i stack install
    done
fi

if [[ $TRACK_DEPENDS = True ]]; then
    $DEST/.venv/bin/pip freeze > $DEST/requires-post-pip
    if ! diff -Nru $DEST/requires-pre-pip $DEST/requires-post-pip > $DEST/requires.diff; then
        echo "Detect some changes for installed packages of pip, in depend tracking mode"
        cat $DEST/requires.diff
    fi
    echo "Ran stack.sh in depend tracking mode, bailing out now"
    exit 0
fi


# Syslog
# ------

if [[ $SYSLOG != "False" ]]; then
    if [[ "$SYSLOG_HOST" = "$HOST_IP" ]]; then
        # Configure the master host to receive
        cat <<EOF >/tmp/90-stack-m.conf
\$ModLoad imrelp
\$InputRELPServerRun $SYSLOG_PORT
EOF
        sudo mv /tmp/90-stack-m.conf /etc/rsyslog.d
    else
        # Set rsyslog to send to remote host
        cat <<EOF >/tmp/90-stack-s.conf
*.*		:omrelp:$SYSLOG_HOST:$SYSLOG_PORT
EOF
        sudo mv /tmp/90-stack-s.conf /etc/rsyslog.d
    fi

    RSYSLOGCONF="/etc/rsyslog.conf"
    if [ -f $RSYSLOGCONF ]; then
        sudo cp -b $RSYSLOGCONF $RSYSLOGCONF.bak
        if [[ $(grep '$SystemLogRateLimitBurst' $RSYSLOGCONF)  ]]; then
            sudo sed -i 's/$SystemLogRateLimitBurst\ .*/$SystemLogRateLimitBurst\ 0/' $RSYSLOGCONF
        else
            sudo sed -i '$ i $SystemLogRateLimitBurst\ 0' $RSYSLOGCONF
        fi
        if [[ $(grep '$SystemLogRateLimitInterval' $RSYSLOGCONF)  ]]; then
            sudo sed -i 's/$SystemLogRateLimitInterval\ .*/$SystemLogRateLimitInterval\ 0/' $RSYSLOGCONF
        else
            sudo sed -i '$ i $SystemLogRateLimitInterval\ 0' $RSYSLOGCONF
        fi
    fi

    echo_summary "Starting rsyslog"
    restart_service rsyslog
fi


# Finalize queue installation
# ----------------------------
restart_rpc_backend


# Export Certicate Authority Bundle
# ---------------------------------

# If certificates were used and written to the SSL bundle file then these
# should be exported so clients can validate their connections.

if [ -f $SSL_BUNDLE_FILE ]; then
    export OS_CACERT=$SSL_BUNDLE_FILE
fi


# Configure database
# ------------------

if is_service_enabled $DATABASE_BACKENDS; then
    configure_database
fi


# Configure screen
# ----------------

USE_SCREEN=$(trueorfalse True $USE_SCREEN)
if [[ "$USE_SCREEN" == "True" ]]; then
    # Create a new named screen to run processes in
    screen -d -m -S $SCREEN_NAME -t shell -s /bin/bash
    sleep 1

    # Set a reasonable status bar
    if [ -z "$SCREEN_HARDSTATUS" ]; then
        SCREEN_HARDSTATUS='%{= .} %-Lw%{= .}%> %n%f %t*%{= .}%+Lw%< %-=%{g}(%{d}%H/%l%{g})'
    fi
    screen -r $SCREEN_NAME -X hardstatus alwayslastline "$SCREEN_HARDSTATUS"
    screen -r $SCREEN_NAME -X setenv PROMPT_COMMAND /bin/true
fi

# Clear screen rc file
SCREENRC=$TOP_DIR/$SCREEN_NAME-screenrc
if [[ -e $SCREENRC ]]; then
    rm -f $SCREENRC
fi

# Initialize the directory for service status check
init_service_check

# Dstat
# -------

# A better kind of sysstat, with the top process per time slice
start_dstat

# Start Services
# ==============

# Keystone
# --------

if is_service_enabled key; then
    echo_summary "Starting Keystone"

    if [ "$KEYSTONE_AUTH_HOST" == "$SERVICE_HOST" ]; then
        init_keystone
        start_keystone
    fi

    # Set up a temporary admin URI for Keystone
    SERVICE_ENDPOINT=$KEYSTONE_AUTH_URI/v2.0

    if is_service_enabled tls-proxy; then
        export OS_CACERT=$INT_CA_DIR/ca-chain.pem
        # Until the client support is fixed, just use the internal endpoint
        SERVICE_ENDPOINT=http://$KEYSTONE_AUTH_HOST:$KEYSTONE_AUTH_PORT_INT/v2.0
    fi

    # Setup OpenStackclient token-flow auth
    export OS_TOKEN=$SERVICE_TOKEN
    export OS_URL=$SERVICE_ENDPOINT

    create_keystone_accounts
    create_nova_accounts
    create_glance_accounts
    create_cinder_accounts
    create_neutron_accounts

    if is_service_enabled ceilometer; then
        create_ceilometer_accounts
    fi

    if is_service_enabled swift; then
        create_swift_accounts
    fi

    if is_service_enabled heat && [[ "$HEAT_STANDALONE" != "True" ]]; then
        create_heat_accounts
    fi

    # Begone token-flow auth
    unset OS_TOKEN OS_URL

    # Set up password-flow auth creds now that keystone is bootstrapped
    export OS_AUTH_URL=$SERVICE_ENDPOINT
    export OS_TENANT_NAME=admin
    export OS_USERNAME=admin
    export OS_PASSWORD=$ADMIN_PASSWORD
    export OS_REGION_NAME=$REGION_NAME
fi


# Horizon
# -------

# Set up the django horizon application to serve via apache/wsgi

if is_service_enabled horizon; then
    echo_summary "Configuring and starting Horizon"
    init_horizon
    start_horizon
fi


# Glance
# ------

if is_service_enabled g-reg; then
    echo_summary "Configuring Glance"
    init_glance
fi


# Neutron
# -------

if is_service_enabled neutron; then
    echo_summary "Configuring Neutron"

    configure_neutron
    # Run init_neutron only on the node hosting the neutron API server
    if is_service_enabled $DATABASE_BACKENDS && is_service_enabled q-svc; then
        init_neutron
    fi
fi

# Some Neutron plugins require network controllers which are not
# a part of the OpenStack project. Configure and start them.
if is_service_enabled neutron; then
    configure_neutron_third_party
    init_neutron_third_party
    start_neutron_third_party
fi


# Nova
# ----

if is_service_enabled n-net q-dhcp; then
    # Delete traces of nova networks from prior runs
    # Do not kill any dnsmasq instance spawned by NetworkManager
    netman_pid=$(pidof NetworkManager || true)
    if [ -z "$netman_pid" ]; then
        sudo killall dnsmasq || true
    else
        sudo ps h -o pid,ppid -C dnsmasq | grep -v $netman_pid | awk '{print $1}' | sudo xargs kill || true
    fi

    clean_iptables

    if is_service_enabled n-net; then
        rm -rf ${NOVA_STATE_PATH}/networks
        sudo mkdir -p ${NOVA_STATE_PATH}/networks
        safe_chown -R ${STACK_USER} ${NOVA_STATE_PATH}/networks
    fi

    # Force IP forwarding on, just in case
    sudo sysctl -w net.ipv4.ip_forward=1
fi


# Storage Service
# ---------------

if is_service_enabled s-proxy; then
    echo_summary "Configuring Swift"
    init_swift
fi


# Volume Service
# --------------

if is_service_enabled cinder; then
    echo_summary "Configuring Cinder"
    init_cinder
fi


# Compute Service
# ---------------

if is_service_enabled nova; then
    echo_summary "Configuring Nova"
    init_nova

    # Additional Nova configuration that is dependent on other services
    if is_service_enabled neutron; then
        create_nova_conf_neutron
    elif is_service_enabled n-net; then
        create_nova_conf_nova_network
    fi

    init_nova_cells
fi

# Extras Configuration
# ====================

# Phase: post-config
if [[ -d $TOP_DIR/extras.d ]]; then
    for i in $TOP_DIR/extras.d/*.sh; do
        [[ -r $i ]] && source $i stack post-config
    done
fi


# Local Configuration
# ===================

# Apply configuration from local.conf if it exists for layer 2 services
# Phase: post-config
merge_config_group $TOP_DIR/local.conf post-config


# Launch Services
# ===============

# Only run the services specified in ``ENABLED_SERVICES``

# Launch Swift Services
if is_service_enabled s-proxy; then
    echo_summary "Starting Swift"
    start_swift
fi

# Launch the Glance services
if is_service_enabled glance; then
    echo_summary "Starting Glance"
    start_glance
fi

# Install Images
# ==============

# Upload an image to glance.
#
# The default image is cirros, a small testing image which lets you login as **root**
# cirros has a ``cloud-init`` analog supporting login via keypair and sending
# scripts as userdata.
# See https://help.ubuntu.com/community/CloudInit for more on cloud-init
#
# Override ``IMAGE_URLS`` with a comma-separated list of UEC images.
#  * **precise**: http://uec-images.ubuntu.com/precise/current/precise-server-cloudimg-amd64.tar.gz

if is_service_enabled g-reg; then
    TOKEN=$(keystone token-get | grep ' id ' | get_field 2)
    die_if_not_set $LINENO TOKEN "Keystone fail to get token"

    echo_summary "Uploading images"

    # Option to upload legacy ami-tty, which works with xenserver
    if [[ -n "$UPLOAD_LEGACY_TTY" ]]; then
        IMAGE_URLS="${IMAGE_URLS:+${IMAGE_URLS},}https://github.com/downloads/citrix-openstack/warehouse/tty.tgz"
    fi

    for image_url in ${IMAGE_URLS//,/ }; do
        upload_image $image_url $TOKEN
    done
fi

# Create an access key and secret key for nova ec2 register image
if is_service_enabled key && is_service_enabled swift3 && is_service_enabled nova; then
    eval $(openstack ec2 credentials create --user nova --project $SERVICE_TENANT_NAME -f shell -c access -c secret)
    iniset $NOVA_CONF DEFAULT s3_access_key "$access"
    iniset $NOVA_CONF DEFAULT s3_secret_key "$secret"
    iniset $NOVA_CONF DEFAULT s3_affix_tenant "True"
fi

# Create a randomized default value for the keymgr's fixed_key
if is_service_enabled nova; then
    iniset $NOVA_CONF keymgr fixed_key $(generate_hex_string 32)
fi

if is_service_enabled zeromq; then
    echo_summary "Starting zermomq receiver"
    run_process zeromq "$OSLO_BIN_DIR/oslo-messaging-zmq-receiver"
fi

# Launch the nova-api and wait for it to answer before continuing
if is_service_enabled n-api; then
    echo_summary "Starting Nova API"
    start_nova_api
fi

if is_service_enabled q-svc; then
    echo_summary "Starting Neutron"
    start_neutron_service_and_check
    check_neutron_third_party_integration
elif is_service_enabled $DATABASE_BACKENDS && is_service_enabled n-net; then
    NM_CONF=${NOVA_CONF}
    if is_service_enabled n-cell; then
        NM_CONF=${NOVA_CELLS_CONF}
    fi

    # Create a small network
    $NOVA_BIN_DIR/nova-manage --config-file $NM_CONF network create "$PRIVATE_NETWORK_NAME" $FIXED_RANGE 1 $FIXED_NETWORK_SIZE $NETWORK_CREATE_ARGS

    # Create some floating ips
    $NOVA_BIN_DIR/nova-manage --config-file $NM_CONF floating create $FLOATING_RANGE --pool=$PUBLIC_NETWORK_NAME

    # Create a second pool
    $NOVA_BIN_DIR/nova-manage --config-file $NM_CONF floating create --ip_range=$TEST_FLOATING_RANGE --pool=$TEST_FLOATING_POOL
fi

if is_service_enabled neutron; then
    start_neutron_agents
fi
# Once neutron agents are started setup initial network elements
if is_service_enabled q-svc && [[ "$NEUTRON_CREATE_INITIAL_NETWORKS" == "True" ]]; then
    echo_summary "Creating initial neutron network elements"
    create_neutron_initial_network
    setup_neutron_debug
fi
if is_service_enabled nova; then
    echo_summary "Starting Nova"
    start_nova
fi
if is_service_enabled cinder; then
    echo_summary "Starting Cinder"
    start_cinder
    create_volume_types
fi
if is_service_enabled ceilometer; then
    echo_summary "Starting Ceilometer"
    init_ceilometer
    start_ceilometer
fi

# Configure and launch heat engine, api and metadata
if is_service_enabled heat; then
    # Initialize heat
    echo_summary "Configuring Heat"
    init_heat
    echo_summary "Starting Heat"
    start_heat
    if [ "$HEAT_CREATE_TEST_IMAGE" = "True" ]; then
        echo_summary "Building Heat functional test image"
        build_heat_functional_test_image
    fi
fi


# Create account rc files
# =======================

# Creates source able script files for easier user switching.
# This step also creates certificates for tenants and users,
# which is helpful in image bundle steps.

if is_service_enabled nova && is_service_enabled key; then
    USERRC_PARAMS="-PA --target-dir $TOP_DIR/accrc"

    if [ -f $SSL_BUNDLE_FILE ]; then
        USERRC_PARAMS="$USERRC_PARAMS --os-cacert $SSL_BUNDLE_FILE"
    fi

    if [[ "$HEAT_STANDALONE" = "True" ]]; then
        USERRC_PARAMS="$USERRC_PARAMS --heat-url http://$HEAT_API_HOST:$HEAT_API_PORT/v1"
    fi

    $TOP_DIR/tools/create_userrc.sh $USERRC_PARAMS
fi


# Save some values we generated for later use
CURRENT_RUN_TIME=$(date "+$TIMESTAMP_FORMAT")
echo "# $CURRENT_RUN_TIME" >$TOP_DIR/.stackenv
for i in BASE_SQL_CONN ENABLED_SERVICES HOST_IP LOGFILE \
    SERVICE_HOST SERVICE_PROTOCOL STACK_USER TLS_IP KEYSTONE_AUTH_PROTOCOL OS_CACERT; do
    echo $i=${!i} >>$TOP_DIR/.stackenv
done


# Local Configuration
# ===================

# Apply configuration from local.conf if it exists for layer 2 services
# Phase: extra
merge_config_group $TOP_DIR/local.conf extra


# Run extras
# ==========

# Phase: extra
if [[ -d $TOP_DIR/extras.d ]]; then
    for i in $TOP_DIR/extras.d/*.sh; do
        [[ -r $i ]] && source $i stack extra
    done
fi

# Local Configuration
# ===================

# Apply configuration from local.conf if it exists for layer 2 services
# Phase: post-extra
merge_config_group $TOP_DIR/local.conf post-extra


# Run local script
# ================

# Run ``local.sh`` if it exists to perform user-managed tasks
if [[ -x $TOP_DIR/local.sh ]]; then
    echo "Running user script $TOP_DIR/local.sh"
    $TOP_DIR/local.sh
fi

# Check the status of running services
service_check


# Fin
# ===

set +o xtrace

if [[ -n "$LOGFILE" ]]; then
    exec 1>&3
    # Force all output to stdout and logs now
    exec 1> >( tee -a "${LOGFILE}" ) 2>&1
else
    # Force all output to stdout now
    exec 1>&3
fi


# Using the cloud
# ---------------

echo ""
echo ""
echo ""

# If you installed Horizon on this server you should be able
# to access the site using your browser.
if is_service_enabled horizon; then
    echo "Horizon is now available at http://$SERVICE_HOST/"
fi

# If Keystone is present you can point ``nova`` cli to this server
if is_service_enabled key; then
    echo "Keystone is serving at $KEYSTONE_SERVICE_URI/v2.0/"
    echo "Examples on using novaclient command line is in exercise.sh"
    echo "The default users are: admin and demo"
    echo "The password: $ADMIN_PASSWORD"
fi

# Echo ``HOST_IP`` - useful for ``build_uec.sh``, which uses dhcp to give the instance an address
echo "This is your host ip: $HOST_IP"

# Warn that a deprecated feature was used
if [[ -n "$DEPRECATED_TEXT" ]]; then
    echo_summary "WARNING: $DEPRECATED_TEXT"
fi

if is_service_enabled neutron; then
    # TODO(dtroyer): Remove Q_AGENT_EXTRA_AGENT_OPTS after stable/juno branch is cut
    if [[ -n "$Q_AGENT_EXTRA_AGENT_OPTS" ]]; then
        echo ""
        echo_summary "WARNING: Q_AGENT_EXTRA_AGENT_OPTS is used"
        echo "You are using Q_AGENT_EXTRA_AGENT_OPTS to pass configuration into $NEUTRON_CONF."
        echo "Please convert that configuration in localrc to a $NEUTRON_CONF section in local.conf:"
        echo "Q_AGENT_EXTRA_AGENT_OPTS will be removed early in the 'K' development cycle"
        echo "
[[post-config|/\$Q_PLUGIN_CONF_FILE]]
[DEFAULT]
"
        for I in "${Q_AGENT_EXTRA_AGENT_OPTS[@]}"; do
            # Replace the first '=' with ' ' for iniset syntax
            echo ${I}
        done
    fi

    # TODO(dtroyer): Remove Q_AGENT_EXTRA_SRV_OPTS after stable/juno branch is cut
    if [[ -n "$Q_AGENT_EXTRA_SRV_OPTS" ]]; then
        echo ""
        echo_summary "WARNING: Q_AGENT_EXTRA_SRV_OPTS is used"
        echo "You are using Q_AGENT_EXTRA_SRV_OPTS to pass configuration into $NEUTRON_CONF."
        echo "Please convert that configuration in localrc to a $NEUTRON_CONF section in local.conf:"
        echo "Q_AGENT_EXTRA_AGENT_OPTS will be removed early in the 'K' development cycle"
        echo "
[[post-config|/\$Q_PLUGIN_CONF_FILE]]
[DEFAULT]
"
        for I in "${Q_AGENT_EXTRA_SRV_OPTS[@]}"; do
            # Replace the first '=' with ' ' for iniset syntax
            echo ${I}
        done
    fi
fi

if is_service_enabled cinder; then
    # TODO(dtroyer): Remove CINDER_MULTI_LVM_BACKEND after stable/juno branch is cut
    if [[ "$CINDER_MULTI_LVM_BACKEND" = "True" ]]; then
        echo ""
        echo_summary "WARNING: CINDER_MULTI_LVM_BACKEND is used"
        echo "You are using CINDER_MULTI_LVM_BACKEND to configure Cinder's multiple LVM backends"
        echo "Please convert that configuration in local.conf to use CINDER_ENABLED_BACKENDS."
        echo "CINDER_MULTI_LVM_BACKEND will be removed early in the 'K' development cycle"
        echo "
[[local|localrc]]
CINDER_ENABLED_BACKENDS=lvm:lvmdriver-1,lvm:lvmdriver-2
"
    fi
fi

# Indicate how long this took to run (bash maintained variable ``SECONDS``)
echo_summary "stack.sh completed in $SECONDS seconds."

# Restore/close logging file descriptors
exec 1>&3
exec 2>&3
exec 3>&-
exec 6>&-
