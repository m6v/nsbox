_rigger_completion() {
    local cur prev
    # Текущее слово под курсором
    cur="${COMP_WORDS[COMP_CWORD]}"
    # Предыдущее слово в строке
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    
    # Список доступных команд
    local commands="list start stop restart execute show destroy"

    # Если предыдущее слово — команда, требующая имя контейнера, получение списка контейнеров nspawn через machinectl
    case "${prev}" in
        start|stop|restart|exec|execute|show|destroy|ps)
            local containers=$(machinectl list --all --no-legend | awk '{print $1}' | grep -v '^\.host$')
            
            COMPREPLY=( $(compgen -W "${containers}" -- "$cur") )
            return 0
            ;;
        list)
            # После команды 'list' аргументы не требуются
            return 0
            ;;
    esac

    # Если вводится самый первый аргумент — дополняем основную команду
    if [ $COMP_CWORD -eq 1 ]; then
        COMPREPLY=( $(compgen -W "${commands}" -- "$cur") )
        return 0
    fi
}

# Привязка автодополнения к имени утилиты rigger
complete -F _rigger_completion rigger
