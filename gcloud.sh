if [ -z "${BASH_VERSINFO}" ] || [ -z "${BASH_VERSINFO[0]}" ] || [ ${BASH_VERSINFO[0]} -lt 3 ]; then
    cat <<EOF

**********************************************************************
               gcloudsh requires Bash version >= 3
**********************************************************************

EOF
fi

# https://cloud.google.com/sdk/docs/scripting-gcloud

# open instance page: https://console.cloud.google.com/compute/instancesDetail/zones/us-central1-b/instances/gluster-migrator-1?project=unity-cs-collab-test

alias gpj="gcloud config list --format='csv[no-heading](core.project)'"
alias gci='gcloud compute instances list'

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

function gproj()
{
    gcloud config list --format='csv[no-heading](core.project)'
}

function gpjgrep()
{
    gcloud projects list --format="csv[no-heading](projectId)" \
           --sort-by projectId --filter "projectId ~ $*"
}

function gcigrep()
{
    local cols
    if [[ "$1" = '-c' ]]; then
        shift; cols=$1; shift
    else
        cols=name
    fi
    gcloud compute instances list --format="csv[no-heading](${cols})" \
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

    local match=$(gcigrep -c "name,${_GCI_ADDRS_FMT}" "${name_match}" | head -1)

    if [[ -z "${match}" ]]; then
        echo 'no match found' >&2
        return 2
    fi

    local ips
    IFS=',' read -r -a ips<<< "${match}"

    local args=("${ssh_args[@]}" "$(_gci_addr "${ips[@]}")" "$@")
    echo "[${ips[0]}] ssh$(printf ' %q' "${args[@]}")" >&2
    ssh "${ssh_args[@]}" "${args[@]}" "$@"
}

function gssh-save-config()
{
    if [[ $# -lt 1 ]]; then
        cat <<EOF >&2
usage: gssh-save-config <project-match>
EOF
        return 1
    fi

    local pj line info host tf=$(mktemp) i=0

    awk 'BEGIN{f=1};/^'"${_GSSH_CONFIG_MARK} BEGIN"'/{exit};f' < "${HOME}/.ssh/config" > "${tf}"
    echo "${_GSSH_CONFIG_MARK} BEGIN $(date '+%Y-%m-%dT%H:%M:%S%z')" >> "${tf}"

    for pj in $(gpjgrep "$1"); do
        while IFS=, read -r -a info; do
            (( ++i ))
            host="${info[0]}"
            [[ "${host}" = *"${info[1]}"* ]] || host+=".${info[1]}"
            cat <<EOF >> "${tf}"

# ${info[*]}
Host     ${host}.${pj}
Hostname $(_gci_addr "${info[@]}")
EOF
        done < <(gci --project "${pj}" --format="csv[no-heading](name,zone,${_GCI_ADDRS_FMT})")
    done

    echo -e "\n${_GSSH_CONFIG_MARK} END" >> "${tf}"
    awk 'f;/'"${_GSSH_CONFIG_MARK} END"'/{f=1}' >> "${tf}" < "${HOME}/.ssh/config"

    chmod 400 "${tf}"
    mv -f "${tf}" "${HOME}/.ssh/config"
    echo "Added ${i} entries"
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
