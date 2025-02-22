(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open Ast
open Pyre

type t = {
  full: int;
  partial: int;
  untyped: int;
  ignore: int;
  crashes: int;
}
[@@deriving eq, show]

let create ?(full = 0) ?(partial = 0) ?(untyped = 0) ?(ignore = 0) ?(crashes = 0) () =
  { full; partial; untyped; ignore; crashes }


let full { full; _ } = full

let partial { partial; _ } = partial

let untyped { untyped; _ } = untyped

let ignore { ignore; _ } = ignore

let crashes { crashes; _ } = crashes

let sum left right =
  {
    full = full left + full right;
    partial = partial left + partial right;
    untyped = untyped left + untyped right;
    ignore = ignore left + ignore right;
    crashes = crashes left + crashes right;
  }


let aggregate annotations =
  let aggregate ({ full; partial; untyped; _ } as coverage) { Annotation.annotation; _ } =
    if Type.is_untyped annotation then
      { coverage with untyped = untyped + 1 }
    else if Type.is_partially_typed annotation then
      { coverage with partial = partial + 1 }
    else
      { coverage with full = full + 1 }
  in
  List.fold ~init:(create ()) ~f:aggregate annotations


let aggregate_over_source ~source coverages =
  List.fold ~init:(create ~ignore:(List.length (Source.ignore_lines source)) ()) ~f:sum coverages


let log { full; partial; untyped; ignore; crashes } ~total_errors ~path =
  Statistics.coverage
    ~randomly_log_every:50
    ~path
    ~coverage:
      [
        "full_type_coverage", full;
        "partial_type_coverage", partial;
        "no_type_coverage", untyped;
        "ignore_coverage", ignore;
        "total_errors", total_errors;
        "crashes", crashes;
      ]
    ()


module CoverageValue = struct
  type nonrec t = t

  let prefix = Prefix.make ()

  let description = "Coverage"

  let unmarshall value = Marshal.from_string value 0
end

module SharedMemory = Memory.WithCache.Make (SharedMemoryKeys.ReferenceKey) (CoverageValue)

let add coverage ~qualifier = SharedMemory.add qualifier coverage

let get ~qualifier = SharedMemory.get qualifier

type aggregate = {
  strict_coverage: int;
  declare_coverage: int;
  default_coverage: int;
  source_files: int;
}

let coverage ~configuration ~ast_environment qualifiers =
  let qualifiers =
    let is_not_external qualifier =
      AstEnvironment.ReadOnly.get_source_path ast_environment qualifier
      >>| (fun { SourcePath.is_external; _ } -> not is_external)
      |> Option.value ~default:false
    in
    List.filter qualifiers ~f:is_not_external
  in
  let number_of_files = List.length qualifiers in
  let strict_coverage, declare_coverage =
    List.filter_map qualifiers ~f:(AstEnvironment.ReadOnly.get_module_metadata ast_environment)
    |> List.map ~f:Module.local_mode
    |> List.fold ~init:(0, 0) ~f:(fun (prev_strict, prev_declare) local_mode ->
           let mode = Source.mode ~local_mode ~configuration in
           ( (prev_strict + if Source.equal_mode mode Source.Strict then 1 else 0),
             prev_declare + if Source.equal_mode mode Source.Declare then 1 else 0 ))
  in
  {
    strict_coverage;
    declare_coverage;
    default_coverage = number_of_files - strict_coverage - declare_coverage;
    source_files = number_of_files;
  }
