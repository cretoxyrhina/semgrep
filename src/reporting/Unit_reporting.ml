open Common
open Testutil
module Out = Semgrep_output_v1_j

(*****************************************************************************)
(* Purpose *)
(*****************************************************************************)
(* Unit (and integration) tests exercising the semgrep-core output format.
 *
 * This module also exercises the semgrep CLI output! (this could be moved
 * in tests/e2e/ at some point
 *)

(*****************************************************************************)
(* Constants *)
(*****************************************************************************)

(* ran from the root of the semgrep repository *)
let tests_path = "tests"
let e2e_path = "cli/tests/e2e/snapshots/"
let e2e_ci_path = e2e_path ^ "test_ci/test_full_run"

(*****************************************************************************)
(* Semgrep-core output *)
(*****************************************************************************)

let semgrep_core_output () =
  pack_tests "semgrep core JSON output"
    (let dir = Filename.concat tests_path "semgrep_output/core_output" in
     (* Some of those JSON were generated by calling semgrep-core as in
      * semgrep-core -l py -e 'foo($X)' tests/python/ tests/parsing_errors/ -json
      *)
     let files = Common2.glob (spf "%s/*.json" dir) in
     files
     |> Common.map (fun file ->
            ( file,
              fun () ->
                let s = Common.read_file file in
                let _res = Out.core_output_of_string s in
                () )))

(*****************************************************************************)
(* Semgrep CLI output *)
(*****************************************************************************)

let semgrep_cli_output () =
  pack_tests "semgrep CLI JSON output"
    (let dir = Filename.concat tests_path "semgrep_output/cli_output" in
     (* Some of those JSON were generated by calling semgrep as in
      * semgrep -l py -e 'foo($X)' /tmp/dir1 where dir1 contained
      * a simple foo.py and bad.py files
      *)
     let files =
       Common2.glob (spf "%s/*.json" dir)
       @ (Common.files_of_dir_or_files_no_vcs_nofilter [ e2e_path ]
         |> List.filter (fun file -> file =~ ".*/results[.]json")
         |> Common.exclude (fun file ->
                (* empty JSON (because of timeout probably) *)
                file =~ ".*/test_spacegrep_timeout/"
                (* weird JSON, results but not match results *)
                || file =~ ".*/test_cli_test/"
                (* missing offset *)
                || file =~ ".*/test_max_target_bytes/"
                (* different API *)
                || file =~ ".*/test_dump_ast/"
                (* too long filename exn in alcotest, and no fingerprint *)
                || file =~ ".*/test_join_rules/"
                || false))
     in
     files
     |> Common.map (fun file ->
            ( file,
              fun () ->
                pr2 (spf "processing %s" file);
                let s = Common.read_file file in
                let _res = Semgrep_output_v1_j.cli_output_of_string s in
                () )))

let semgrep_scans_output () =
  pack_tests "semgrep scans JSON output"
    (let dir = Filename.concat tests_path "semgrep_output/scans_output" in
     let files =
       Common2.glob (spf "%s/findings*.json" dir)
       @ (Common.files_of_dir_or_files_no_vcs_nofilter [ e2e_ci_path ]
         |> List.filter (fun file -> file =~ ".*\\findings.json")
         |> Common.exclude (fun _file -> false))
     in
     files
     |> Common.map (fun file ->
            ( file,
              fun () ->
                pr2 (spf "processing %s" file);
                let s = Common.read_file file in
                let _res = Semgrep_output_v1_j.ci_scan_results_of_string s in
                () )))

(*****************************************************************************)
(* All tests *)
(*****************************************************************************)

let tests () =
  List.flatten
    [ semgrep_core_output (); semgrep_cli_output (); semgrep_scans_output () ]
