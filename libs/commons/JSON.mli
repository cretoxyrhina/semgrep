module Y = Yojson.Basic

(* a JSON object as a string *)
type str = string

type t =
  | Object of (string * t) list
  | Array of t list
  | String of string
  | Int of int
  | Float of float
  | Bool of bool
  | Null
[@@deriving show, eq]

val member : string -> t -> t option
(** [`member s j`] gives `Some v` where `v` is the value associated with the
  * key `s` in the JSON Object `j` or `None` if no such value exists (either
  * `j` is not an object or no such key is present). *)

val to_yojson : t -> Y.t
val from_yojson : Y.t -> t
val load_json : string -> t
val json_of_string : string -> t

val string_of_json :
  ?compact:bool -> ?recursive:bool -> ?allow_nan:bool -> t -> string
(** NOTE: compact, recursive, allow_nan all currently unused *)

val update : Y.t -> Y.t -> Y.t
(** [update old new] makes a new JSON value by, in the case of an object [old]
    and [new], recursively [update]-ing fields from [old] with fields of the
    same name in [new], or, in other cases, using [new] directly.

    For example,
      - [update (`Int i) (`Bool b)] is [`Bool b]
      - [update (`Assoc ["a", `Int i; "c", `String s])
                (`Assoc ["a", `Bool b; "b", `Int k])] is
        [`Assoc ["a", `Bool b; "b", `Int k; "c", `String s]]
    *)
