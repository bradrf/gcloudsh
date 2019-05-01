#!/bin/bash

if [ -z "${BASH_VERSINFO}" ] || [ -z "${BASH_VERSINFO[0]}" ] || [ ${BASH_VERSINFO[0]} -lt 3 ]; then
    cat <<EOF

**********************************************************************
               gcloudsh requires Bash version >= 3
**********************************************************************

EOF
fi

# https://cloud.google.com/sdk/docs/scripting-gcloud

# open instance page: https://console.cloud.google.com/compute/instancesDetail/zones/us-central1-b/instances/gluster-migrator-1?project=unity-cs-collab-test

alias gpj="gcloud config list --format='value(core.project)'"
alias gci='gcloud compute instances list'

GPROJ_EACH_REGEX="${GPROJ_EACH_REGEX:-.*}"

function gu()
{
    if [[ $# -lt 1 ]]; then
        gcloud config list
        return
    fi

    local project=$(gpjgrep "$@" | head -1)
    if [[ -z "${project}" ]]; then
        echo 'no match found' >&2
        return 1
    fi

    gcloud config set project "${project}"
    gu
}

function gc()
{
    local proj projs
    if [[ "$1" = '-a' ]]; then
        shift; projs=($(gpjgrep "$GPROJ_EACH_REGEX"))
    else
        projs=(gpj)
    fi
    (
        for proj in "${projs[@]}"; do
            gcloud --project "$proj" "$@" &
        done
        wait
    )
}

function gpjgrep()
{
    gcloud projects list --format="value(projectId)" --sort-by projectId --filter "projectId ~ $*"
}

function gpjeach()
{
    (
        for proj in $(gpjgrep "$GPROJ_EACH_REGEX"); do
            gcloud --project "$proj" "$@" &
        done
        wait
    )
}

function gcigrep()
{
    local cols cmd=gcloud
    if [[ "$1" = '-a' ]]; then
        shift; cmd=gpjeach
    fi
    if [[ "$1" = '-c' ]]; then
        shift; cols=$1; shift
    else
        cols=name
    fi
    $cmd compute instances list --format="csv[no-heading](${cols})" \
         --sort-by name --filter "name ~ $*"
}

function gssh()
{
    local ssh_args=()
    while [[ $# -gt 1 ]]; do
        [[ "$1" =~ ^- ]] || break
        ssh_args+=("$1"); shift
    done

    if [[ $# -lt 1 ]]; then
        echo 'usage: gssh [<ssh_options>...] <instance_name_match> [<remote_command>...]' >&2
        return 1
    fi

    local name_match=$1; shift

    local match
    IFS=$'\n' match=($(gcigrep -a -c "name,${_GCI_ADDRS_FMT}" "${name_match}"))

    if [[ ${#match[@]} -lt 1 ]]; then
        echo 'no match found' >&2
        return 2
    fi

    local instance
    if [[ ${#match[@]} -eq 1 ]]; then
        instance="${match[0]}"
    else
        PS3='Choice: '
        select instance in "${match[@]}"; do break; done
    fi

    local ips
    IFS=',' read -r -a ips<<< "${instance}"

    local args=("${ssh_args[@]}" "$(_gci_addr "${ips[@]}")" "$@")
    echo "[${instance}] ssh$(printf ' %q' "${args[@]}")" >&2
    ssh "${ssh_args[@]}" "${args[@]}" "$@"
}

function gssh-save-config()
{
    local final_tf=$(mktemp /tmp/gssh-sc-final.XXX)

    echo "Gathering hosts from GCP projects..."

    # copy out current ssh config stripping existing entries...
    awk 'BEGIN{f=1};/^'"${_GSSH_CONFIG_MARK} BEGIN"'/{exit};f' \
        < "${HOME}/.ssh/config" > "${final_tf}"
    echo "${_GSSH_CONFIG_MARK} BEGIN $(date '+%Y-%m-%dT%H:%M:%S%z')" >> "${final_tf}"

    # create a temp file for each project to build concurrently...
    local pj tfs=() pjs=($(gpjgrep "$GPROJ_EACH_REGEX"))
    for pj in "${pjs[@]}"; do
        tfs+=($(mktemp "/tmp/gssh-${pj}.XXX"))
    done

    # concurrently gather a list of each project's hosts...
    (
        for i in "${!pjs[@]}"; do
            gci --project="${pjs[$i]}" --format="csv[no-heading](name,zone,${_GCI_ADDRS_FMT})" \
                > "${tfs[$i]}" &
        done
        wait
    )

    echo "Building SSH config..."

    # build up all the host configs...
    local pj tf i cnt info total=0
    for i in "${!pjs[@]}"; do
        cnt=0
        pj="${pjs[$i]}"
        tf="${tfs[$i]}"
        while IFS=, read -r -a info; do
            (( ++cnt ))
            (( ++total ))
            host="${info[0]}"
            [[ "${host}" = *"${info[1]}"* ]] || host+=".${info[1]}"
            cat <<EOF >> "${final_tf}"

# ${info[*]}
Host     ${host}.${pj}
Hostname $(_gci_addr "${info[@]}")
EOF
        done < "${tf}"
        rm -f "${tf}"
        echo "Added ${cnt} entries from ${pj}"
    done

    # finish out final config and move into place...
    echo -e "\n${_GSSH_CONFIG_MARK} END" >> "${final_tf}"
    awk 'f;/'"${_GSSH_CONFIG_MARK} END"'/{f=1}' >> "${final_tf}" < "${HOME}/.ssh/config"

    chmod 400 "${final_tf}"
    mv -f "${final_tf}" "${HOME}/.ssh/config"
    echo "Added ${total} entries overall"
}

######################################################################
# PRIVATE - internal helpers

_GCI_ADDRS_FMT='networkInterfaces[].networkIP,'`
              `'networkInterfaces[].accessConfigs[].natIP.map().list(separator=;)'
_GSSH_CONFIG_MARK='### GSSH-CONFIG'

function _gci_addr()
{
    local i=1 a=("$@")
    [[ "${@: -1}" = 'None' ]] && i=2
    echo "${a[${#a[@]}-$i]}"
}

if [[ "$(basename -- "$0")" = 'gcloud.sh' ]]; then
    cat <<EOF >&2

gcloudsh is meant to be source'd into your environment. Try this:

  $ source "$0"

  $ gu

EOF
    exit 1
fi
