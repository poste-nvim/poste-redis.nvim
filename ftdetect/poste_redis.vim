" Poste Redis filetype detection
" Use `set filetype=` instead of `setfiletype` because Neovim may detect
" `.redis` as `conf` first; we need to override that builtin match so this
" plugin's syntax and FileType hooks actually run.
autocmd BufRead,BufNewFile *.redis set filetype=poste_redis
