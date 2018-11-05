(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core

open Ast
open Pyre


type result = {
  handles: File.Handle.t list;
  environment: (module Analysis.Environment.Handler);
  errors: Analysis.Error.t list;
}


(** Internal result type; not exposed. *)
type analyze_source_results = {
  errors: Analysis.Error.t list;
  number_files: int;
  coverage: Analysis.Coverage.t;
}


let analyze_sources
    ~scheduler
    ~configuration:({
        Configuration.Analysis.project_root;
        filter_directories;
        run_additional_checks;
        _;
      } as configuration)
    ~environment
    ~handles =
  let open Analysis in
  let analyze_source
      ~configuration:({ Configuration.Analysis.infer; _ } as configuration)
      ~environment
      ~source:({ Source.handle; metadata; _ } as source) =
    let open Analysis in
    (* Override file-specific local debug configuraiton *)
    let { Source.Metadata.local_mode; debug; version; number_of_lines; _ } =
      metadata
    in
    let local_strict, declare =
      match local_mode with
      | Source.Strict -> true, false
      | Source.Declare -> false, true
      | _ -> false, false
    in
    let configuration =
      Configuration.Analysis.localize
        configuration
        ~local_debug:debug
        ~local_strict
        ~declare
    in

    if version < 3 then
      begin
        Log.log
          ~section:`Check
          "Skipping `%a` (Python 2.x)"
          File.Handle.pp handle;
        {
          TypeCheck.Result.errors = [];
          coverage = Coverage.create ();
        }
      end
    else
      begin
        let timer = Timer.start () in
        Log.log ~section:`Check "Checking `%a`..." File.Handle.pp handle;
        let result =
          let check = if infer then Inference.infer ~mode_override:None else TypeCheck.check in
          check ~configuration ~environment ~source
        in
        Statistics.performance
          ~flush:false
          ~randomly_log_every:100
          ~section:`Check
          ~name:(Format.asprintf "SingleFileTypeCheck of %a" File.Handle.pp handle)
          ~timer
          ~normals:["handle", File.Handle.show handle; "request kind", "SingleFileTypeCheck"]
          ~integers:["number of lines", number_of_lines]
          ();
        result
      end
  in

  Annotated.Class.Attribute.Cache.clear ();
  let timer = Timer.start () in
  let handles =
    let filter_by_directories handle =
      match filter_directories with
      | None ->
          true
      | Some filter_directories ->
          List.exists
            filter_directories
            ~f:(fun directory -> Path.directory_contains ~follow_symlinks:true ~directory handle)
    in
    let filter_by_root handle =
      let path = File.Handle.to_path ~configuration handle in
      match path with
      | Some path ->
          Path.directory_contains path ~follow_symlinks:true ~directory:project_root &&
          filter_by_directories path
      | _ ->
          false
    in
    Scheduler.map_reduce
      scheduler
      ~configuration
      ~map:(fun _ handles -> List.filter handles ~f:filter_by_root)
      ~reduce:(fun handles new_handles -> List.rev_append new_handles handles)
      ~initial:[]
      ~inputs:handles
      ()
    |> List.sort ~compare:File.Handle.compare
  in
  Statistics.performance ~name:"filtered directories" ~timer ();

  Log.info "Checking %d sources..." (List.length handles);
  let timer = Timer.start () in
  let empty_result = {
    errors = [];
    number_files = 0;
    coverage = Coverage.create ();
  }
  in
  let { errors; coverage; _ } =
    let map _ handles =
      Annotated.Class.Attribute.Cache.clear ();
      let analyze_source { errors; number_files; coverage = total_coverage } handle =
        match SharedMemory.Sources.get handle with
        | Some source ->
            let { TypeCheck.Result.errors = new_errors; coverage; _; } =
              analyze_source
                ~configuration
                ~environment
                ~source
            in
            {
              errors = List.append new_errors errors;
              number_files = number_files + 1;
              coverage = Coverage.sum total_coverage coverage;
            }
        | None -> {
            errors;
            number_files = number_files + 1;
            coverage = total_coverage;
          }
      in
      List.fold handles ~init:empty_result ~f:analyze_source
    in
    let reduce left right =
      let number_files = left.number_files + right.number_files in
      Log.log ~section:`Progress "Processed %d of %d sources" number_files (List.length handles);
      {
        errors = List.append left.errors right.errors;
        number_files;
        coverage = Coverage.sum left.coverage right.coverage;
      }
    in
    Scheduler.map_reduce
      scheduler
      ~configuration
      ~bucket_size:75
      ~initial:empty_result
      ~map
      ~reduce
      ~inputs:handles
      ()
  in
  Statistics.performance ~name:"analyzed sources" ~timer ();

  let timer = Timer.start () in
  let errors = Postprocess.ignore ~configuration scheduler handles errors in
  Statistics.performance ~name:"postprocessed" ~timer ();

  let timer = Timer.start () in
  let additional_errors =
    if run_additional_checks then
      begin
        Log.info "Running additional checks...";
        let run_additional_check (module Check: Analysis.Check.Signature) =
          Log.info "Running check `%s`..." Check.name;
          let timer = Timer.start () in
          let map _ handles =
            let analyze_source errors handle =
              match SharedMemory.Sources.get handle with
              | Some source ->
                  Check.run ~configuration ~environment ~source
                  |> List.rev_append errors
              | _ ->
                  Log.warning "Unable to load source for `%a`" File.Handle.pp handle;
                  errors
            in
            List.fold handles ~init:[] ~f:analyze_source
          in
          let errors =
            Scheduler.map_reduce
              scheduler
              ~configuration
              ~bucket_size:75
              ~initial:[]
              ~map
              ~reduce:List.append
              ~inputs:handles
              ()
          in
          Statistics.performance ~name:(Format.asprintf "additional_check_%s" Check.name) ~timer ();
          errors
        in
        List.map Analysis.Check.additional_checks ~f:run_additional_check
        |> List.concat
      end
    else
      []
  in
  Statistics.performance ~name:"additional_checks" ~timer ();

  errors @ additional_errors, coverage


let check
    ~scheduler:original_scheduler
    ~configuration:({
        Configuration.Analysis.project_root;
        local_root;
        search_path;
        typeshed;
        _;
      } as configuration) =
  (* Sanity check environment. *)
  let check_directory_exists directory =
    if not (Path.is_directory directory) then
      raise (Invalid_argument (Format.asprintf "`%a` is not a directory" Path.pp directory));
  in
  check_directory_exists local_root;
  check_directory_exists project_root;
  List.iter ~f:check_directory_exists search_path;
  Option.iter typeshed ~f:check_directory_exists;

  let scheduler =
    let bucket_multiplier =
      try Int.of_string (Sys.getenv "BUCKET_MULTIPLIER" |> (fun value -> Option.value_exn value))
      with _ -> 10
    in
    match original_scheduler with
    | None -> Scheduler.create ~configuration ~bucket_multiplier ()
    | Some scheduler -> scheduler
  in

  (* Parse sources. *)
  let { Parser.stubs; sources } = Parser.parse_all scheduler ~configuration in
  Postprocess.register_ignores ~configuration scheduler sources;
  let environment = (module Environment.SharedHandler: Analysis.Environment.Handler) in
  Environment.populate_shared_memory ~configuration ~stubs ~sources;
  let errors, { Analysis.Coverage.full; partial; untyped; ignore; crashes } =
    analyze_sources
      ~scheduler
      ~configuration
      ~environment
      ~handles:sources
  in

  (* Log coverage results *)
  let path_to_files =
    Path.get_relative_to_root ~root:project_root ~path:local_root
    |> Option.value ~default:(Path.absolute local_root)
  in
  let { Coverage.strict_coverage; declare_coverage; default_coverage; source_files } =
    let number_of_files = List.length sources in
    Coverage.coverage ~sources ~number_of_files
  in
  Statistics.coverage
    ~path:path_to_files
    ~coverage:[
      "crashes", crashes;
      "declare_coverage", declare_coverage;
      "default_coverage", default_coverage;
      "full_type_coverage", full;
      "ignore_coverage", ignore;
      "no_type_coverage", untyped;
      "partial_type_coverage", partial;
      "source_files", source_files;
      "strict_coverage", strict_coverage;
      "total_errors", List.length errors;
    ]
    ();

  (* Only destroy the scheduler if the check command created it. *)
  begin
    match original_scheduler with
    | None -> Scheduler.destroy scheduler
    | Some _ -> ()
  end;

  { handles = stubs @ sources; environment; errors }
