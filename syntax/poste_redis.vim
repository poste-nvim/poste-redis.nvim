" Vim syntax file for Poste Redis request files (.redis)
" Language: poste_redis — one command per line, # / -- comments, USE directive
" M1: regex fallback (tree-sitter grammar lands in M2)

if exists("b:current_syntax")
  finish
endif

syn case ignore

" ─── Comments (full-line or inline tail after USE / command) ────────────────
syn match PosteRedisComment '^\s*#.*$'
syn match PosteRedisComment '^\s*--.*$'
" Inline comment tails after commands / USE.
syn match PosteRedisComment '\s\+#.*$'
syn match PosteRedisComment '\s\+--.*$'

" ─── USE directive (plugin instruction, not a Redis command) ──
syn match PosteRedisUse '^\s*use\>' nextgroup=PosteRedisUseName skipwhite
syn match PosteRedisUseName '\S\+' contained

" ─── Line continuation ──
syn match PosteRedisContinuation '\\\s*$'

" ─── Strings ──
syn region PosteRedisString start='"' skip='\\"' end='"'
syn region PosteRedisString start="'" skip="\\'" end="'"

" ─── Numbers (standalone args) ──
syn match PosteRedisNumber '\<-\?\d\+\%(\.\d\+\)\?\>'

" ─── Command name: first token of a non-comment line ──
syn match PosteRedisCommand '^\s*\%(use\>\)\@!\k\+'
  \ contains=PosteRedisUse

" ─── Highlight group links ──
hi def link PosteRedisComment      Comment
hi def link PosteRedisUse          Keyword
hi def link PosteRedisUseName      Identifier
hi def link PosteRedisContinuation Special
hi def link PosteRedisString       String
hi def link PosteRedisNumber       Number
hi def link PosteRedisCommand      Function

let b:current_syntax = "poste_redis"
