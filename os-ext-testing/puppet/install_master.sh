#! /usr/bin/env bash

# Sets up a master Jenkins server and associated machinery like
# Zuul, JJB, Gearman, etc.

set -e

THIS_DIR=`pwd`

DATA_REPO_INFO_FILE=$THIS_DIR/.data_repo_info
DATA_PATH=$THIS_DIR/data
OSEXT_PATH=$THIS_DIR/os-ext-testing
OSEXT_REPO=https://github.com/jaypipes/os-ext-testing
CONFIG_MODULES=$THIS_DIR/config/modules
PUPPET_MODULE_PATH="--modulepath=$OSEXT_PATH/puppet/modules:$CONFIG_MODULES:/etc/puppet/modules"

sudo apt-get install wget openssl ssl-cert ca-certificates

# Install Puppet and the OpenStack Infra Config source tree
sudo bash -xe install_puppet.sh
sudo install_modules.sh

# Pulling in variables from data repository
. $DATA_PATH/vars.sh

# Validate that the upstream gerrit user and key are present in the data
# repository
if [[ -z $UPSTREAM_GERRIT_USER ]]; then
    echo "Expected to find UPSTREAM_GERRIT_USER in $DATA_PATH/vars.sh. Please correct. Exiting."
    exit 1
else
    echo "Using upstream Gerrit user: $UPSTREAM_GERRIT_USER"
fi

if [[ ! -e "$DATA_PATH/$UPSTREAM_GERRIT_SSH_KEY_PATH" ]]; then
    echo "Expected to find $UPSTREAM_GERRIT_SSH_KEY_PATH in $DATA_PATH. Please correct. Exiting."
    exit 1
fi
export UPSTREAM_GERRIT_SSH_PRIVATE_KEY_CONTENTS=`cat "$DATA_PATH/$UPSTREAM_GERRIT_SSH_KEY_PATH"`

# Validate there is a Jenkins SSH key pair in the data repository
if [[ -z $JENKINS_SSH_KEY_PATH ]]; then
    echo "Expected to find JENKINS_SSH_KEY_PATH in $DATA_PATH/vars.sh. Please correct. Exiting."
    exit 1
elif [[ ! -e "$DATA_PATH/$JENKINS_SSH_KEY_PATH" ]]; then
    echo "Expected to find Jenkins SSH key pair at $DATA_PATH/$JENKINS_SSH_KEY_PATH, but wasn't found. Please correct. Exiting."
    exit 1
else
    echo "Using Jenkins SSH key path: $DATA_PATH/$JENKINS_SSH_KEY_PATH"
    JENKINS_SSH_PRIVATE_KEY_CONTENTS=`sudo cat $DATA_PATH/$JENKINS_SSH_KEY_PATH`
    JENKINS_SSH_PUBLIC_KEY_CONTENTS=`sudo cat $DATA_PATH/$JENKINS_SSH_KEY_PATH.pub`
fi

PUBLISH_HOST=${PUBLISH_HOST:-localhost}

# Create a self-signed SSL certificate for use in Apache
APACHE_SSL_ROOT_DIR=$THIS_DIR/tmp/apache/ssl
if [[ ! -e $APACHE_SSL_ROOT_DIR/new.ssl.csr ]]; then
    echo "Creating self-signed SSL certificate for Apache"
    mkdir -p $APACHE_SSL_ROOT_DIR
    cd $APACHE_SSL_ROOT_DIR
    echo '
[ req ]
default_bits            = 2048
default_keyfile         = new.key.pem
default_md              = default
prompt                  = no
distinguished_name      = distinguished_name

[ distinguished_name ]
countryName             = US
stateOrProvinceName     = CA
localityName            = Sunnyvale
organizationName        = OpenStack
organizationalUnitName  = OpenStack
commonName              = localhost
emailAddress            = openstack@openstack.org
' > ssl_req.conf
    # Create the certificate signing request
    openssl req -new -config ssl_req.conf -nodes > new.ssl.csr
    # Generate the certificate from the CSR
    openssl rsa -in new.key.pem -out new.cert.key
    openssl x509 -in new.ssl.csr -out new.cert.cert -req -signkey new.cert.key -days 3650
    cd $THIS_DIR
fi
APACHE_SSL_CERT_FILE=`cat $APACHE_SSL_ROOT_DIR/new.cert.cert`
APACHE_SSL_KEY_FILE=`cat $APACHE_SSL_ROOT_DIR/new.cert.key`

CLASS_ARGS="jenkins_ssh_public_key => '$JENKINS_SSH_PUBLIC_KEY_CONTENTS', jenkins_ssh_private_key => '$JENKINS_SSH_PRIVATE_KEY_CONTENTS', "
CLASS_ARGS="$CLASS_ARGS ssl_cert_file_contents => '$APACHE_SSL_CERT_FILE', ssl_key_file_contents => '$APACHE_SSL_KEY_FILE', "
CLASS_ARGS="$CLASS_ARGS upstream_gerrit_user => '$UPSTREAM_GERRIT_USER', "
CLASS_ARGS="$CLASS_ARGS upstream_gerrit_ssh_private_key => '$UPSTREAM_GERRIT_SSH_PRIVATE_KEY_CONTENTS', "
CLASS_ARGS="$CLASS_ARGS upstream_gerrit_host_pub_key => '$UPSTREAM_GERRIT_HOST_PUB_KEY', "
CLASS_ARGS="$CLASS_ARGS git_email => '$GIT_EMAIL', git_name => '$GIT_NAME', "
CLASS_ARGS="$CLASS_ARGS publish_host => '$PUBLISH_HOST', "
CLASS_ARGS="$CLASS_ARGS jenkins_url => '$JENKINS_URL', "
CLASS_ARGS="$CLASS_ARGS data_repo_dir => '$DATA_PATH', "

# Doing this here because ran into one problem after another trying
# to do this in Puppet... which won't let me execute Ruby code in
# a manifest and doesn't allow you to "merge" the contents of two
# directory sources in the file resource. :(
sudo mkdir -p /etc/jenkins_jobs/config
sudo cp -r $DATA_PATH/etc/jenkins_jobs/config/* /etc/jenkins_jobs/config/

sudo puppet apply --verbose $PUPPET_MODULE_PATH -e "class {'os_ext_testing::master': $CLASS_ARGS }"
