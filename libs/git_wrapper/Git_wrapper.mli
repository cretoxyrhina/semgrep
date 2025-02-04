(* Small wrapper around the 'git' command-line program *)

exception Error of string

type status = {
  added : string list;
  modified : string list;
  removed : string list;
  unmerged : string list;
  renamed : (string * string) list;
}
[@@deriving show]

(* very general helper to run a git command and return its output
 * if everthing went fine or log the error (using Logs) and
 * raise an Error otherwise
 *)
val git_check_output : Bos.Cmd.t -> string

(* precondition: cwd must be a directory
   This returns a list of paths relative to cwd.
*)
val files_from_git_ls : cwd:Fpath.t -> Fpath.t list

(* get merge base between arg and HEAD *)
val get_merge_base : string -> string

(* Executing a function inside a directory created from git-worktree.

   `git worktree` is doing 90% of the heavy lifting here. Docs:
   https://git-scm.com/docs/git-worktree

   In short, git allows you to have multiple working trees checked out at
   the same time. This means you can essentially have X different
   branches/commits checked out from the same repo, in different locations

   Different worktrees share the same .git directory, so this is a lot
   faster/cheaper than cloning the repo multiple times

   This also allows us to not worry about git state, since
   unstaged/staged files are not shared between worktrees. This means we
   don't need to git stash anything, or expect a clean working tree.
*)
val run_with_worktree :
  commit:string -> ?branch:string option -> (unit -> 'a) -> 'a

(* git status *)
val status : cwd:Fpath.t -> commit:string -> status

(* precondition: cwd must be a directory *)
val is_git_repo : Fpath.t -> bool
(** Returns true if passed directory a git repo*)

(* precondition: cwd must be a directory *)
val dirty_lines_of_file : ?git_ref:string -> Fpath.t -> (int * int) array option
(** [dirty_lines_of_file path] will return an optional array of line ranges that indicate what
  * lines have been changed. An optional [git_ref] can be passed that will be used
  * to diff against. The default [git_ref] is ["HEAD"]
  *)

(* precondition: cwd must be a directory *)
val is_tracked_by_git : Fpath.t -> bool
(** [is_tracked_by_git path] Returns true if the file is tracked by git *)

(* precondition: cwd must be a directory *)
val dirty_files : Fpath.t -> Fpath.t list
(** Returns a list of files that are dirty in a git repo *)

val init : Fpath.t -> unit
(** Initialize a git repo in the given directory *)

val add : Fpath.t -> Fpath.t list -> unit
(** Add the given files to the git repo *)

val commit : Fpath.t -> string -> unit
(** Commit the given files to the git repo with the given message *)

val get_project_url : unit -> string option
(** [get_project_url ()] tries to get the URL of the project from
    [git ls-remote] or from the [.git/config] file. It returns [None] if it
    found nothing relevant.
    TODO: should maybe raise an exn instead if not run from a git repo.
*)

val get_git_logs : ?since:Common2.float_time option -> unit -> string list
(** [get_git_logs()] will run 'git log' in the current directory
    and returns for each log a JSON string that fits the schema
    defined in semgrep_output_v1.atd contribution type.
    It returns an empty list if it found nothing relevant.
    You can use the [since] parameter to restrict the logs to
    the commits since the specified time.
 *)
