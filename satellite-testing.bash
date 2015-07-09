#!/bin/bash
# satellite-testing.bash - OSTF wrapper to enable Satellite testing.
#
main() {
    get_env_configuration "$@"
    #env_json.generate
    #repo_json.generate
    #environment.init
    environment.setup_hosts
    #testenvcli.shell 'repo'
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
    hosts.repo.setup
}

hosts.repo.setup() {
    hosts.run_remote_functions \
        "repo" \
        'hosts.repo.remote.setup' \
        'hosts.remote.*' \
        'hosts.repo.remote.*'
}

hosts.repo.remote.setup() {
    local rh_mirror="http://download.eng.tlv.redhat.com/pub"
    local rhel_mirror="${rh_mirror}/rhel/released/RHEL-7/7.1"
    hosts.remote.yum.zaprepos
    hosts.remote.yum.addrepo \
        'rhel' \
        "${rhel_mirror}/Server/x86_64/os"
    hosts.remote.yum.addrepo \
        'rhel-optional' \
        "${rhel_mirror}/Server-optional/x86_64/os"
    hosts.remote.yum.addrepo \
        'ci-tools' \
        'http://ci-web.eng.lab.tlv.redhat.com/repos/ci-tools/el7'
    hosts.remote.yum.addrepo \
        'rhpkg' \
        'http://download.lab.bos.redhat.com/rel-eng/dist-git/rhel/$releasever/'
    yum install -y createrepo repoman httpd brewkoji
}

hosts.remote.yum.zaprepos() {
    find /etc/yum.repos.d/ -mindepth 1 -maxdepth 1 -type f -print0 \
    | xargs -0 -r rpm -qf \
    | grep -v 'file .* is not owned by any package' \
    | sort -u \
    | xargs -r yum remove -y
    rm -f /etc/yum.repos.d/*
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
