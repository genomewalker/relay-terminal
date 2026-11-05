# Relay prompt, intentionally scoped to this application's interactive shells.
# Restore the profile from ~/.config/relay/backups to remove its source hook.
[[ $- == *i* && ${TERM_PROGRAM:-} == relay ]] || return 0

__relay_aesthetic_prompt() {
    local command_status=$?
    local branch='' environment_name='' marker_color='116;203;178'
    local git_state='' git_line git_header git_staged=0 git_changed=0
    local git_ahead='' git_behind='' git_output=''
    # One read-only Git query; avoid scanning untracked files on shared storage.
    # Disabling optional locks keeps the prompt from competing with real work.
    if command -v git >/dev/null 2>&1; then
        git_output=$(GIT_OPTIONAL_LOCKS=0 git status --porcelain=v1 --branch --untracked-files=no --ignore-submodules=all 2>/dev/null) || git_output=''
        while IFS= read -r git_line; do
            case "$git_line" in
                '## '*)
                    git_header=${git_line#'## '}
                    branch=${git_header%%...*}; branch=${branch%% \[*}
                    case "$branch" in 'HEAD (no branch)'*) branch='detached' ;; 'No commits yet on '*) branch=${branch#'No commits yet on '} ;; esac
                    if [[ $git_header =~ ahead[[:space:]]([0-9]+) ]]; then git_ahead=${BASH_REMATCH[1]}; fi
                    if [[ $git_header =~ behind[[:space:]]([0-9]+) ]]; then git_behind=${BASH_REMATCH[1]}; fi
                    ;;
                '') ;;
                *)
                    [[ ${git_line:0:1} != ' ' ]] && git_staged=1
                    [[ ${git_line:1:1} != ' ' ]] && git_changed=1
                    ;;
            esac
        done <<< "$git_output"
        if [[ -n $branch ]]; then
            (( git_staged )) && git_state+=' +'
            (( git_changed )) && git_state+=' ~'
            [[ -n $git_ahead ]] && git_state+=" ↑$git_ahead"
            [[ -n $git_behind ]] && git_state+=" ↓$git_behind"
            [[ -z $git_state ]] && git_state=' =' # tracked files unchanged; untracked files are not scanned
        fi
    fi
    # Branch and environment names are display data, never shell expressions.
    case "$branch" in *[!a-zA-Z0-9/._-]*) branch='branch' ;; esac
    environment_name=${CONDA_DEFAULT_ENV:-${VIRTUAL_ENV##*/}}
    case "$environment_name" in *[!a-zA-Z0-9/._-]*) environment_name='environment' ;; esac
    __relay_prompt_location=$PWD
    if [[ $PWD == "$HOME" ]]; then
        __relay_prompt_location='~'
    elif [[ $PWD == "$HOME/"* ]]; then
        __relay_prompt_location="~/${PWD#"$HOME/"}"
    fi
    # Data expands once through these variables; path names cannot become PS1 code.
    __relay_prompt_location=${__relay_prompt_location//$'\e'/␛}
    __relay_prompt_location=${__relay_prompt_location//$'\n'/⏎}
    __relay_prompt_location=${__relay_prompt_location//$'\r'/ }
    __relay_prompt_location=${__relay_prompt_location//$'\t'/ }
    # Fit context to the actual pane width, preserving both the root and leaf.
    local prompt_columns=${COLUMNS:-80} path_budget path_root parent_leaf head_count tail_count
    [[ $prompt_columns =~ ^[0-9]+$ ]] || prompt_columns=80
    local context_break=0 metadata_separator='  ' host_limit branch_limit environment_limit
    (( prompt_columns < 80 )) && context_break=1
    host_limit=$(( prompt_columns / 3 ))
    (( host_limit > 16 )) && host_limit=16
    (( host_limit < 6 )) && host_limit=6
    branch_limit=$(( prompt_columns - 4 ))
    (( branch_limit > 18 )) && branch_limit=18
    (( branch_limit < 8 )) && branch_limit=8
    environment_limit=$(( prompt_columns - 4 ))
    (( environment_limit > 14 )) && environment_limit=14
    (( environment_limit < 8 )) && environment_limit=8
    (( ${#branch} > branch_limit )) && branch="${branch:0:branch_limit-5}…${branch: -4}"
    (( ${#environment_name} > environment_limit )) && environment_name="${environment_name:0:environment_limit-5}…${environment_name: -4}"
    __relay_prompt_host=${RELAY_PROMPT_REMOTE_HOST:-${HOSTNAME%%.*}}
    case "$__relay_prompt_host" in *[!a-zA-Z0-9._-]*) __relay_prompt_host=remote ;; esac
    (( ${#__relay_prompt_host} > host_limit )) && __relay_prompt_host="${__relay_prompt_host:0:host_limit-5}…${__relay_prompt_host: -4}"
    if (( context_break )); then
        metadata_separator='\n'
        path_budget=$(( prompt_columns - ${#__relay_prompt_host} - 6 ))
    else
        path_budget=$(( prompt_columns - ${#branch} - ${#git_state} - ${#environment_name} - ${#__relay_prompt_host} - 25 ))
    fi
    (( path_budget < 8 )) && path_budget=8
    if (( ${#__relay_prompt_location} > path_budget )); then
        if [[ $__relay_prompt_location == '~/'* ]]; then path_root='~/'; else path_root='/'; fi
        __relay_prompt_folder=${__relay_prompt_location##*/}
        __relay_prompt_parent=${__relay_prompt_location%/*}
        parent_leaf=${__relay_prompt_parent##*/}
        __relay_prompt_location="${path_root}…/${parent_leaf}/${__relay_prompt_folder}"
        if (( ${#__relay_prompt_location} > path_budget )); then
            __relay_prompt_location="${path_root}…/${__relay_prompt_folder}"
        fi
        if (( ${#__relay_prompt_location} > path_budget )); then
            head_count=$(( (path_budget - ${#path_root} - 4) / 2 ))
            tail_count=$(( path_budget - ${#path_root} - 4 - head_count ))
            __relay_prompt_location="${path_root}…/${__relay_prompt_folder:0:head_count}…${__relay_prompt_folder: -tail_count}"
        fi
    fi
    __relay_prompt_folder=${__relay_prompt_location##*/}
    __relay_prompt_parent=${__relay_prompt_location%"$__relay_prompt_folder"}
    if [[ $__relay_prompt_location == / ]]; then
        __relay_prompt_parent=''
        __relay_prompt_folder=/
    fi
    # Context above, a clean input line below. No icon font is required.
    __relay_prompt_branch=$branch
    __relay_prompt_git_state=$git_state
    __relay_prompt_environment=$environment_name
    PS1='\[\e[0m\]\[\e[38;2;103;116;137m\]╭─ \[\e[38;2;149;180;219m\]${__relay_prompt_host}\[\e[38;2;103;116;137m\] · \[\e[38;2;131;147;168m\]${__relay_prompt_parent}\[\e[1;38;2;221;230;242m\]${__relay_prompt_folder}\[\e[0m\]'
    [[ -n $branch ]] && PS1+="$metadata_separator"'\[\e[38;2;116;203;178m\]git:${__relay_prompt_branch}\[\e[38;2;225;190;123m\]${__relay_prompt_git_state}\[\e[0m\]'
    [[ -n $environment_name ]] && PS1+="$metadata_separator"'\[\e[38;2;187;158;223m\]env:${__relay_prompt_environment}\[\e[0m\]'
    PS1+='\n\[\e[38;2;103;116;137m\]╰─ '
    if (( command_status != 0 )); then
        marker_color='239;143;143'
        PS1+='\[\e[38;2;239;143;143m\]exit:'"$command_status"' '
    fi
    if (( EUID == 0 )); then
        marker_color='239;143;143'
        PS1+='\[\e[38;2;239;143;143m\]root '
    fi
    PS1+='\[\e[38;2;'"$marker_color"'m\]❯\[\e[0m\] '
    PS2='\[\e[38;2;103;116;137m\]   …\[\e[0m\] '
    return "$command_status"
}

# Run before Relay's semantic prompt wrapper, including existing shells.
# Preserve history, title, sqz, and other user prompt hooks.
# bash-preexec owns PROMPT_COMMAND after its delayed installation. Register
# with its native callback list so its first prompt cannot erase this hook.
if declare -F __bp_precmd_invoke_cmd >/dev/null; then
    case " ${precmd_functions[*]-} " in
        *' __relay_aesthetic_prompt '*) ;;
        *) precmd_functions=(__relay_aesthetic_prompt "${precmd_functions[@]}") ;;
    esac
elif [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a '* ]]; then
    case ";${PROMPT_COMMAND[*]};" in
        *';__relay_aesthetic_prompt;'*) ;;
        *) PROMPT_COMMAND=(__relay_aesthetic_prompt "${PROMPT_COMMAND[@]}") ;;
    esac
else
    case ";${PROMPT_COMMAND:-};" in
        *';__relay_aesthetic_prompt;'*) ;;
        *) PROMPT_COMMAND="__relay_aesthetic_prompt${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;;
    esac
fi
