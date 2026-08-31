/// <reference types="tree-sitter-cli/dsl" />
// @ts-check
//
// poste-redis grammar (requirements §3.4, M2 P1-6):
//   line-oriented highlighting for comments, USE directives, commands,
//   `\` continuation, and inline comment tails. Lua remains the ONLY parser
//   for execution (EXECUTION-PLAN D1) — this grammar exists purely for
//   highlighting, mirroring the poste-http tree-sitter pattern.

const WS = /[ \t]+/;
const NL = token(choice('\n', '\r', '\r\n'));

module.exports = grammar({
  name: 'poste_redis',

  extras: $ => [],

  rules: {
    source_file: $ => repeat(choice(
      $.line,
      $._blank_line,
    )),

    _blank_line: $ => seq(optional(WS), token(prec(-1, NL))),

    line: $ => seq(
      optional(WS),
      choice($.comment, $.use_directive, $.command),
    ),

    // ─── Comments ───────────────────────────────────
    // Full-line `#` or `--`; inline `#` handled by the argument scanner
    // (the grammar only anchors full-line comments).
    comment: $ => token(seq(
      choice('#', '--'),
      optional(/[^\n]*/),
      NL,
    )),

    // ─── USE directive ──────────────────────────────
    use_directive: $ => seq(
      token(prec(1, /[Uu][Ss][Ee]/)),
      optional(seq(WS, $.connection_name)),
      optional(seq(WS, $.comment_tail)),
      NL,
    ),
    connection_name: $ => /[^ \t\n#]+/,

    // ─── Command ────────────────────────────────────
    command: $ => seq(
      field('name', $.command_name),
      repeat(seq(
        WS,
        choice(field('arg', $.arg), $.line_continuation),
      )),
      optional(seq(WS, $.comment_tail)),
      /[ \t]*/,
      NL,
    ),

    line_continuation: $ => token(seq('\\', /[ \t]*/, NL)),

    // Inline comment tail: `# ...` or `-- ...` after a directive/command.
    comment_tail: $ => token(choice(
      seq('#', /[^\n]*/),
      seq('--', /[^\n]*/),
    )),

    command_name: $ => /[A-Za-z][A-Za-z0-9_-]*/,

    arg: $ => choice(
      $.string,
      $.number,
      $.flag,
      $.bareword,
    ),

    // Double-quoted with JSON-style escapes; single-quoted literal.
    string: $ => choice(
      token(seq('"', /[^"\n]*/, '"')),
      token(seq("'", /[^'\n]*/, "'")),
    ),

    number: $ => /-?\d+(?:\.\d+)?/,

    flag: $ => /--?[A-Za-z][A-Za-z0-9_-]*/,

    // Bare word: up to whitespace / quote / newline. `#` is allowed inside
    // so inline comments don't create lexer ambiguity (they highlight as
    // part of the trailing arg — the M1 regex already colors them).
    bareword: $ => /[^ \t\n"'][^ \t\n"']*/,
  },
});
