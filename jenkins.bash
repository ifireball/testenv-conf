#!/bin/bash
# jenkins.bash - Lago wrapper to seup a Jenkins environment
#
set -o pipefail
set -e

main() {
    get_env_configuration "$@"
    verbs.playground
}

get_env_configuration() {
    # Read the environment configuration from command line arguments and
    # environment variables and setup script configuration

    # Where environments should be setup
    local ws_root_default="$HOME/src/workspace"
    conf_LAGO_WS_ROOT="${LAGO_WS_ROOT:-"$ws_root_default"}"
    # The directory under which Lago should setup the environment
    local ws_default="$conf_LAGO_WS_ROOT/jenkins"
    conf_JENKINS_LAGO_WORKSPACE="${JENKINS_LAGO_WORKSPACE:-"$ws_default"}"
    # Where is lago
    local lagocli_default="/usr/bin/lagocli"
    conf_JENKINS_LAGO_LAGOCLI="${JENKINS_LAGO_LAGOCLI:-"$lagocli_default"}"
}

verbs.playground() {
    # Reach "playground" steup level where jenkins is deployed
    verbs.base
    for host in jenkins builder; do
        hosts.set_host_level "$host" 'playground'
    done
}

verbs.base() {
    # Reach base setup level with all VMs up and with yum repos
    #environment.init
    #environment.start
    for host in jenkins builder; do
        hosts.set_host_level "$host" 'base'
    done
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

    echo "Setting $host level to $level... "

    local remote_function="hosts.${host}.remote.set_level"
    if ! is_function "$remote_function"; then
        remote_function="hosts.remote.set_level"
    fi

    if hosts.run_remote_functions \
        "$host" \
        "$remote_function" \
        "hosts.remote.*" \
        "hosts.${host}.remote.*" \
        -- \
        "$level"
    then
        echo "Succeeded setting $host level to $level!"
    else
        echo "Failed setting $host level to $level with error code $?"
    fi
}

hosts.jenkins.remote.set_level() {
    local level="${1:?}"

    hosts.remote.set_level "$level"

    [[ -f /etc/yum.repos.d/jenkins.repo ]] \
    || curl \
        -o /etc/yum.repos.d/jenkins.repo \
        http://pkg.jenkins-ci.org/redhat/jenkins.repo
    rpm --import http://pkg.jenkins-ci.org/redhat/jenkins-ci.org.key

    if [[ "$level" == 'playground' ]]; then
        yum install -y jenkins git
        systemctl enable jenkins.service
        systemctl start jenkins.service
    fi
}

hosts.builder.remote.set_level() {
    local level="${1:?}"

    local jenkins_pwd='$6$15e3$cL0hqJQ9CaYIyTEkUY.fitj/HT9hfRCVe5SIAHf47to4GY/k.Q4x2MDSnSUtlHpwLyEqx2LyRLiGcOgivNVNi/'

    hosts.remote.set_level "$level"
    if [[ "$level" == 'playground' ]]; then
        useradd --system --create-home --password "$jenkins_pwd" jenkins
        echo 'jenkins ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/jenkins
        yum install -y tito mock brewkoji
        usermod -a -G mock jenkins
    fi
}

hosts.remote.set_level() {
    local level="${1:?}"

    hosts.remote.yum.zaprepos
    hosts.remote.yum.add_external_rhel_repos
    # Remove cloud-init if its there to speed up booting
    yum remove -y cloud-init || :

    if [[ "$level" == 'playground' ]]; then
        yum install -y java-1.8.0-openjdk
    fi
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
    rpm -q epel-release \
    || yum install -y \
        'https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm'
    hosts.remote.yum.addrepo \
        'rhpkg' \
        'http://download.lab.bos.redhat.com/rel-eng/dist-git/rhel/$releasever/'
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

    {
        # Send TERM over so we get nicer output
        echo "export TERM=$TERM"
        glob_functions "$main_function" "${other_function_patterns[@]}"
        echo "$main_function $(shell_quote "${function_args[@]}")"
    } | testenvcli.shell "$host"
}

testenvcli.init() {
    "$conf_JENKINS_LAGO_LAGOCLI" init \
        --template-repo-path="$repo_json" \
        "${conf_JENKINS_LAGO_WORKSPACE}" \
        "$env_json"
}

testenvcli.start() {
    with workspace_dir -- \
        "$conf_JENKINS_LAGO_LAGOCLI" start
}

testenvcli.shell() {
    local host="${1:?}"
    with workspace_dir -- \
        "$conf_JENKINS_LAGO_LAGOCLI" shell "$host"
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
$(for host in jenkins builder; do
    echo "    $host: $(env_json.generate_host)"
done)
nets:
    testenv:
        type: "nat"
        dhcp:
            start: 100
            end: 254
        management: true
EOF
}

env_json.generate_host() {
    yaml_to_json <<EOF
nics:
-   net: "testenv"
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
    directory.get "${conf_JENKINS_LAGO_WORKSPACE}"
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
