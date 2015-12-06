#!/bin/bash
# satellite-testing.bash - OSTF wrapper to enable Satellite testing.
#
set -o pipefail -e

main() {
    get_env_configuration "$@"
    #verbs.base
    #verbs.playground
    verbs.test "$@"
}

get_env_configuration() {
    # Read the environment configuration from command line arguments and
    # environment variables and setup script configuration

    # Where environments should be setup
    local ws_root_default="$HOME/src/workspace"
    conf_LAGO_WS_ROOT="${LAGO_WS_ROOT:-"$ws_root_default"}"
    # The directory under which Lago should setup the environment
    local ws_default="$conf_LAGO_WS_ROOT/satellite-testing"
    conf_SATELLITE_LAGO_WORKSPACE="${SATELLITE_LAGO_WORKSPACE:-"$ws_default"}"
    # Where is lago
    local lagocli_default="/usr/bin/lagocli"
    conf_SATELLITE_LAGO_LAGOCLI="${SATELLITE_LAGO_LAGOCLI:-"$lagocli_default"}"
}

verbs.base() {
    # Reach base setup level with all VMs up and with yum repos
    environment.init
    environment.start
    # hosts.set_host_level 'repo' 'playground'
    for host in satellite host1 host2; do
        hosts.set_host_level "$host" 'base'
    done
}

verbs.playground() {
    # Reach "playground" steup level where satellite is deployed
    verbs.base
    for host in satellite host1 host2; do
        hosts.set_host_level "$host" 'playground'
    done
}

verbs.test() {
    verbs.playground
    local test_name="${1:-test-foreman-smoke}"
    robotello "$test_name"
}

environment.init() {
    with env_json= env_json -- \
        with repo_json= repo_json -- \
            testenvcli.init
}

environment.start() {
    testenvcli.start
}

hosts.set_host_level() {
    local host="${1:?}"
    local level="${2:?}"

    if [[ ! "$level" =~ ^(base|playground)$ ]]; then
        level='base'
    fi

    local remote_function="hosts.${host}.remote.set_level"
    if ! is_function "$remote_function"; then
        remote_function="hosts.remote.set_level"
    fi

    hosts.run_remote_functions \
        "$host" \
        "$remote_function" \
        "hosts.remote.*" \
        "hosts.${host}.remote.*" \
        -- \
        "$level"
}

hosts.get_host_ip() {
    local host="${1:?}"
    local MGMT_IFACE=eth0

    hosts.run_remote_functions \
        "$host" \
        hosts.remote.net.get_iface_ip \
        "hosts.remote.net.*" \
        -- "$MGMT_IFACE" 2> /dev/null
}

hosts.satellite.get_katello_password() {
    echo 'cat /etc/katello-installer/answers.katello-installer.yaml' \
    | testenvcli.shell satellite 2> /dev/null \
    | yaml_extract "doc['foreman']['admin_password']"
}

hosts.repo.remote.set_level() {
    local level="${1:?}"

    hosts.remote.yum.zaprepos
    hosts.remote.yum.add_rhel_repos
    hosts.repo.remote.setup.httpd
}

hosts.satellite.remote.setup() {
    hosts.remote.yum.zaprepos
    hosts.remote.yum.add_rhel_repos
    hosts.remote.yum.addrepo \
        'satellite' \
        'http://repo/repos/satellite/$releasever'
    hosts.remote.net.set_static
    hosts.remote.net.set_self_resolv satellite.example.com satellite
    hosts.remote.satellite.setup.satellite
}

hosts.repo.remote.setup.httpd() {
    local HTTPD_CONF='/etc/httpd/conf.d/repos.conf'

    yum install -y httpd mod_ssl yum-plugin-fastmirror
    python > "$HTTPD_CONF" <<EOF
import sys
sys.path.insert(0, '/usr/share/yum-cli')
import cli

TEMPLATE = '''RewriteRule ^/proxy/{key}/(.*) {url}\$1 [P] '''

if __name__ == '__main__':
    ybc = cli.YumBaseCli()
    ybc.getOptionsConfig(['repolist', '-q'])
    print 'RewriteEngine On'
    print 'SSLProxyEngine On'
    for repo in ybc.repos.repos.itervalues():
        print TEMPLATE.format(key=repo.id, url=repo.urls[0])
EOF
    systemctl enable httpd
    systemctl restart httpd
    firewall-cmd --permanent --add-service=http
    firewall-cmd --reload
}

hosts.repo.remote.setup.brew_tag_repo() {
    local reponame="${1:?}"
    local tag="${2:?}"
    local inherit="${3}"
    if [[ "${inherit,,}" == "inherit" ]]; then
        inherit='@inherit'
    else
        inherit=''
    fi
    local repo_path="${REPO_BASE_DIR}/${reponame}"

    install -o root -g root -m 755 -d "$repo_path"
    repoman -c "$REPOMAN_CONF" "$repo_path" add "koji:@${tag}${inherit}"
}

hosts.satellite.remote.set_level() {
    local level="${1:?}"
    #local sat_mirror='http://downlaoad.eng.tlv.redhat.com/released/'
    #local sat_url="$sat_mirror/Satellite-6/6.1-GA/RHEL-7/Satellite/x86_64/os/"
    local sat_mirror_host='http://satellite6.lab.eng.rdu2.redhat.com'
    local sat_mirror_dir="$sat_mirror_host/devel/candidate-trees/Satellite"
    local sat_mirror="$sat_mirror_dir/Satellite-6.1.0-RHEL-7-20151111.0/"
    local sat_url="$sat_mirror/compose/Satellite/x86_64/os/"

    hosts.remote.set_level "$level"

    hosts.remote.yum.add_external_rhel_repos
    hosts.remote.yum.addrepo 'satellite' "$sat_url"

    if [[ "$level" == 'playground' ]]; then
        hosts.remote.net.set_static
        hosts.remote.net.set_self_resolv satellite.example.com satellite
        hosts.remote.satellite.setup.satellite
    fi
}

hosts.remote.satellite.setup.satellite() {
    local PRIVATE_IFACE='eth1'
    local PRIVATE_CONN="$(hosts.remote.net.get_iface_conn $PRIVATE_IFACE)"
    local private_ip="$(hosts.remote.net.get_conn_ip "$PRIVATE_CONN")"
    local dhcp_range=(${private_ip%.*}.{10,100})
    local dhcp_range="${dhcp_range[*]}"

    yum install -y katello

    local dns_zone="$(facter domain)"
    local dns_zone="${dns_zone:-example.com}"

    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --permanent --add-port=9090/tcp
    firewall-cmd --reload

    katello-installer \
        --capsule-dns true \
        --capsule-dns-forwarders "$private_ip" \
        --capsule-dns-interface "$PRIVATE_IFACE" \
        --capsule-dns-zone "$dns_zone"\
        --capsule-dhcp true \
        --capsule-dhcp-gateway "$private_ip" \
        --capsule-dhcp-interface "$PRIVATE_IFACE" \
        --capsule-dhcp-nameservers "$private_ip" \
        --capsule-dhcp-range "$dhcp_range" \
        --capsule-tftp true \
        --capsule-tftp-servername "$private_ip"
}

hosts.remote.set_level() {
    local level="${1:?}"

    hosts.remote.yum.zaprepos
    # Remove cloud-init if its there to speed up booting
    yum remove -y cloud-init || :
}

hosts.remote.net.set_static() {
    local PUBLIC_IFACE=eth0
    local PRIVATE_IFACE=eth1
    local PUBLIC_CONN="$(hosts.remote.net.get_iface_conn $PUBLIC_IFACE)"
    local PRIVATE_CONN="$PRIVATE_IFACE"
    local PRIVATE_NET="192.168.105"

    local public_ip="$(hosts.remote.net.get_conn_ip "$PUBLIC_CONN")"
    local private_ip="${public_ip/*./$PRIVATE_NET.}"

    # If local connection already exists disable and delete it
    if nmcli conn show "$PRIVATE_CONN" >> /dev/null 2>&1; then
        nmcli conn down "$PRIVATE_CONN"
        nmcli conn delete "$PRIVATE_CONN"
    fi
    # Drop all connections that use our interface
    local ids_to_drop=($(
        nmcli conn show \
        | while read name uuid type device; do
            [[ "$device" == "$PRIVATE_IFACE" ]] && echo "$uuid"
        done
    ))
    for uuid in "${ids_to_drop[@]}"; do
        echo "Setting connection $uuid down"
        nmcli conn down "$uuid"
    done
    # Add a new connection
    nmcli conn add \
        type ethernet \
        ifname "$PRIVATE_IFACE" \
        con-name "$PRIVATE_CONN" \
        ip4 "$private_ip/24"
    nmcli conn up "$PRIVATE_CONN"
}

hosts.remote.net.set_self_resolv() {
    local hostname="${1:?}"
    shift

    local PUBLIC_IFACE=eth0
    local PUBLIC_CONN="$(hosts.remote.net.get_iface_conn $PUBLIC_IFACE)"
    local public_ip="$(hosts.remote.net.get_conn_ip "$PUBLIC_CONN")"

    local sedp="
\$a \
$public_ip $hostname "$@"
/^${public_ip//\./\\.}/d
"
    sed -ire "$sedp" /etc/hosts
}

hosts.remote.net.get_iface_conn() {
    local iface="${1:?}"
    for conn in $(nmcli -m tabular -t --fields uuid con show --active); do
        conn_iface="$(nmcli -m tabular -t -f GENERAL.DEVICES con show "$conn")"
        if [[ "$conn_iface" == "$iface" ]]; then
            echo "$conn"
        fi
    done
}

hosts.remote.net.get_conn_ip() {
    local conn_name="${1:?}"

    nmcli conn show "$conn_name" \
    | sed -nre 's/IP4.ADDRESS\[[0-9]\]:\s+([0-9\.]+)\/[0-9]+/\1/p'
}

hosts.remote.net.get_iface_ip() {
    local iface="${1:?}"
    local conn="$(hosts.remote.net.get_iface_conn $iface)"
    hosts.remote.net.get_conn_ip "$conn"
}

hosts.remote.yum.zaprepos() {
    set -o pipefail
    find /etc/yum.repos.d/ -mindepth 1 -maxdepth 1 -type f -print0 \
    | xargs -0 -r rpm -qf \
    | grep -v 'file .* is not owned by any package' \
    | sort -u \
    | xargs -r yum remove -y
    rm -f /etc/yum.repos.d/*
    set +o pipefail
}

hosts.remote.yum.add_external_rhel_repos() {
    local rh_mirror="http://download.eng.tlv.redhat.com/pub"
    #local rhel_mirror="${rh_mirror}/rhel/rel-eng/RHEL-7.2-20151001.0/compose"
    local rhel_mirror="${rh_mirror}/rhel/released/RHEL-7/7.1"
    local rhel_z_mirror="${rh_mirror}/rhel/rel-eng/repos/rhel-7.1-z/"

    hosts.remote.yum.addrepo \
        'rhel' \
        "${rhel_mirror}/Server/x86_64/os"
    hosts.remote.yum.addrepo \
        'rhel-z' \
        "${rhel_z_mirror}/x86_64"
    hosts.remote.yum.addrepo \
        'rhel-optional' \
        "${rhel_mirror}/Server-optional/x86_64/os"
    hosts.remote.yum.addrepo \
        'scl' \
        "${rh_mirror}/rhel/released/RHSCL/2.0/RHEL-7/Server/x86_64/os"
}

hosts.remote.yum.add_rhel_repos() {
    hosts.remote.yum.addrepo 'rhel' 'http://repo/proxy/rhel'
    hosts.remote.yum.addrepo 'rhel-optional' 'http://repo/proxy/rhel-optional'
    hosts.remote.yum.addrepo 'scl' 'http://repo/proxy/scl'
}

hosts.remote.yum.add_satellite_repos() {
    hosts.remote.yum.addrepo \
        'satellite-6.1.0-rhel-7-candidate' \
        'http://repo/proxy/satellite-6.1.0-rhel-7-candidate'
}

hosts.remote.yum.add_katello_repos() {
    hosts.remote.yum.addrepo 'epel' 'http://repo/proxy/epel'
    hosts.remote.yum.addrepo 'foreman' 'http://repo/proxy/foreman'
    hosts.remote.yum.addrepo 'foreman-plugins' 'http://repo/proxy/foreman-plugins'
    hosts.remote.yum.addrepo 'katello-candlepin' 'http://repo/proxy/katello-candlepin'
    hosts.remote.yum.addrepo 'katello-client' 'http://repo/proxy/katello-client'
    hosts.remote.yum.addrepo 'katello' 'http://repo/proxy/katello'
    hosts.remote.yum.addrepo 'katello-pulp' 'http://repo/proxy/katello-pulp'
    hosts.remote.yum.addrepo 'puppetlabs-deps' 'http://repo/proxy/puppetlabs-deps'
    hosts.remote.yum.addrepo 'puppetlabs-devel' 'http://repo/proxy/puppetlabs-devel'
    hosts.remote.yum.addrepo 'puppetlabs-products' 'http://repo/proxy/puppetlabs-products'
    hosts.remote.yum.addrepo 'rhscl-ruby193-epel-7-x86_64' 'http://repo/proxy/rhscl-ruby193-epel-7-x86_64'
    hosts.remote.yum.addrepo 'rhscl-v8314-epel-7-x86_64' 'http://repo/proxy/rhscl-v8314-epel-7-x86_64'
}

hosts.remote.yum.addrepo() {
    local reponame="${1:?}"
    local repourl="${2:?}"
    local gpgcheck="${3:-0}"
    local enabled="${4:-1}"
    {
        echo "[$reponame]"
        echo "name=\"$reponame\""
        echo "baseurl=\"$repourl\""
        echo "enabled=$enabled"
        echo "gpgcheck=$gpgcheck"
    } > "/etc/yum.repos.d/${reponame}.repo"
}

hosts.run_remote_functions() {
    local host="${1:?}"
    local main_function="${2:?}"
    shift 2
    local other_function_patterns=()
    while [[ $# -gt 0 ]] && [[ "$1" != "--" ]]; do
        other_function_patterns[${#other_function_patterns[@]}]="$1"
        shift
    done
    #echo bundling functions: "${other_function_patterns[@]}"
    [[ "$1" == "--" ]] && shift
    local function_args=("$@")

    echo "Invoking $main_function on $host" 1>&2
    {
        # Send TERM over so we get nicer output
        echo "export TERM=$TERM"
        glob_functions "$main_function" "${other_function_patterns[@]}"
        echo "$main_function $(shell_quote "${function_args[@]}")"
    } | testenvcli.shell "$host" || :
    # Lago returns strage stuff from 'shell' so ignoring failures above
}

robotello.setup_here() {
    # We need PyYAML to Parse Katello configuration
    pip install PyYAML
    pip install -r requirements.txt
    pip install nose PyVirtualDisplay
    cat > 'robottelo.properties' <<EOF
[main]
project=sat
locale=en_US
remote=0
smoke=0

[server]
hostname=$(hosts.get_host_ip satellite)
ssh_key=${conf_SATELLITE_LAGO_WORKSPACE}/id_rsa
ssh_username=root
admin_username=admin
admin_password=$(hosts.satellite.get_katello_password)
EOF
}

robotello.invoke_here() {
    robotello.setup_here
    make "$@"
}

robotello() {
    local venv_path="${conf_SATELLITE_LAGO_WORKSPACE}/virtualenvs/robotello"
    local upstream_git='https://github.com/SatelliteQE/robottelo'
    local git_path="${conf_SATELLITE_LAGO_WORKSPACE}/git_repos/robotello"

    with virtualenv --create "$venv_path" -- \
        with git_repo \
        --clone "$upstream_git" \
        --checkout master \
        "$git_path" -- \
            robotello.invoke_here "$@"
}

testenvcli.init() {
    #mkdir -p "${conf_SATELLITE_LAGO_WORKSPACE}"
    "$conf_SATELLITE_LAGO_LAGOCLI" init \
        --template-repo-path="$repo_json" \
        "${conf_SATELLITE_LAGO_WORKSPACE}" \
        "$env_json"
}

testenvcli.start() {
    with workspace_dir -- \
        "$conf_SATELLITE_LAGO_LAGOCLI" start
}

testenvcli.shell() {
    local host="${1:?}"
    with workspace_dir -- \
        "$conf_SATELLITE_LAGO_LAGOCLI" shell "$host"
}

virtualenv.create() {
    local venv_path="${1:?}"
    local activate_script="$venv_path/bin/activate"
    if [[ -r "$activate_script" ]]; then
        echo "Python virtual env at $venv_path seems to already exist" 1>&2
    else
        virtualenv -q "$venv_path" 1>&2
    fi
}

virtualenv.get() {
    local create=''

    local opts
    opts="$(getopt -n virtualenv -o c -l create -- "$@")" \
    || return 1
    eval set -- "$opts"
    while true; do
        case "$1" in
            -c|--create) create=true;;
            --) shift; break;;
            *)  return 1;
        esac
        shift
    done

    local venv_path="${1:?}"
    local activate_script="$venv_path/bin/activate"
    [[ "$create" ]] && virtualenv.create "$venv_path"
    if [[ -r "$activate_script" ]]; then
        source "$activate_script"
        echo "$venv_path"
        return 0
    else
        echo "Python virtual env at $venv_path not found" 1>&2
        return 1
    fi
}

virtualenv.return() {
    local venv_path="${1:?}"

    if [[ "$venv_path" == "$VIRTUAL_ENV" ]]; then
        # deactivate should be defined by the virtualenv we're in
        deactivate
    else
        echo "Trying to leave a virtualenv we're not in ($venv_path)" 1>&2
        return 1
    fi
}

git_repo.clone_here() {
    local remote="${1:?}"

    git clone -q "$remote" . 1>&2 \
    || git remote show -n origin \
    | sed -nre 's/^\s*Fetch URL:\s+(.*)\s*$/\1/p' \
    | grep -qxF "$remote"
}

git_repo.checkout_here() {
    local refspec="${1:?}"

    git checkout -q -f "$refspec" 1>&2
}

git_repo.get() {
    local clone=''
    local checkout=''

    local opts
    opts="$(getopt -n git_repo -o '' -l clone:,checkout: -- "$@")" \
    || return 1
    eval set -- "$opts"
    while true; do
        case "$1" in
            --clone) clone="$2"; shift;;
            --checkout) checkout="$2"; shift;;
            --) shift; break;;
            *)  return 1;
        esac
        shift
    done

    local repo_path="${1:?}"
    directory.get --mkdir "$repo_path" || return 1
    if [[ "$clone" ]]; then
        git_repo.clone_here "$clone" || return 2
    fi
    if [[ "$checkout" ]]; then
        git_repo.checkout_here "$checkout" || return 3
    fi
}

git_repo.return() {
    directory.return "$@"
}

env_json.get() {
    json="$(env_json.generate)"
    tempfile.get "$json"
}

env_json.return() {
    local tempfile="${1:?}"
    tempfile.return "$tempfile"
}

env_json.generate() {
yaml_to_json <<EOF
#cat <<EOF
domains:
$(for host in satellite repo host1 host2; do
    echo "    $host: $(env_json.generate_host)"
done)
nets:
    testenv:
        type: "nat"
        dhcp:
            start: 100
            end: 254
        management: true
    sat:
        type: "bridge"
        management: false
EOF
}

env_json.generate_host() {
    yaml_to_json <<EOF
nics:
-   net: "testenv"
-   net: "sat"
disks:
-   template_name: "rhel7_1_host"
    type: "template"
    name: "root"
    dev: "vda"
    format: "qcow2"
"memory": 5120
EOF
}

repo_json.get() {
    json="$(repo_json.generate)"
    tempfile.get "$json"
}

repo_json.return() {
    local tempfile="${1:?}"
    tempfile.return "$tempfile"
}

repo_json.generate() {
    yaml_to_json <<EOF
name: "bob"
templates:
    rhel7_1_host:
        versions:
            v1:
                source: "bob"
                handle: "rhel-guest-image-7.1-20150224.0.x86_64.qcow2"
                timestamp: 1424728800
    rhel7_2_host:
        versions:
            v1:
                source: "bob"
                handle: "rhel-guest-image-7.2-20150925.0.x86_64.qcow2"
                timestamp: 1443128400
sources:
    bob:
        type: http
        args:
            baseurl: "http://bob.eng.lab.tlv.redhat.com/templates/"
EOF
}

workspace_dir.get() {
    directory.get "${conf_SATELLITE_LAGO_WORKSPACE}"
}

workspace_dir.return() {
    directory.return "$@"
}

tempfile.get() {
    local tempfile_content=("$@")
    local tempfile
    tempfile="$(mktemp)" || return 1
    echo "${tempfile_content[@]}" > "$tempfile"
    echo "$tempfile"
    #echo "Created tempfile: $tempfile" 1>&2
    return 0
}

tempfile.return() {
    local tempfile="${1:?}"
    #rm -f "$tempfile"
}

directory.get() {
    local create=''

    local opts
    opts="$(getopt -n directory -o c -l create,mkdir -- "$@")" \
    || return 1
    eval set -- "$opts"
    while true; do
        case "$1" in
            -c|--mkdir|--create) create=true;;
            --) shift; break;;
            *)  return 1;
        esac
        shift
    done

    local directory="${1:?}"
    [[ "$create" ]] && mkdir -p "$directory"
    pwd
    #echo Entering directory: "$directory" 1>&2
    cd "$directory"
}

directory.return() {
    local prev_directory="${1:?}"
    cd "$prev_directory"
}

yaml_to_json() {
    local yaml_to_json_py="
from sys import stdin
from yaml import load
from json import dumps
print dumps(load(stdin), indent=4)
    "
    python -c "$yaml_to_json_py"
}

yaml_extract() {
    local yaml_extract_py="
from sys import stdin, argv
from yaml import load
doc=load(stdin)
print '\n'.join(str(eval(arg)) for arg in argv[1:])
    "
    python -c "$yaml_extract_py" "$@"
}

glob_functions() {
    local patterns=("$@")
    declare -F \
    | while read declare f funcname; do
        for pattern in "${patterns[@]}"; do
            [[ $funcname == $pattern ]] \
            && declare -f "$funcname"
        done
    done
}

with() {
    # Implementation of contexts
    local varname=with_var
    local cmd
    local -a cmd_args
    local cmd_outfile
    local cmd_output
    local -a yield
    local yield_result

    [[ $# -lt 1 ]] && return
    # If 1st parameter ends with '=' it is the name of a global variable to be
    # set with given comman output
    if [[ "$1" == *= ]]; then
        varname="${1%=}"
        echo var="$varname"
        shift
    fi
    [[ $# -lt 1 ]] && return
    # 1st parameter (or 2nd if global variable name was given) is the name of
    # the context commad to be used
    cmd="$1"
    shift
    # All parmeters up to '--' are passed to the context creation function
    while [[ $# -gt 0 ]] && [[ "$1" != "--" ]]; do
        cmd_args[${#cmd_args[@]}]="$1"
        shift
    done
    [[ "$1" == "--" ]] && shift
    # All the rest of the arguments are a command to run within the context
    yield=("$@")

    if is_function "${cmd}.context"; then
        "${cmd}.context" "$varname" "${cmd_args[@]}" -- "${yield[@]}"
    elif is_function "${cmd}.get" && is_function "${cmd}.return"; then
        # Have to use a tempfile so ${cmd}.get won't run in a subshell
        yeild_result=100
        cmd_outfile="$(mktemp)"
        exec 200>"$cmd_outfile" 201<"$cmd_outfile"
        rm -f "$cmd_outfile"
        if "${cmd}.get" "${cmd_args[@]}" >&200 ; then
            cmd_output="$(cat <&201)"
            exec 200>&- 201>&-
            declare -g "$varname"="$cmd_output"
            # echo running: "${yield[@]}"
            "${yield[@]}"
            yield_result=$?
            unset "$varname"
            ${cmd}.return "$cmd_output" "${cmd_args[@]}"
        fi
        exec 200>&- 201>&-
        return $yield_result
    else
        echo "${cmd} context definition not found!" 1>&2
        return 1
    fi
}

shell_quote() {
    local singlequote="'"
    printf " '%s'" "${@//\'/'\\$singlequote'}"
}

is_function() {
    local name="${1:?}"
    [[ "$(type -t "$name")" == 'function' ]]
}

main "$@"
