open Common
open Unix
(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)
(*
   Small wrapper around Semgrep_metrics.atd to manipulate
   semgrep metrics data to send to metrics.semgrep.dev.

   This implementation is a port of the python implementation (metrics.py)
   and currently is targeting functionality, not parity.

   To date, we have implemented the following features from the python
   implementation:
     - base payload structure
     - required timing information (started_at, sent_at)
     - required event information (event_id, anonymous_user_id)
     - basic environment information (version, ci, isAuthenticated, integrationName)
     - basic feature tags (subcommands, language)
     - user agent information (version, subommand)
     - language information (language, numRules, numTargets, totalBytesScanned)

    Sending the metrics is handled from the main CLI entrypoint following the
    execution of the CLI.safe_run() function to report the exit code.

    With the original implementation, we specified the following rules to guard
    against sending malformed metrics:
      1. inject all data into the metrics class with add_* methods
      2. ensure all add_* methods only set sanitized data

    The idea was to enforce that we sanitize before write, not before sending.

    Here, we follow a similar approach and try to exclusively use the helper methods
    prefixed by `add_*` as exposed by the metrics interface. Setter methods `set_*`
    are currently exposed as well, but we should plan to keep them as internal to
    this file in the future to help ensure we send consistent and correct data.

    Metrics Flow:
      1. init() - set started_at, event_id, anonymous_user_id
      2. add_feature – tag subcommand, CLI flags, language, etc.
      3. add_user_agent_tag – add CLI version, subcommand, etc.
      4. add_* methods - any other data
      5. prepare_to_send() - set sent_at
      6. string_of_metrics() - serialize metrics payload as JSON string
      7. send_metrics() - send payload to our endpoint (i.e. metrics.semgrep.dev)

    Life of a Metric Payload After Sending:
      -> API Gateway (Name=Telemetry)
      -> Lambda (Name=SemgrepMetricsGatewayToKinesisIntegration)
      -> Kinesis Stream (Name=semgrep-cli-telemetry)
        |-> S3 Bucket (Name=semgrep-cli-metrics)
          -> Snowflake (SEMGREP_CLI_TELEMETRY)
            -> Metabase (SEMGREP CLI - SNOWFLAKE)
        |-> OpenSearch (Name=semgrep-metrics)

    Notes:
      - Raw payload is ingested by our metrics endpoint exposed via our API Gateway
      - We parse the payload and add additional metadata (i.e. sender ip address) in our Lambda function
      - We pass the transformed payload to our AWS Kinesis stream ("semgrep-cli-telemetry")
      - The payload can be viewed in our internal AWS console (if you can guess the shard ID?)
        The shard ID is based on the Partition Key (which is set to the ip address). If someone
        can figure out how to determine the shard ID easily please update this docstring!!!

        In practice, your shard ID only needs to found once through trial and error by sending multiple payloads
        until you find a match. There is probably a better way to do this...

        I found the following StackOverflow link helpful, but not enough to automate this process:
        https://stackoverflow.com/questions/31893297/how-to-determine-shard-id-for-a-specific-partition-key-with-kcl

      - The data viewer URL will look something like https://us-west-2.console.aws.amazon.com/kinesis/home?region=us-west-2#/streams/details/semgrep-cli-telemetry/dataViewer
        where each row is a payload with the IP address as the Partition Key
      - The data is then stored in our S3 bucket ("semgrep-cli-metrics") and can be queried via Snowflake or Metabase


*)

module Out = Semgrep_output_v1_t

(*****************************************************************************)
(* Types and constants *)
(*****************************************************************************)

let _metrics_endpoint = "https://metrics.semgrep.dev"
let _version = spf "%s" Version.version
let _base_user_agent = spf "Semgrep/%s" _version

(*
     Configures metrics upload.

     ON - Metrics always sent
     OFF - Metrics never sent
     AUTO - Metrics only sent if config is pulled from the server
  python: was in an intermediate MetricsState before.
*)
type config = On | Off | Auto [@@deriving show]

(* For Cmdliner
 * TOPORT? use lowercase_ascii before? accept ON/OFF/AUTO?
 * TOPORT? Support setting via old environment variable values 0/1/true/false
 * was in scan.py before.
 *)
let converter = Cmdliner.Arg.enum [ ("on", On); ("off", Off); ("auto", Auto) ]

type t = {
  mutable is_using_registry : bool;
  mutable user_agent : string list;
  mutable payload : Semgrep_metrics_t.payload;
  mutable config : config;
}

let default_payload =
  {
    Semgrep_metrics_t.event_id = "";
    anonymous_user_id = "";
    started_at = "";
    sent_at = "";
    environment =
      {
        version = _version;
        projectHash = None;
        configNamesHash = "";
        rulesHash = None;
        ci = None;
        isAuthenticated = false;
        integrationName = None;
      };
    performance =
      {
        numRules = None;
        numTargets = None;
        totalBytesScanned = None;
        fileStats = None;
        ruleStats = None;
        profilingTimes = None;
        maxMemoryBytes = None;
      };
    errors = { returnCode = None; errors = None };
    value =
      {
        features = [];
        numFindings = None;
        numIgnored = None;
        ruleHashesWithFindings = None;
        engineRequested = "OSS";
      };
    parse_rate = [];
    extension =
      {
        machineId = None;
        isNewAppInstall = None;
        sessionId = None;
        version = None;
        ty = None;
      };
  }

let default =
  {
    is_using_registry = false;
    user_agent = [ _base_user_agent ];
    payload = default_payload;
    config = Off;
  }

(*****************************************************************************)
(* Global! *)
(*****************************************************************************)

(* It is ugly to have to use a global for the metrics data, but it is
 * configured in the subcommands, modified at a few places,
 * and finally accessed in CLI.safe_run() which makes it hard to pass
 * it around.
 *)
let g = default

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)
let string_of_gmtime tm =
  let str =
    Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d+00:00" (1900 + tm.tm_year)
      (1 + tm.tm_mon) tm.tm_mday tm.tm_hour tm.tm_min tm.tm_sec
  in
  str

(*****************************************************************************)
(* Entry points *)
(*****************************************************************************)
let configure config = g.config <- config

open Semgrep_metrics_t

let add_engine_type ~name = g.payload.value.engineRequested <- name
let is_using_registry () = g.is_using_registry
let is_enabled () = g.config <> Off

let set_is_using_registry ~is_using_registry =
  g.is_using_registry <- is_using_registry

let set_anonymous_user_id ~anonymous_user_id =
  g.payload.anonymous_user_id <- anonymous_user_id

let set_started_at ~started_at = g.payload.started_at <- started_at
let set_sent_at ~sent_at = g.payload.sent_at <- sent_at
let set_event_id ~event_id = g.payload.event_id <- event_id
let set_ci () = g.payload.environment.ci <- Some "true"
(* quirk of the python implementation *)

(* NOTE: we pass anonymous_user_id here to avoid a dependency on semgrep settings *)
let init ~anonymous_user_id ~ci =
  let started_at = string_of_gmtime (Unix.gmtime (Unix.gettimeofday ())) in
  let event_id = Uuidm.to_string (Uuidm.v4_gen (Random.get_state ()) ()) in
  let anonymous_user_id = Uuidm.to_string anonymous_user_id in
  set_started_at ~started_at;
  set_event_id ~event_id;
  set_anonymous_user_id ~anonymous_user_id;
  if ci then set_ci ()

let prepare_to_send () =
  let sent_at = string_of_gmtime (Unix.gmtime (Unix.gettimeofday ())) in
  set_sent_at ~sent_at

let string_of_metrics () =
  let json = Semgrep_metrics_j.string_of_payload g.payload in
  let json = Yojson.Safe.from_string json in
  Yojson.Safe.to_string json

let string_of_user_agent () = String.concat " " g.user_agent

let add_user_agent_tag ~str =
  let str =
    str
    |> Base.String.chop_prefix_if_exists ~prefix:"("
    |> Base.String.chop_suffix_if_exists ~suffix:")"
    |> String.trim |> spf "(%s)"
  in
  g.user_agent <- g.user_agent @ [ str ]

let add_project_url = function
  | None -> g.payload.environment.projectHash <- None
  | Some project_url ->
      let parsed_url = Uri.of_string project_url in
      let sanitized_url =
        match Uri.scheme parsed_url with
        | Some "https" ->
            (* XXX(dinosaure): remove username/password from [parsed_url]. *)
            Uri.make ~scheme:"https" ?host:(Uri.host parsed_url)
              ~path:(Uri.path parsed_url) ()
        | __else__ -> parsed_url
      in
      g.payload.environment.projectHash <-
        Some
          Digestif.SHA256.(to_hex (digest_string (Uri.to_string sanitized_url)))

let add_configs ~configs =
  let ctx =
    List.fold_left
      (fun ctx str -> Digestif.SHA256.feed_string ctx str)
      Digestif.SHA256.empty configs
  in
  g.payload.environment.configNamesHash <- Digestif.SHA256.(to_hex (get ctx))

let add_integration_name name = g.payload.environment.integrationName <- name

let add_rules ?profiling:_ rules =
  let hashes = Common.map Rule.sha256_of_rule rules in
  let hashes = Common.map Digestif.SHA256.to_hex hashes in
  let hashes = List.sort String.compare hashes in
  let rulesHash_value =
    List.fold_left
      (fun ctx str -> Digestif.SHA256.feed_string ctx str)
      Digestif.SHA256.empty hashes
  in
  g.payload.environment.rulesHash <-
    Some Digestif.SHA256.(to_hex (get rulesHash_value));
  g.payload.performance.numRules <- Some (List.length rules);
  let ruleStats_value =
    Common.mapi
      (fun idx _rule ->
        { ruleHash = List.nth hashes idx; bytesScanned = 0; matchTime = None })
      rules
  in
  g.payload.performance.ruleStats <- Some ruleStats_value

let add_max_memory_bytes (profiling_data : Report.final_profiling option) =
  Option.iter
    (fun { Report.max_memory_bytes; _ } ->
      g.payload.performance.maxMemoryBytes <- Some max_memory_bytes)
    profiling_data

let add_findings (filtered_matches : (Rule.t * int) list) =
  let ruleHashesWithFindings_value =
    Common.map
      (fun (rule, rule_matches) ->
        let hash = Rule.sha256_of_rule rule in
        (Digestif.SHA256.to_hex hash, rule_matches))
      filtered_matches
  in
  g.payload.value.ruleHashesWithFindings <- Some ruleHashesWithFindings_value

let add_targets (targets : Fpath.t Set_.t)
    (profiling_data : Report.final_profiling option) =
  let fileStats_value =
    Set_.fold
      (fun path acc ->
        let path = Fpath.to_string path in
        let size = (Unix.stat path).Unix.st_size in
        let file_profiling =
          Option.bind profiling_data (fun profiling_data ->
              List.find_opt
                (fun { Report.file; _ } -> file = path)
                profiling_data.Report.file_times)
        in
        let numTimesScanned =
          match file_profiling with
          | None -> 0
          | Some file_profiling -> List.length file_profiling.Report.rule_times
        in
        let parseTime =
          Option.map
            (fun file_profiling ->
              List.fold_left max 0.
                (Common.map
                   (fun { Report.parse_time; _ } -> parse_time)
                   file_profiling.Report.rule_times))
            file_profiling
        in
        let matchTime =
          Option.map
            (fun file_profiling ->
              List.fold_left max 0.
                (Common.map
                   (fun { Report.match_time; _ } -> match_time)
                   file_profiling.Report.rule_times))
            file_profiling
        in
        let runTime =
          Option.map
            (fun file_profiling -> file_profiling.Report.run_time)
            file_profiling
        in
        { size; numTimesScanned; parseTime; matchTime; runTime } :: acc)
      targets []
  in
  let numTargets_value = Set_.cardinal targets in
  let totalBytesScanned =
    Set_.fold
      (fun path acc -> acc + (Unix.stat (Fpath.to_string path)).Unix.st_size)
      targets 0
  in
  g.payload.performance.fileStats <- Some fileStats_value;
  g.payload.performance.totalBytesScanned <- Some totalBytesScanned;
  g.payload.performance.numTargets <- Some numTargets_value

let add_errors errors =
  g.payload.errors.errors <-
    Some
      (errors
      |> Common.map (fun (err : Out.cli_error) -> (* TODO? enough? *)
                                                  err.type_))

let add_profiling profiler =
  g.payload.performance.profilingTimes <- Some (Profiler.dump profiler)

let add_token token =
  g.payload.environment.isAuthenticated <- Option.is_some token

let add_version version = g.payload.environment.version <- version

let add_exit_code code =
  let code = Exit_code.to_int code in
  g.payload.errors.returnCode <- Some code

let add_feature ~category ~name =
  let str = Format.asprintf "%s/%s" category name in
  g.payload.value.features <- str :: g.payload.value.features;
  g.payload.value.features <- List.sort String.compare g.payload.value.features
