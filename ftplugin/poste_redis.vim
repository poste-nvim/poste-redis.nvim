" Poste Redis filetype plugin

if exists("b:did_poste_redis_ftplugin")
  finish
endif
let b:did_poste_redis_ftplugin = 1

" Shell-style comments
setlocal commentstring=#\ %s

setlocal shiftwidth=2
setlocal tabstop=2
setlocal expandtab
