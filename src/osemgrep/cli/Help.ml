(* Yoann Padioleau
 *
 * Copyright (C) 2023 Semgrep Inc.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * version 2.1 as published by the Free Software Foundation, with the
 * special exception on linking described in file LICENSE.
 *
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
 * LICENSE for more details.
 *)

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)
(* Help messages for 'semgrep --help' and just 'semgrep'.
 *
 * python: the help message was automatically generated by Click
 * based on the docstring and the subcommands. In OCaml we have to
 * generate it manually, but anyway we want full control of the help
 * message so this isn't too bad.
 *
 * LATER: add 'interactive' and 'test' new osemgrep-only
 * subcommands (not added yet to avoid regressions in tests/e2e/test_help.py).
 *)

(*****************************************************************************)
(* Entry point *)
(*****************************************************************************)

let print_help () =
  Ocolor_format.printf
    {|
┌──── @{<green>○○○@} ────┐
│ Semgrep CLI │
└─────────────┘
Semgrep CLI scans your code for bugs, security and dependency vulnerabilities.

For more information about Semgrep, visit @{<cyan;ul>https://semgrep.dev@}

@{<ul>Get Started@}:
  Run @{<cyan>`semgrep login && semgrep ci`@} to find dependency
  vulnerabilities and advanced cross-file findings. 💎

@{<ul>Commands@}:
  @{<cyan>semgrep ci@}                   The recommended way to run semgrep in CI
  @{<cyan>semgrep scan@}                 Run semgrep rules on files

@{<ul>Advanced Commands@}:
  @{<cyan>semgrep install-semgrep-pro@}  Install the Semgrep Pro Engine (recommended)
  @{<cyan>semgrep login@}                Obtain and save credentials for semgrep.dev
  @{<cyan>semgrep logout@}               Remove locally stored credentials to
                               semgrep.dev

@{<ul>Help@}:
  @{<cyan>semgrep COMMAND --help@}       For more information on each command

For the CLI docs visit @{<cyan;ul>https://semgrep.dev/docs/category/semgrep-cli/@}
|}

let print_semgrep_dashdash_help () =
  print_string
    {|Usage: semgrep [OPTIONS] COMMAND [ARGS]...

  To get started quickly, run `semgrep scan --config auto`

  Run `semgrep SUBCOMMAND --help` for more information on each subcommand

  If no subcommand is passed, will run `scan` subcommand by default

Options:
  -h, --help  Show this message and exit.

Commands:
  ci                   The recommended way to run semgrep in CI
  install-semgrep-pro  Install the Semgrep Pro Engine
  login                Obtain and save credentials for semgrep.dev
  logout               Remove locally stored credentials to semgrep.dev
  lsp                  Start the Semgrep LSP server (useful for IDEs)
  publish              Upload rule to semgrep.dev
  scan                 Run semgrep rules on files
  show                 Show various information about Semgrep
|}
