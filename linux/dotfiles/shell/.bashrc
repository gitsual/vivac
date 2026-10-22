# Interactive shell baseline. Secrets belong in a private password manager or
# a local, untracked environment file—not here.
[[ $- != *i* ]] && return

export EDITOR=nvim
export VISUAL=nvim
export PAGER=less
export LESS='-R'

alias ls='ls --color=auto'
alias grep='grep --color=auto'
alias ll='ls -alF'
alias la='ls -A'
alias update='sudo pacman -Syu'
alias cleanup='sudo pacman -Rns $(pacman -Qtdq 2>/dev/null)'
alias n='nvim'

bind 'set completion-ignore-case on'
bind 'set show-all-if-ambiguous on'
PS1='\[\e[38;5;203m\]\u\[\e[0m\]@\[\e[38;5;143m\]\h\[\e[0m\] \[\e[38;5;180m\]\w\[\e[0m\] \\$ '

# Machine, employer and credential-bearing integrations belong in this optional
# local extension. It is never created or tracked by the portfolio.
if [[ -r "$HOME/.config/shell/local.bash" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.config/shell/local.bash"
fi
