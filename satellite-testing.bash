#!/bin/bash
# satellite-testing.bash - OSTF wrapper to enable Satellite testing.
#
main() {
    get_env_configuration "$@"
    #env_json.generate
    #repo_json.generate
    #environment.init
    #environment.setup_hosts
    hosts.setup_host satellite
}

get_env_configuration() {
    # Read the environment configuration from command line arguments and
    # environment variables and setup script configuration

    # The directory under which OSTF should setup the environment
    local ws_default="$HOME/src/workspace/satellite-testing"
    conf_SATELLITE_OSTF_WORKSPACE="${SATELLITE_OSTF_WORKSPACE:-"$ws_default"}"
}

environment.init() {
    with env_json= env_json -- \
        with repo_json= repo_json -- \
            testenvcli.init
}

environment.start() {
    testenvcli.start
}

environment.setup_hosts() {
    for host in repo satellite; do
        hosts.setup_host "$host"
    done
}

hosts.setup_host() {
    local host="${1:?}"

    hosts.run_remote_functions \
        "$host" \
        "hosts.${host}.remote.setup" \
        "hosts.remote.*" \
        "hosts.${host}.remote.*"
}

hosts.repo.remote.setup() {
    declare -g REPOMAN_CONF='/etc/repoman.conf'
    declare -g REPO_BASE_DIR='/var/www/repos'
    declare -g REPO_BASE_URL='repos'

    local sat6_brew_tag='satellite-6.1.0-rhel-7-candidate'

    hosts.remote.yum.zaprepos
    hosts.remote.yum.add_rhel_repos
    hosts.remote.yum.addrepo \
        'ci-tools' \
        'http://ci-web.eng.lab.tlv.redhat.com/repos/ci-tools/el7'
    hosts.remote.yum.addrepo \
        'rhpkg' \
        'http://download.lab.bos.redhat.com/rel-eng/dist-git/rhel/$releasever/'
    hosts.repo.remote.setup.repoman
    hosts.repo.remote.setup.httpd
    hosts.repo.remote.setup.brew_tag_repo \
        'satellite' \
        "$sat6_brew_tag" \
        inherit
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

hosts.repo.remote.setup.repoman() {
    yum install -y createrepo repoman brewkoji
    cat > "$REPOMAN_CONF" <<EOF
[source.KojiBuildSource]
koji_server = http://brewhub.devel.redhat.com/brewhub
koji_topurl = http://download.devel.redhat.com/brewroot

[store.RPMStore]
# Some links that are expected by some rhel distro flavours
extra_symlinks =
	el6:6Server
	el7:7Server
	el7:7Everything
# no need for src.rpms
with_srcrpms = false
# we don't need sources dir ds
with_sources = false
# don't create rpm subdir
rpm_dir =
EOF
}

hosts.repo.remote.setup.httpd() {
    local HTTPD_CONF='/etc/httpd/conf.d/repos.conf'

    yum install -y httpd
    cat > "$HTTPD_CONF" <<EOF
alias /$REPO_BASE_URL $REPO_BASE_DIR

<Directory $REPO_BASE_DIR>
    Options Indexes FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>
EOF
    install -o root -g root -m 755 -d "$REPO_BASE_DIR"
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

hosts.remote.satellite.setup.satellite() {
    local PRIVATE_IFACE='eth1'
    local private_ip="$(hosts.remote.net.get_conn_ip "$PRIVATE_IFACE")"
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

hosts.remote.net.set_static() {
    local PUBLIC_IFACE=eth0
    local PRIVATE_IFACE=eth1
    local PUBLIC_CONN="$PUBLIC_IFACE"
    local PRIVATE_CONN="$PRIVATE_IFACE"
    local PRIVATE_NET="192.168.105"

    local public_ip="$(hosts.remote.net.get_conn_ip "$PUBLIC_IFACE")"
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
    local public_ip="$(hosts.remote.net.get_conn_ip "$PUBLIC_IFACE")"

    local sedp="
\$a \
$public_ip $hostname "$@"
/^${public_ip//\./\\.}/d
"
    sed -ire "$sedp" /etc/hosts
}

hosts.remote.net.get_conn_ip() {
    local conn_name="${1:?}"

    nmcli conn show "$conn_name" \
    | sed -nre 's/IP4.ADDRESS\[[0-9]\]:\s+([0-9\.]+)\/[0-9]+/\1/p'
}

hosts.remote.yum.zaprepos() {
    find /etc/yum.repos.d/ -mindepth 1 -maxdepth 1 -type f -print0 \
    | xargs -0 -r rpm -qf \
    | grep -v 'file .* is not owned by any package' \
    | sort -u \
    | xargs -r yum remove -y
    rm -f /etc/yum.repos.d/*
}

hosts.remote.yum.add_rhel_repos() {
    local rh_mirror="http://download.eng.tlv.redhat.com/pub"
    local rhel_mirror="${rh_mirror}/rhel/released/RHEL-7/7.1"

    hosts.remote.yum.addrepo \
        'rhel' \
        "${rhel_mirror}/Server/x86_64/os"
    hosts.remote.yum.addrepo \
        'rhel-optional' \
        "${rhel_mirror}/Server-optional/x86_64/os"
    hosts.remote.yum.addrepo \
        'scl' \
        "${rh_mirror}/rhel/released/RHSCL/2.0/RHEL-7/Server/x86_64/os"
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
    local other_function_patterns=("$@")
    #echo bundling functions: "${other_function_patterns[@]}"

    {
        # Send TERM over so we get nicer output
        echo "export TERM=$TERM"
        glob_functions "$main_function" "${other_function_patterns[@]}"
        echo "$main_function"
    } | testenvcli.shell "$host"
}

testenvcli.init() {
    #mkdir -p "${conf_SATELLITE_OSTF_WORKSPACE}"
    testenvcli init \
        --template-repo-path="$repo_json" \
        "${conf_SATELLITE_OSTF_WORKSPACE}" \
        "$env_json"
}

testenvcli.start() {
    with workspace_dir -- \
        testenvcli start
}

testenvcli.shell() {
    local host="${1:?}"
    with workspace_dir -- \
        testenvcli shell "$host"
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
$(for host in satellite repo; do
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
-   template_name: "rhel7_host"
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
name: "in_office_repo"
templates:
    rhel7_host:
        versions:
            v1:
                source: "in-office-minidell"
                handle: "rhel7/host/v1.qcow2"
                timestamp: 1428328144
sources:
    in-office-minidell:
        type: http
        args:
            baseurl: "http://10.35.1.12/repo/"
EOF
}

workspace_dir.get() {
    directory.get "${conf_SATELLITE_OSTF_WORKSPACE}"
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
    local directory="${1:?}"
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

    if type -t "${cmd}.context" > /dev/null; then
        "${cmd}.context" "$varname" "${cmd_args[@]}" -- "${yield[@]}"
    elif
        type -t "${cmd}.get" >> /dev/null \
        && type -t "${cmd}.return" >> /dev/null
    then
        # Have to us a tempfile so ${cmd}.get won't run in a subshell
        cmd_outfile="$(mktemp)"
        exec 10>"$cmd_outfile" 11<"$cmd_outfile"
        rm -f "$cmd_outfile"
        if "${cmd}.get" "${cmd_args[@]}" >&10 ; then
            cmd_output="$(cat <&11)"
            exec 10>&- 11>&-
            declare -g "$varname"="$cmd_output"
            # echo running: "${yield[@]}"
            "${yield[@]}"
            yield_result=$?
            unset "$varname"
            ${cmd}.return "$cmd_output" "${cmd_args[@]}"
        fi
        exec 10>&- 11>&-
        return $yield_result
    else
        echo "${cmd} context definition not found!" 1>&2
        return 1
    fi
}

main "$@"
