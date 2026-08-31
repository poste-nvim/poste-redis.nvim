; poste-redis highlights (requirements §3.4)
; comment → @comment, use → @keyword + connection @label,
; command name → @keyword.command, args by type.

(comment) @PosteRedisComment

(use_directive
  (connection_name) @PosteRedisLabel)

; USE keyword itself
(use_directive) @PosteRedisKeyword

(command
  (command_name) @PosteRedisCommand)

(command
  (arg
    (string) @PosteRedisString))

(command
  (arg
    (number) @PosteRedisNumber))

(command
  (arg
    (flag) @PosteRedisFlag))
