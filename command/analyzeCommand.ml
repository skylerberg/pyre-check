(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open Pyre

let get_analysis_kind = function
  | "taint" -> Taint.Analysis.abstract_kind
  | "liveness" -> DeadStore.Analysis.abstract_kind
  | _ ->
      Log.error "Invalid analysis kind specified.";
      failwith "bad argument"


let run_analysis
    analysis
    result_json_path
    no_verify
    dump_call_graph
    verbose
    expected_version
    sections
    debug
    strict
    show_error_traces
    infer
    additional_checks
    sequential
    filter_directories
    ignore_all_errors
    number_of_workers
    log_identifier
    logger
    profiling_output
    project_root
    search_path
    taint_models_directories
    excludes
    extensions
    local_root
    ()
  =
  let filter_directories =
    filter_directories
    >>| String.split_on_chars ~on:[';']
    >>| List.map ~f:String.strip
    >>| List.map ~f:Path.create_absolute
  in
  let ignore_all_errors =
    ignore_all_errors
    >>| String.split_on_chars ~on:[';']
    >>| List.map ~f:String.strip
    >>| List.map ~f:Path.create_absolute
  in
  let configuration =
    Configuration.Analysis.create
      ~verbose
      ?expected_version
      ~sections
      ~debug
      ~strict
      ~show_error_traces
      ~log_identifier
      ?logger
      ?profiling_output
      ~infer
      ~additional_checks
      ~project_root:(Path.create_absolute project_root)
      ~parallel:(not sequential)
      ?filter_directories
      ?ignore_all_errors
      ~number_of_workers
      ~search_path:(List.map search_path ~f:SearchPath.create)
      ~taint_models_directories:(List.map taint_models_directories ~f:Path.create_absolute)
      ~excludes
      ~extensions
      ~local_root:(Path.create_absolute local_root)
      ()
  in
  let result_json_path = result_json_path >>| Path.create_absolute ~follow_symbolic_links:false in
  let () =
    match result_json_path with
    | Some path when not (Path.is_directory path) ->
        Log.error "--save-results-to path must be a directory.";
        failwith "bad argument"
    | _ -> ()
  in
  (fun () ->
    let timer = Timer.start () in
    let bucket_multiplier =
      try
        Int.of_string (Sys.getenv "BUCKET_MULTIPLIER" |> fun value -> Option.value_exn value)
      with
      | _ -> 10
    in
    let scheduler = Scheduler.create ~configuration ~bucket_multiplier () in
    let errors, ast_environment =
      Service.Check.check
        ~scheduler:(Some scheduler)
        ~configuration
        ~build_legacy_dependency_graph:true
      |> fun { module_tracker; environment; ast_environment; _ } ->
      (* In order to get an accurate call graph and type information, we need to ensure that we
         schedule a type check for external files as well. *)
      let qualifiers = Analysis.ModuleTracker.tracked_explicit_modules module_tracker in
      let external_sources =
        let ast_environment = Analysis.AstEnvironment.read_only ast_environment in
        let is_external qualifier =
          Analysis.AstEnvironment.ReadOnly.get_source_path ast_environment qualifier
          >>| (fun { Ast.SourcePath.is_external; _ } -> is_external)
          |> Option.value ~default:false
        in
        List.filter qualifiers ~f:is_external
      in
      Log.info "Analyzing %d external sources..." (List.length external_sources);
      Service.Check.analyze_sources
        ~filter_external_sources:false
        ~scheduler
        ~configuration
        ~environment
        external_sources
      |> ignore;
      let errors =
        Service.StaticAnalysis.analyze
          ~scheduler
          ~analysis_kind:(get_analysis_kind analysis)
          ~configuration:
            {
              Configuration.StaticAnalysis.configuration;
              result_json_path;
              dump_call_graph;
              verify_models = not no_verify;
            }
          ~environment
          ~qualifiers
          ()
      in
      errors, Analysis.AnnotatedGlobalEnvironment.ReadOnly.ast_environment environment
    in
    let { Caml.Gc.minor_collections; major_collections; compactions; _ } = Caml.Gc.stat () in
    Statistics.performance
      ~name:"analyze"
      ~timer
      ~integers:
        [
          "gc_minor_collections", minor_collections;
          "gc_major_collections", major_collections;
          "gc_compactions", compactions;
        ]
      ();

    (* Print results. *)
    List.map errors ~f:(fun error ->
        Interprocedural.Error.instantiate
          ~lookup:
            (Analysis.AstEnvironment.ReadOnly.get_real_path_relative ~configuration ast_environment)
          error
        |> Interprocedural.Error.Instantiated.to_json ~show_error_traces)
    |> (fun result -> Yojson.Safe.pretty_to_string (`List result))
    |> Log.print "%s";
    Scheduler.destroy scheduler)
  |> Scheduler.run_process ~configuration


let command =
  Command.basic_spec
    ~summary:"Runs a static analysis without a server (default)."
    Command.Spec.(
      empty
      +> flag "-analysis" (optional_with_default "taint" string) ~doc:"Type of analysis to run."
      +> flag
           "-save-results-to"
           (optional string)
           ~doc:"file A JSON file that Pyre Analyze will save its' results to."
      +> flag
           "-no-verify"
           no_arg
           ~doc:"Do not verify that all models passed into the analysis are valid."
      +> flag "-dump-call-graph" no_arg ~doc:"Store call graph in .pyre/call_graph.json"
      ++ Specification.base_command_line_arguments)
    run_analysis
