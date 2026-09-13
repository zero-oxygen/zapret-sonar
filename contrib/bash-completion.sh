#!/usr/bin/env bash
# bash-completion для zapret-sonar / sonar
# Установка: source этот файл в ~/.bashrc или положить в /etc/bash_completion.d/

_sonar_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD-1]}"

    if (( COMP_CWORD == 1 )); then
        # shellcheck disable=SC2207
        COMPREPLY=( $(compgen -W "list use status check validate export-diagnostic snapshots rollback doctor try baseline update upgrade self-update uninstall gamefilter ipset site start stop restart enable disable log help --version --help --debug" -- "$cur") )
        return 0
    fi

    case "$prev" in
        use)
            local strategy
            COMPREPLY=()
            while IFS= read -r strategy; do
                [[ "$strategy" == "$cur"* ]] && COMPREPLY+=("$strategy")
            done < <(command sonar _list 2>/dev/null)
            return 0 ;;
        gamefilter)
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "off tcp udp both" -- "$cur") )
            return 0 ;;
        ipset)
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "none any loaded" -- "$cur") )
            return 0 ;;
        try)
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "--keep" -- "$cur") )
            return 0 ;;
        update|upgrade)
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "--force" -- "$cur") )
            return 0 ;;
        self-update)
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "--force --version" -- "$cur") )
            return 0 ;;
        check)
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "--json --json-v2" -- "$cur") )
            return 0 ;;
        status|validate|snapshots)
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "--json" -- "$cur") )
            return 0 ;;
        export-diagnostic)
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "--output" -- "$cur") )
            return 0 ;;
        site)
            # shellcheck disable=SC2207
            COMPREPLY=( $(compgen -W "--list --remove" -- "$cur") )
            return 0 ;;
    esac

    if [[ "${COMP_WORDS[1]}" == "help" ]]; then
        # shellcheck disable=SC2207
        COMPREPLY=( $(compgen -W "list use status check validate export-diagnostic snapshots rollback doctor try baseline update upgrade self-update uninstall gamefilter ipset site start stop restart enable disable log" -- "$cur") )
        return 0
    fi
}
complete -F _sonar_completion sonar zapret-sonar
