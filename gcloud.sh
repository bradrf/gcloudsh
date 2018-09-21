if [ -z "${BASH_VERSINFO}" ] || [ -z "${BASH_VERSINFO[0]}" ] || [ ${BASH_VERSINFO[0]} -lt 3 ]; then
    cat <<EOF

**********************************************************************
               gcloudsh requires Bash version >= 3
**********************************************************************

EOF
fi

# https://cloud.google.com/sdk/docs/scripting-gcloud

alias gc='gcloud compute'
alias gpj="gcloud config list --format='csv[no-heading](core.project)'"

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

    local match=$(gcigrep -c \
      'name,networkInterfaces[].networkIP,networkInterfaces[].accessConfigs[].natIP.map().list(separator=;)' \
      "${name_match}" | head -1)

    if [[ -z "${match}" ]]; then
        echo 'no match found' >&2
        return 2
    fi

    local ips
    IFS=',' read -r -a ips<<< "${match}"

    local args=("${ssh_args[@]}" "${ips[${#ips[@]}-1]}" "$@")
    echo "[${ips[0]}] ssh$(printf ' %q' "${args[@]}")" >&2
    ssh "${ssh_args[@]}" "${ips[${#ips[@]}-1]}" "$@"
}

if [[ "$(basename -- "$0")" = 'gcloud.sh' ]]; then
    cat <<EOF >&2

gcloudsh is meant to be source'd into your environment. Try this:

  $ source "$0"

  $ gu

EOF
    exit 1
fi
