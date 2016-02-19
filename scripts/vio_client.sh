#!/bin/bash
# alias.sh

#This script is aimed at automating Vmware Integrated Openstack system testing via Rally (http://rally.readthedocs.org/en/latest/). You can use it where Rally is installed but it's highly recommended to execute it in Rally docker image(http://rally.readthedocs.org/en/latest/install.html#rally-docker) 
#Author : Chandler Zhang (chengz@vmware.com)

shopt -s expand_aliases

alias nova="nova --insecure"
alias neutron="neutron --insecure"
alias heat="heat --insecure"
alias glance="glance --insecure"
alias cinder="cinder --insecure"
alias ceilometer="ceilometer --os-insecure true"

# Rally configurations
RALLY_FILE_REPO=~/.rally
RALLY_DEPLOY_FILE=$RALLY_FILE_REPO/rally_deploy.json
RALLY_LOG_DIR=$RALLY_FILE_REPO/logs
RALLY_CONF_FILE=$RALLY_FILE_REPO/rally.conf
RALLY_TASK_DIR=$RALLY_FILE_REPO/tasks
RALLY_HOT_DIR=$RALLY_FILE_REPO/hots
RALLY_PLUGIN_DIR=$RALLY_FILE_REPO/plugins
RALLY_USER_FILE=$RALLY_FILE_REPO/users.txt
RALLY_DEPLOY_NAME=vio

cyan='\E[36;40m'
green='\E[32;40m'
red='\E[31;40m'
yellow='\E[33;40m'

cecho() {
  local default_msg="No message passed."
  message=${1:-$default_msg}
  color=${2:-$green}
  echo -ne "$color$message"
  tput sgr0
  echo ""
  return
}

parse_yaml() {
   local prefix=$2
   local suffix=$3
   local s='[[:space:]]*' w='[a-zA-Z0-9_]*' fs=$(echo @|tr @ '\034')
   sed -ne "s|^\($s\):|\1|" \
        -e "s|^\($s\)\($w\)$s:$s[\"']\(.*\)[\"']$s\$|\1$fs\2$fs\3|p" \
        -e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p"  $1 |
   awk -F$fs '{
      indent = length($1)/2;
      vname[indent] = $2;
      for (i in vname) {if (i > indent) {delete vname[i]}}
      if (length($3) > 0) {
         vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])(":")}
         if (match(vn, "^'$prefix':") && match($2,"'$suffix'$")) {
           gsub(/[ \t]+$/, "", $3);
           printf("%s%s=%s\n", vn, $2, $3);
         }
      }
   }'
}

rally_hot_nested_templates() {
  local top_yaml=$1
  local pth=`dirname $top_yaml`
  local file=`basename $top_yaml`
  for ny in `parse_yaml $top_yaml resources type | awk -F= '{if(match($2,".yaml$")) print $2}'`
  do
    echo $ny $pth"/"$ny
    rally_hot_nested_templates $pth"/"$ny
  done
}

rally_hot_parameters() {
  local top_yaml=$1
  local prefix=$2
  parse_yaml $top_yaml parameters "type|default" | awk 'BEGIN {FS="[:=]";type;default;name} {if($2==name){if($3=="type"){if($4=="number"){printf("%s\"%s\": %s,\n","'$prefix'",$2,default);}else{printf("%s\"%s\": \"%s\",\n","'$prefix'",$2,default);}}else{if(type=="number"){printf("%s\"%s\": %s,\n","'$prefix'",$2,$4);}else{printf("%s\"%s\": \"%s\",\n","'$prefix'",$2,$4);}}type="";default=""}else{name=$2;if(type=="number"){printf("%s\"%s\": 0,\n","'$prefix'",name);}else if(type!=""){printf("%s\"%s\": \"\",\n","'$prefix'",name);}if($3=="type"){type=$4}else{default=$4}}} END{if(type=="number"){printf("%s\"%s\": 0\n","'$prefix'",name);}else if(type!=""){printf("%s\"%s\": \"\"\n","'$prefix'",name);}}'
}

env_file() {
  local env=~/.vio_client.conf
  mkdir -p $RALLY_FILE_REPO
  if [ ! -f $env ]
  then
    local auth="http://<internal_vip>:5000/v2.0/"
    if [ ! -z $OS_AUTH_URL ]
    then
      auth=$OS_AUTH_URL
    fi
    local user="admin"
    if [ ! -z $OS_USERNAME ]
    then
      user=$OS_USERNAME
    fi
    local password=""
    if [ ! -z $OS_PASSWORD ]
    then
      password=$OS_PASSWORD
    fi
    cat >$env <<EOF
# Openstack client environment parameters
export OS_AUTH_URL=$auth
export OS_USERNAME=$user
export OS_PASSWORD=$password
export OS_TENANT_NAME=admin
export OS_REGION_NAME=nova

# Openstack data population configurations
EXTERNAL_NETWORK=flat
KEYPAIR=vioKey

# Change message background colors (uncomment four below for white background)
#cyan='\033[36m'
#green='\033[32m'
#red='\033[31m'
#yellow='\033[33m'
EOF
  cecho "It might be the first time to execute the script in the environment. Configuration file $env is generated and please enter approperiate values inside it before next run." $cyan
  exit 0
  else
    source $env 
  fi
}

rally_generate_user_file() {
  local description="generate rally user file which contains tenant and user information"
  local tenant_count="2"
  local tenant_prefix="vio_tenant"
  local user_per_tenant="2"
  local user_password="vmware"
  while [[ $# > 0 ]]
  do
    key="$1"
    case $key in
      -h|--help)
      cecho "$description" $cyan
      if [[ "-usage_hidden" != $2 ]]
      then
        cecho "usage: $0 ${FUNCNAME} [-c tenant_count(default $tenant_count)][-t tenant_prefix(default $tenant_prefix)][-u user_per_tenant(default $user_per_tenant)][-p user_password(default $user_password)]" $yellow
      fi
      exit 0
      ;;
      -c|--tenant_count)
      tenant_count="$2"
      shift
      ;;
      -t|--tenant_prefix)
      tenant_prefix="$2"
      shift
      ;;
      -u|--user_per_tenant)
      user_per_tenant="$2"
      shift
      ;;
      -p|--user_password)
      user_password="$2"
      shift
      ;;
      *)
    esac
    shift
  done
  if [ -f $RALLY_USER_FILE ]
  then
    cecho "$description -- skipped as $RALLY_USER_FILE already exists" $yellow
    exit 0
  fi
  echo -n "" > $RALLY_USER_FILE
  for i in `seq 1 $tenant_count`
  do  
    for j in `seq 1 $user_per_tenant`
    do
      echo "$tenant_prefix${i} $tenant_prefix${i}_user${j} $user_password admin" >> $RALLY_USER_FILE
    done
  done
}

rally_create_tenants() {
  local description="create tenants with users per $RALLY_USER_FILE"
  if [ "-h" == $1 ]
  then
    cecho "$description, add option '-u' or '--create-users' to create users as well" $cyan
    exit 0
  fi
  if [ ! -f $RALLY_USER_FILE ]
  then
    cecho "$description -- $RALLY_USER_FILE does not exist" $red
    exit 1
  fi
  cecho "$description -- starting" $cyan
  local previous_tenant=""
  while read line; do
    read -r -a array <<< "$line"
    if [[ ${#array[@]} > 2 ]]
    then
      tenant=${array[0]}
      user=${array[1]}
      password=${array[2]}
      role="_member_"
      if [[ "$tenant" != "$previous_tenant" ]]
      then
        cecho "creating tenant $tenant" $cyan 
        keystone tenant-create --name $tenant
        previous_tenant=$tenant
      fi
      if [[ "-u" == $1 ]] || [[ "--create-users" == $1 ]]
      then
        cecho "creating user $user in tenant $tenant" $cyan
        keystone user-create --name $user --pass $password --tenant $tenant
      fi
      if [[ ${#array[@]} > 3 ]]
      then
        role=${array[3]}
      fi
      cecho "adding role $role to user $user in tenant $tenant" $cyan
      keystone user-role-add --user $user --tenant $tenant --role $role
    fi
  done < $RALLY_USER_FILE
  cecho "$description -- done" $cyan
}

rally_remove_tenants() {
  local description="remove tenants with users per $RALLY_USER_FILE"
  if [ "-h" == $1 ]
  then
    cecho "$description, add option '-u' or '--remove-users' to remove users as well" $cyan
    exit 0
  fi
  if [ ! -f $RALLY_USER_FILE ]
  then
    cecho "$description -- $RALLY_USER_FILE does not exist" $red
    exit 1
  fi
  cecho "$description -- starting" $cyan
  if [[ "-u" == $1 ]] || [[ "--remove-users" == $1 ]]
  then
    for user in `awk '{if($2) print $2;}' $RALLY_USER_FILE | sort | uniq`
    do
      cecho "deleting user $user" $cyan
      keystone user-delete $user
    done
  fi
  for tenant in `awk '{if($1) print $1;}' $RALLY_USER_FILE | sort | uniq`
  do
    for sg in `neutron security-group-list --tenant-id $tenant | grep -v "name" | awk 'BEGIN {FS="|";} {if($2&&match($2,"([^ ]+)")) print $2}'`
    do
      cecho "deleting security-group '${sg}' in tenant $tenant" $cyan
      neutron security-group-delete ${sg}
    done
    cecho "deleting tenant $tenant" $cyan
    keystone tenant-delete $tenant
  done
  cecho "$description -- done" $cyan
}

rally_generate_deployment() {
  local description="generate rally deployment file '$RALLY_DEPLOY_FILE' with regard to user information in $RALLY_USER_FILE" 
  if [ "-h" == $1 ]
  then
    cecho "$description" $cyan
    exit 0
  fi
  cecho "$description -- starting" $cyan
  cat >$RALLY_DEPLOY_FILE <<EOF
{
  "type": "ExistingCloud",
  "auth_url": "$OS_AUTH_URL",
  "region_name": "$OS_REGION_NAME",
  "use_public_urls": false,
  "admin_port": 35357,
  "admin": {
    "username": "$OS_USERNAME",
    "password": "$OS_PASSWORD",
    "tenant_name": "$OS_TENANT_NAME"
  },
  "users": [
  ],
  "https_insecure": True,
  "https_cacert": "",
}
EOF
  if [ -f $RALLY_USER_FILE ]
  then
    while read line; do
      read -r -a array <<< "$line"
      if [[ ${#array[@]} > 2 ]]
      then
        tenant=${array[0]}
        user=${array[1]}
        password=${array[2]}
        sed -i '/users/ a\    {\n      "username": "'$user'",\n      "password": "'$password'",\n      "tenant_name": "'$tenant'"\n    },' $RALLY_DEPLOY_FILE
      fi
    done < $RALLY_USER_FILE
    sed -i '/    },/N;s/    },\n  ],/    }\n  ],/' $RALLY_DEPLOY_FILE 
  fi
  cecho "$description -- done" $cyan
}

rally_init() {
  local description="create rally db and rally deployment with populated rally users"
  if [ "-h" == $1 ]
  then
    cecho "$description" $cyan
    exit 0
  fi
  rally_conf_file -o
  cecho "executing :: rally-manage --config-file $RALLY_CONF_FILE db recreate" $cyan
  rally-manage --config-file $RALLY_CONF_FILE --nodebug --norally-debug db recreate 
  rally_generate_deployment
  cecho "executing :: rally --config-file $RALLY_CONF_FILE deployment create --name $RALLY_DEPLOY_NAME --filename $RALLY_DEPLOY_FILE" $cyan
  if [ -f $RALLY_FILE_REPO/openrc ]
  then
    rm -f $RALLY_FILE_REPO/openrc
  fi
  rally --config-file $RALLY_CONF_FILE deployment create --name $RALLY_DEPLOY_NAME --filename $RALLY_DEPLOY_FILE 2>/dev/null
}

create_external_network() {
  local description="create external network '$EXTERNAL_NETWORK'"
  local usage="usage: $0 ${FUNCNAME} -p dvportgroup -s ip_pool_start -e ip_pool_end -g gateway -n netmask"
  local dvportgroup=""
  local ip_pool_start=""
  local ip_pool_end=""
  local gateway=""
  local netmask=""
  while [[ $# > 0 ]]
  do
    key="$1"
    case $key in
      -h|--help)
      cecho "$description" $cyan
      if [[ "-usage_hidden" != $2 ]]
      then
        cecho "$usage" $yellow
      fi
      exit 0
      ;;
      -p|--dvportgroup)
      dvportgroup="$2"
      shift
      ;;
      -s|--ip_pool_start)
      ip_pool_start="$2"
      shift
      ;;
      -e|--ip_pool_end)
      ip_pool_end="$2"
      shift
      ;;
      -g|--gateway)
      gateway="$2"
      shift
      ;;
      -n|--netmask)
      netmask="$2"
      shift
      ;;
      *)
    esac
    shift
  done
  if [[ "$dvportgroup" == "" ]] || [[ "$ip_pool_start" == "" ]] || [[ "$ip_pool_end" == "" ]] || [[ "$gateway" == "" ]] || [[ "$netmask" == "" ]]
  then
    cecho "$usage" $yellow
    exit 0
  fi 
  cecho "$description -- starting" $cyan
  neutron net-create $EXTERNAL_NETWORK -- --provider:network_type=portgroup --provider:physical_network=$dvportgroup --router:external=True;neutron subnet-create --name $EXTERNAL_NETWORK --allocation-pool start=$ip_pool_start,end=$ip_pool_end --gateway $gateway $EXTERNAL_NETWORK $netmask -- --enable_dhcp=False 
  cecho "$description -- done" $cyan
}

remove_external_network() {
  description="remove external network '$EXTERNAL_NETWORK'"
  if [ "-h" == $1 ]
  then
    cecho "$description" $cyan
    exit 0
  fi
  cecho "$description -- starting" $cyan
  neutron subnet-delete $EXTERNAL_NETWORK
  neutron net-delete $EXTERNAL_NETWORK
  cecho "$description -- done" $cyan
} 

defcore_seeding() {
  keystone role-create --name member
  keystone tenant-create --name alt-user; keystone user-create --name alt-user --tenant alt-user --pass vmware
  keystone tenant-create --name default; keystone user-create --name default --tenant default --pass vmware
  nova flavor-create m1.ref 42 512 10 1
  nova flavor-create m2.ref 84 1024 10 2
  neutron net-create flat-private;neutron subnet-create --name flat-private flat-private 172.16.10.0/24
#  create_external_network
}

remove_tenants_users() {
  local description="remove tenants and users whose name contains specific string(the first parameter), related security groups are purged as well"
  if [[ -z $1 ]] || [[ "-h" == $1 ]]
  then
    cecho "$description" $cyan
    if [[ "-usage_hidden" != $2 ]]
    then
      cecho "usage: $0 ${FUNCNAME} string" $yellow
    fi
    exit 0
  fi
  description="remove tenants and users whose name contains string '${1}'"
  cecho "$description -- starting" $cyan
  for user in `keystone user-list | grep $1 | awk 'BEGIN {FS="|";} {print $2}'`
  do
    cecho "deleting user $user" $cyan
    keystone user-delete $user
  done
  for tenant in `keystone tenant-list | grep $1 | awk 'BEGIN {FS="|";} {print $2}'`
  do
    for sg in `neutron security-group-list --tenant-id $tenant | grep -v "name" | awk 'BEGIN {FS="|";} {if($2&&match($2,"([^ ]+)")) print $2}'`
    do
      cecho "deleting security-group '${sg}' in tenant $tenant" $cyan
      neutron security-group-delete ${sg}
    done
    cecho "deleting tenant $tenant" $cyan
    keystone tenant-delete $tenant
  done
  cecho "$description -- done" $cyan
}

defcore_remove_seeding() {
#  remove_external_network
  neutron subnet-delete flat-private
  neutron net-delete flat-private
  nova flavor-delete m1.ref
  nova flavor-delete m2.ref
  keystone user-delete default
  keystone tenant-delete default
  keystone user-delete alt-user
  keystone tenant-delete alt-user
  keystone role-delete member
  remove_tenants_users tempest
}

switch_to_user() {
  local description="Generate a plain file of environment parameters for certain user to use openstack CLI"
  local tenant=$OS_TENANT_NAME
  local username=$OS_USERNAME
  local password=$OS_PASSWORD
  while [[ $# > 0 ]]
  do
    key="$1"
    case $key in
      -h|--help)
      cecho "$description" $cyan
      if [[ "-usage_hidden" != $2 ]]
      then
        cecho "usage: $0 ${FUNCNAME} [-t tenant(default $tenant)][-u username(default $username)][-p password(default $password)]" $yellow
      fi
      exit 0
      ;;
      -t|--tenant)
      tenant="$2"
      shift
      ;;
      -u|--username)
      username="$2"
      shift
      ;;
      -p|--password)
      password="$2"
      shift
      ;;
      *)
    esac
    shift
  done
  cecho "$description -- starting" $cyan
  cat > $RALLY_FILE_REPO/openrc_tenant <<EOF
export OS_AUTH_URL=$OS_AUTH_URL
export OS_USERNAME=$username
export OS_PASSWORD=$password
export OS_TENANT_NAME=$tenant
export OS_REGION_NAME=$OS_REGION_NAME
alias nova="nova --insecure"
alias neutron="neutron --insecure"
alias heat="heat --insecure"
alias glance="glance --insecure"
alias cinder="cinder --insecure"
alias ceilometer="ceilometer --os-insecure true"
EOF
  cecho "$description -- done" $cyan
  cecho "Please run 'source $RALLY_FILE_REPO/openrc_tenant' to declare the environment variables in your current process" $cyan
}

rally_add_keypairs() {
  local description="create keypair '$KEYPAIR' for users in $RALLY_USER_FILE"
  if [ "-h" == $1 ]
  then
    cecho "$description" $cyan
    exit 0
  fi
  cecho "$description -- starting" $cyan
  mkdir -p $RALLY_FILE_REPO/$KEYPAIR
  if [ -f $RALLY_USER_FILE ]
  then
    while read line; do
      read -r -a array <<< "$line"
      if [[ ${#array[@]} > 2 ]]
      then
        tenant=${array[0]}
        user=${array[1]}
        password=${array[2]}
        cecho "creating keypair '$KEYPAIR' to user $user in tenant $tenant and storing to file $RALLY_FILE_REPO/$KEYPAIR/$tenant/$user" $cyan
        mkdir -p $RALLY_FILE_REPO/$KEYPAIR/$tenant
        nova --os-user-name $user --os-password $password --os-tenant-name $tenant keypair-add $KEYPAIR > $RALLY_FILE_REPO/$KEYPAIR/$tenant/$user
      fi
    done < $RALLY_USER_FILE
  fi 
  cecho "$description -- done" $cyan
}

rally_increase_quota() {
  local description="increase quota for tenants and users in $RALLY_USER_FILE"
  if [ "-h" == $1 ]
  then
    cecho "$description" $cyan
    exit 0
  fi
  cecho "updating nova default quota to 1100 instances, 1100 cores and 5120000 RAM" $cyan
  nova quota-class-update --instances 1100 default
  nova quota-class-update --cores 1100 default
  nova quota-class-update --ram 5120000 default
  cecho "new nova default quota" $cyan
  nova quota-defaults
  cecho "updating cinder default quota" $cyan
  cinder quota-class-update --volumes 1100 --snapshots 1100 --gigabytes 11000 default
  if [ -f $RALLY_USER_FILE ]
  then
    local previous_tenant=""
    while read line; do
      read -r -a array <<< "$line"
      if [[ ${#array[@]} > 2 ]]
      then
        tenant=${array[0]}
        if [[ "$tenant" != "$previous_tenant" ]]
        then
          cecho "updating neutron quota for tenant $tenant" $cyan
          neutron quota-update --tenant-id $tenant --network 50 --subnet 50 --port 1500 --router 50 --security-group 1500 --security-group-rule 5000 --vip 50 --floatingip 50
          previous_tenant=$tenant 
        fi
      fi
    done < $RALLY_USER_FILE
  fi
  cecho "$description -- done" $cyan 
}

rally_list_stacks() {
  local description="list heat stacks for users in $RALLY_USER_FILE"
  if [ "-h" == $1 ]
  then
    cecho "$description" $cyan
    exit 0
  fi
  cecho "$description -- starting" $cyan 
  if [ -f $RALLY_USER_FILE ]
  then
    while read line; do
      read -r -a array <<< "$line"
      if [[ ${#array[@]} > 2 ]]
      then
        tenant=${array[0]}
        user=${array[1]}
        password=${array[2]}
        cecho "listing all stacks owned by user $user in tenant $tenant" $cyan
        heat --os-username $user --os-password $password --os-tenant-name $tenant stack-list
      fi
    done < $RALLY_USER_FILE
  fi
  cecho "$description -- done" $cyan 
}

rally_remove_stacks() {
  local description="remove heat stacks for users in $RALLY_USER_FILE"
  if [ "-h" == $1 ]
  then
    cecho "$description" $cyan
    exit 0
  fi
  cecho "$description -- starting" $cyan
  if [ -f $RALLY_USER_FILE ]
  then
    while read line; do
      read -r -a array <<< "$line"
      if [[ ${#array[@]} > 2 ]]
      then
        tenant=${array[0]}
        user=${array[1]}
        password=${array[2]}
        cecho "deleting all stacks owned by user $user in tenant $tenant" $cyan
        credential="--os-username $user --os-password $password --os-tenant-name $tenant"
        for stack in `heat $credential stack-list | grep -v "stack_name" | grep -v "IN_PROGRESS" | awk 'BEGIN {FS="|";} {if($3) print $3}'`
        do
          heat $credential stack-delete $stack
        done
      fi
    done < $RALLY_USER_FILE
  fi
  cecho "$description -- done" $cyan
}

check_wordpress_fips() {
  local description="check each floating ip address if there is a wordpress apps running"
  if [ "-h" == $1 ]
  then
    cecho "$description" $cyan
    exit 0
  fi
  cecho "$description -- starting" $cyan
  for fip in `neutron floatingip-list | grep -v "floating_ip_address" | awk 'BEGIN {FS="|";} {if($4) print $4}'`
  do
    wget http://$fip/wp-admin/install.php -O /tmp/wordpress -o /tmp/wget
    validation=`grep "English (United States)" /tmp/wordpress | wc -l`
    if [ $validation -eq 1 ]
    then
      cecho "Wordpress validation on floating ip $fip -- succeeded" $green
    else
      cecho "Wordpress validation on floating ip $fip -- failed" $yellow
    fi
  done
  cecho "$description -- done" $cyan
}

rally_conf_file() {
  local description="generate $RALLY_CONF_FILE where customised rally settings are configured"
  if [ "-h" == $1 ]
  then
    cecho "$description, add option '-o' if you want to overwrite existing file" $cyan
    exit 0
  fi
  if [[ "-o" != $1 ]] && [[ -f $RALLY_CONF_FILE ]]
  then
    cecho "$description -- skipped as $RALLY_CONF_FILE already exists" $yellow
    exit 0
  fi
  cecho "$description -- starting" $cyan
  mkdir -p $RALLY_LOG_DIR
  cat >$RALLY_CONF_FILE <<EOF 
[DEFAULT]
https_insecure=True
log_dir=`echo $RALLY_LOG_DIR`
log_file=rally.log
debug=true
rally_debug=true

[benchmark]
heat_stack_create_timeout=14400.0
heat_stack_create_prepoll_delay=300.0
heat_stack_create_poll_interval=10.0

[database]
connection = `echo "sqlite:///$RALLY_FILE_REPO/.rally.sqlite"`
EOF
  cecho "$description -- done" $cyan
}

rally_hot_weave() {
  local description="copy $(dirname "${BASH_SOURCE[0]}")/../heat to $RALLY_HOT_DIR and weave templates for local execution, e.g. local apt repository"
  local usage="usage: $0 ${FUNCNAME} -s local_apt_repo_server [-d private_network_dns]"
  local local_repo=""
  local private_network_dns=""
  while [[ $# > 0 ]]
  do
    key="$1"
    case $key in
      -h|--help)
      cecho "$description" $cyan
      if [[ "-usage_hidden" != $2 ]]
      then
        cecho "$usage" $yellow
      fi
      exit 0
      ;;
      -s|--local_apt_repo_server)
      local_repo="$2"
      shift
      ;;
      -d|--private_network_dns)
      private_network_dns="$2"
      shift
      ;;
      *)
    esac
    shift
  done
  if [ "$local_repo" == "" ]
  then
    cecho "$usage" $yellow
    exit 0
  fi
  description="copy $(dirname "${BASH_SOURCE[0]}")/../heat to $RALLY_HOT_DIR and weave templates using local apt repository '$local_repo'"
  cecho "$description -- starting" $cyan
  mkdir -p $RALLY_HOT_DIR
  cp -r $(dirname "${BASH_SOURCE[0]}")/../heat/* $RALLY_HOT_DIR/
  if [ "$private_network_dns" != "" ]
  then
    sed -i "s/default: '8.8.8.8'/default: $private_network_dns/" $RALLY_HOT_DIR/lib/wordpress_networks.yaml
  fi
  sed -i '/apt-get update/ i\            echo "deb http://'$local_repo'/ mydebs/" > /etc/apt/sources.list' $RALLY_HOT_DIR/lib/mysql.yaml
  sed -i '/apt-get update/ i\            echo "deb http://'$local_repo'/ mydebs/" > /etc/apt/sources.list' $RALLY_HOT_DIR/lib/wordpress.yaml
  sed -i 's/wordpress.org/'$local_repo'/' $RALLY_HOT_DIR/lib/wordpress.yaml
  sed -i '/apt-get update/ i\            echo "deb http://'$local_repo'/ mydebs/" > /etc/apt/sources.list' $RALLY_HOT_DIR/lib/haproxy.yaml
  sed -i '/cat >>\/etc\/haproxy\/update.py/,/EOF/d' $RALLY_HOT_DIR/lib/haproxy.yaml
  sed -i '/write the update script/ a\        wget http://'$local_repo'/update.py\n        mv update.py /etc/haproxy/update.py' $RALLY_HOT_DIR/lib/haproxy.yaml
# to be deleted after the bug is resolved.
  cp $RALLY_HOT_DIR/lib/wordpress.yaml $RALLY_HOT_DIR/
  cp $RALLY_HOT_DIR/lib/volume_with_attachment.yaml $RALLY_HOT_DIR/
  cecho "$description -- done" $cyan
}

rally_hot_plugins() {
  local description="generate rally plugins into $RALLY_PLUGIN_DIR"
  if [ "-h" == $1 ]
  then
    cecho "$description, add option '-o' if you want to overwrite existing files" $cyan
    exit 0
  fi
  if [[ "-o" != $1 ]] && [[ -f $RALLY_PLUGIN_DIR/scenario/stack_seeding.py ]]
  then
    cecho "$description -- skipped as plugins already exist" $yellow
    exit 0
  fi
  cecho "$description -- starting" $cyan
  mkdir -p $RALLY_PLUGIN_DIR/scenario
  cecho "generating $RALLY_PLUGIN_DIR/scenario/stack_seeding.py with scenario StackSeeding.populate_stacks which doesn't clean up created stacks in the end" $cyan
  cat >$RALLY_PLUGIN_DIR/scenario/stack_seeding.py <<EOF
from rally.plugins.openstack import scenario
from rally.task import types
from rally.task import validation
from rally import consts
from rally.plugins.openstack.scenarios.heat import stacks

class StackSeeding(stacks.HeatStacks):

    @types.set(template_path=types.FileType, files=types.FileTypeDict)
    @validation.required_services(consts.Service.HEAT)
    @scenario.configure(context={})
    def populate_stacks(self, template_path, parameters=None,
                              files=None, environment=None):
        self._create_stack(template_path, parameters, files, environment)
EOF
  cecho "$description -- done" $cyan
}

rally_hot_task_file() {
  local description="generate rally task file (json or yaml)"
  local scenario=StackSeeding.populate_stacks
  local template=heat_wp.yaml
  local task_file=$RALLY_TASK_DIR/stack.json
  local runs=1
  local concurrency=1 
  local template_parameters=""
  while [[ $# > 0 ]]
  do
    key="$1"
    case $key in
      -h|--help)
      cecho "$description" $cyan
      if [[ "-usage_hidden" != $2 ]]
      then
        cecho "usage: $0 ${FUNCNAME} [-s scenario(default $scenario)][-t template(default $template)][-o output(default $task_file)][-r runs(default $runs)][-c concurrency(default $concurrency)][-p template_parameters(example: flavor=m1.small,volume_count=1,volume_size=5)]" $yellow
      fi
      exit 0
      ;;
      -s|--scenario)
      scenario="$2"
      shift
      ;;
      -t|--template)
      template="$2"
      shift
      ;;
      -p|--template_parameters)
      template_parameters="$2"
      shift
      ;;
      -o|--output)
      task_file="$RALLY_TASK_DIR/$2"
      shift
      ;;
      -r|--runs)
      runs="$2"
      shift
      ;;
      -c|--concurrency)
      concurrency="$2"
      shift
      ;;
      *)
    esac
    shift
  done
  if [ ! -f $template ]
  then
    OLDPWD=`pwd`
    local base_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../heat" && pwd)
    cd - > /dev/null
    local old_template=$template
    template=$base_dir/$template
    if [ ! -f $template ]
    then
      cecho "either $old_template or $template doesn't exist" $red
      exit 1
    fi
  fi
  external_net=`neutron net-list | grep $EXTERNAL_NETWORK | awk 'BEGIN {FS="|";} {print $2}'`
  if [ -z $external_net ]
  then
    cecho "an external network is required for function rally_heat_task_file" $red
    exit 1
  fi
  external_net=`echo $external_net`
  local description="generate rally task file '$task_file' with scenario=$scenario, template=$template, runs=$runs, concurrency=$concurrency and public_network_id=$external_net"
  cecho "$description -- starting" $cyan
  mkdir -p $RALLY_TASK_DIR
  if [ "yaml" = ${task_file: -4} ]
  then
    cat >$task_file <<EOF
---

  $scenario:
  {% for i in range(1, 2, 1) %}
    -
      args:
        template_path: "$template"
        parameters:
`rally_hot_parameters $template ":::" | sed 's/,$//' | sed 's/":/:/' | sed 's/:::"/          /' | sed 's/public_network_id: "\([^"]*\)"/public_network_id: "'$external_net'"/'`
        files:
`rally_hot_nested_templates $template | sort | uniq | awk '{printf("          %s: \"%s\"\n",$1,$2)}'`
      runner:
        type: "constant"
        times: $runs
        concurrency: $concurrency
      sla:
        failure_rate:
          max: 0
  {% endfor %}
EOF
    if [ "$template_parameters" != "" ]
    then
      array=`echo $template_parameters | tr "," "\n"`
      for item in $array
      do
        eq=(`echo $item | sed 's/=/ /'`)
        if [ ${#eq[@]} -eq 2 ]
        then
          param=${eq[0]}
          val=${eq[1]}
          sed -i 's/'$param': "\([^"]*\)"/'$param': "'$val'"/;s/'$param': \([0-9]\+\)/'$param': '$val'/' $task_file
        fi
      done
    fi
  else
    cat >$task_file <<EOF
{
  "$scenario": [
    {
      "args": {
        "template_path": "$template",
        "parameters": {
`rally_hot_parameters $template ":::" | sed '$ {s/,//}' | sed 's/:::/          /' | sed 's/"public_network_id": "\([^"]*\)"/"public_network_id": "'$external_net'"/'`
        },
        "files": {
`rally_hot_nested_templates $template | sort | uniq | awk '{printf("          \"%s\": \"%s\",\n",$1,$2)}' | sed '$ {s/,//}'`
        }
      },
      "runner": {
        "type": "constant",
        "times": $runs,
        "concurrency": $concurrency
      },
      "context": {},
      "sla": {
        "failure_rate": {"max": 0}
      }
    }
  ]
}
EOF
    if [ "$template_parameters" != "" ]
    then
      array=`echo $template_parameters | tr "," "\n"`
      for item in $array
      do
        eq=(`echo $item | sed 's/=/ /'`)
        if [ ${#eq[@]} -eq 2 ]
        then
          param=${eq[0]}
          val=${eq[1]}
          sed -i 's/"'$param'": "\([^"]*\)"/"'$param'": "'$val'"/;s/"'$param'": \([0-9]\+\)/"'$param'": '$val'/' $task_file
        fi
      done
    fi
  fi
  cecho "$description -- done" $cyan
}

rally_start_task() {
  local description="kick off rally task with specific task file"
  if [[ -z $1 ]] || [[ "-h" == $1 ]]
  then
    cecho "$description" $cyan
    if [[ "-usage_hidden" != $2 ]]
    then
      cecho "usage: $0 ${FUNCNAME} task_file [--hide-rally-stderr]" $yellow
    fi
    exit 0
  fi
  local task_file=$1
  if [ ! -f $RALLY_CONF_FILE ]  
  then
    rally_conf_file
  fi
  if [ ! -f $task_file ]
  then
    task_file=$RALLY_TASK_DIR/$1
    if [ ! -f $task_file ]
    then
      cecho "either $1 or $task_file doesn't exist" $red
      exit 1
    fi
  fi
  description="kick off rally task '$task_file'"
  cecho "$description -- starting" $cyan
  cd $RALLY_HOT_DIR # to be deleted if the bug is resolved
  if [[ "--hide-rally-stderr" != $2 ]]
  then
    rally --config-file $RALLY_CONF_FILE task start $task_file
  else
    rally --config-file $RALLY_CONF_FILE task start $task_file 2>/dev/null
  fi
  cecho "$description -- done" $cyan
}

rally_task_report() {
  local description="generate report of certain rally task"
  local task=""
  local format="html"
  local output="report.html"
  while [[ $# > 0 ]]
  do
    key="$1"
    case $key in
      -h|--help)
      cecho "$description" $cyan
      if [[ "-usage_hidden" != $2 ]]
      then
        cecho "usage: $0 ${FUNCNAME} [-t task(default latest)][-f format('junit','json' or 'html', default $format)][-o output(default $output)]" $yellow
      fi
      exit 0
      ;;
      -t|--task)
      task="$2"
      shift
      ;;
      -f|--format)
      format="$2"
      shift
      ;;
      -o|--output)
      output="$2"
      shift
      ;;
      *)
    esac
    shift
  done
  if [ "$task" == "" ]
  then
    task=`rally --norally-debug --nodebug task list | grep $RALLY_DEPLOY_NAME | awk 'BEGIN {FS="|";} END {print $2}'`
  else
    task=`rally --norally-debug --nodebug task list | grep $RALLY_DEPLOY_NAME | grep $task | awk 'BEGIN {FS="|";} {print $2}'`
  fi
  if [ -z $task ]
  then
    cecho "requested task doesn't exist for function rally_task_report" $red
    exit 1
  fi
  local finished=`rally --norally-debug --nodebug task status $task | grep finished`
  if [ -z "$finished" ]
  then
    cecho "$(rally --norally-debug --nodebug task status $task)" $red
    exit 1
  fi
  local fail=`rally --norally-debug --nodebug task sla_check $task | grep FAIL` 
  if [ ! -z "$fail" ]
  then
    cecho "sla_check task $task - $fail" $red
    if [[ "$fail" =~ "something_went_wrong" ]]
    then
      exit 1
    fi
  fi
  cecho "$description with task=$task, format=$format, output=$output -- starting" $cyan
  if [ "junit" == $format ]
  then
    rally --nodebug --norally-debug task report $task --junit --out $output 
  elif [ "json" == $format ]
  then
    rally --nodebug --norally-debug task results $task > $output
  else
    rally --nodebug --norally-debug task report $task --out $output
  fi
  cecho "$description -- done" $cyan
}

funcs=`typeset -f | awk '/ \(\) $/ && !/^(cecho|parse_yaml|rally_hot_parameters|rally_hot_nested_templates|env_file|defcore_seeding|defcore_remove_seeding|remove_tenants_users) / {print $1}'`

usage() {
  cecho "usage:" $cyan
  cecho "$0 [subcommand][-h]" $green
  cecho "subcommands available:" $cyan
  for func in $funcs
  do
    cecho "$func -- `$func -h -usage_hidden`" $green
  done
}

env_file
if [[ $# = 0 ]]
then
  usage
else
  if [ "-h" = "$1" ]
  then
    usage
  else
    match=0
    for func in $funcs
    do
      if [ "$func" = "$1" ]
      then
        match=1
      fi
    done
    if [[ $match = 0 ]]
    then
      cecho "$1 is not a valid subcommand" $yellow
    else 
      $@ 2> >(
        while IFS='' read -r line || [ -n "$line" ]; do
          if [[ ! $line =~ InsecurePlatformWarning|DeprecationWarning|InsecureRequestWarning|\*\*kwargs ]]
          then
            cecho "${line}" $red
          fi
        done
      )
      wait
    fi
  fi
fi
