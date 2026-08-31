; poste-redis highlights (requirements §3.4)
; standard capture groups: comment, keyword, label, function, string, number.

(comment) @comment

(line_continuation) @punctuation.special

(use_directive
  (connection_name) @label)

(use_directive
  (comment_tail) @comment)

; USE keyword itself
(use_directive) @keyword

(command
  (command_name) @function)

(command
  (comment_tail) @comment)

(command
  (arg
    (string) @string))

(command
  (arg
    (number) @number))

(command
  (arg
    (flag) @keyword)
