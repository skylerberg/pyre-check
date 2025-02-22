(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open Ast
open Pyre
open Expression
module PreviousEnvironment = UnannotatedGlobalEnvironment

type t = { unannotated_global_environment: UnannotatedGlobalEnvironment.ReadOnly.t }

let create unannotated_global_environment = { unannotated_global_environment }

module AliasValue = struct
  type t = Type.alias

  let prefix = Prefix.make ()

  let description = "Alias"

  let unmarshall value = Marshal.from_string value 0

  let compare = Type.compare_alias
end

let ast_environment { unannotated_global_environment } =
  UnannotatedGlobalEnvironment.ReadOnly.ast_environment unannotated_global_environment


module UnresolvedAlias = struct
  type t = {
    value: Expression.t;
    target: Reference.t;
  }

  let unchecked_resolve ~unparsed ~target map =
    match Type.create ~aliases:(Map.find map) ~use_cache:false unparsed with
    | Type.Variable variable ->
        if Type.Variable.Unary.contains_subvariable variable then
          Type.Any
        else
          Type.Variable { variable with variable = Reference.show target }
    | annotation -> annotation


  type check_result =
    | Resolved of Type.alias
    | HasDependents of {
        unparsed: Expression.t;
        dependencies: string list;
      }

  let checked_resolve
      ({ unannotated_global_environment } as environment)
      { value; target }
      ~dependency
      ()
    =
    let value_annotation = unchecked_resolve ~unparsed:value ~target String.Map.empty in
    let dependencies = String.Hash_set.create () in
    let module TrackedTransform = Type.Transform.Make (struct
      type state = unit

      let visit_children_before _ = function
        | Type.Optional Bottom -> false
        | _ -> true


      let visit_children_after = false

      let visit _ annotation =
        let new_state, transformed_annotation =
          match annotation with
          | Type.Parametric { name = primitive; _ }
          | Primitive primitive ->
              let reference =
                match Node.value (Type.expression (Type.Primitive primitive)) with
                | Expression.Name name when Expression.is_simple_name name ->
                    Expression.name_to_reference_exn name
                | _ -> Reference.create "typing.Any"
              in
              let ast_environment = ast_environment environment in
              if AstEnvironment.ReadOnly.from_empty_stub ast_environment ?dependency reference then
                (), Type.Any
              else if
                UnannotatedGlobalEnvironment.ReadOnly.class_exists
                  ?dependency
                  unannotated_global_environment
                  primitive
                || Option.is_some
                     (AstEnvironment.ReadOnly.get_module_metadata
                        ast_environment
                        ?dependency
                        (Reference.create primitive))
              then
                (), annotation
              else
                let _ = Hash_set.add dependencies primitive in
                (), annotation
          | _ -> (), annotation
        in
        { Type.Transform.transformed_annotation; new_state }
    end)
    in
    let _, annotation = TrackedTransform.visit () value_annotation in
    if Hash_set.is_empty dependencies then
      Resolved (Type.TypeAlias annotation)
    else
      HasDependents { unparsed = value; dependencies = Hash_set.to_list dependencies }
end

type extracted =
  | VariableAlias of Type.Variable.t
  | TypeAlias of UnresolvedAlias.t

let extract_alias { unannotated_global_environment } name ~dependency =
  let extract_alias = function
    | UnannotatedGlobalEnvironment.SimpleAssign { explicit_annotation; value; _ } -> (
        let target_annotation =
          Type.create
            ~aliases:(fun _ -> None)
            ~use_cache:false
            (Expression.from_reference ~location:Location.Reference.any name)
        in
        match Node.value value, explicit_annotation with
        | ( _,
            Some
              {
                Node.value =
                  Call
                    {
                      callee =
                        {
                          Node.value =
                            Name
                              (Name.Attribute
                                {
                                  base =
                                    {
                                      Node.value =
                                        Name
                                          (Name.Attribute
                                            {
                                              base =
                                                { Node.value = Name (Name.Identifier "typing"); _ };
                                              attribute = "Type";
                                              _;
                                            });
                                      _;
                                    };
                                  attribute = "__getitem__";
                                  _;
                                });
                          _;
                        };
                      arguments =
                        [
                          {
                            Call.Argument.value =
                              {
                                Node.value =
                                  Call
                                    {
                                      callee =
                                        {
                                          Node.value =
                                            Name
                                              (Name.Attribute
                                                {
                                                  base =
                                                    {
                                                      Node.value =
                                                        Name
                                                          (Name.Attribute
                                                            {
                                                              base =
                                                                {
                                                                  Node.value =
                                                                    Name
                                                                      (Name.Identifier
                                                                        "mypy_extensions");
                                                                  _;
                                                                };
                                                              attribute = "TypedDict";
                                                              _;
                                                            });
                                                      _;
                                                    };
                                                  attribute = "__getitem__";
                                                  _;
                                                });
                                          _;
                                        };
                                      _;
                                    };
                                _;
                              };
                            _;
                          };
                        ];
                    };
                _;
              } ) ->
            if not (Type.is_top target_annotation) then
              let value = Expression.delocalize value in
              Some (TypeAlias { target = name; value })
            else
              None
        | ( Call _,
            Some
              {
                Node.value =
                  Name
                    (Name.Attribute
                      {
                        base = { Node.value = Name (Name.Identifier "typing"); _ };
                        attribute = "TypeAlias";
                        _;
                      });
                _;
              } )
        | ( Name _,
            Some
              {
                Node.value =
                  Name
                    (Name.Attribute
                      {
                        base = { Node.value = Name (Name.Identifier "typing"); _ };
                        attribute = "TypeAlias";
                        _;
                      });
                _;
              } )
        | Call _, None
        | Name _, None -> (
            let value = Expression.delocalize value in
            let value_annotation = Type.create ~aliases:(fun _ -> None) ~use_cache:false value in
            match Type.Variable.parse_declaration value ~target:name with
            | Some variable -> Some (VariableAlias variable)
            | _ ->
                if
                  not
                    ( Type.is_top target_annotation
                    || Type.is_top value_annotation
                    || Type.equal value_annotation target_annotation )
                then
                  Some (TypeAlias { target = name; value })
                else
                  None )
        | _ -> None )
    | UnannotatedGlobalEnvironment.Imported original_name -> (
        if
          UnannotatedGlobalEnvironment.ReadOnly.class_exists
            unannotated_global_environment
            (Reference.show name)
        then
          None
        else
          match Reference.as_list name, Reference.as_list original_name with
          | [single_identifier], [typing; identifier]
            when String.equal typing "typing" && String.equal single_identifier identifier ->
              (* builtins has a bare qualifier. Don't export bare aliases from typing. *)
              None
          | _ ->
              let value =
                Expression.from_reference ~location:Location.Reference.any original_name
              in
              Some (TypeAlias { target = name; value }) )
    | TupleAssign _
    | Define _ ->
        None
  in
  UnannotatedGlobalEnvironment.ReadOnly.get_unannotated_global
    ?dependency
    unannotated_global_environment
    name
  >>= extract_alias


let produce_alias environment global_name ~track_dependencies =
  (* TODO(T53786399): Optimize this function. Theres a lot of perf potentially to be gained here,
     currently biasing towards simplicity *)
  let dependency =
    Option.some_if track_dependencies (SharedMemoryKeys.AliasRegister global_name)
  in
  let rec get_aliased_type_for current ~visited =
    (* This means we're in a loop *)
    if Set.mem visited current then
      None
    else
      let visited = Set.add visited current in
      let handle_extracted = function
        | VariableAlias variable -> Some (Type.VariableAlias variable)
        | TypeAlias unresolved -> (
          match UnresolvedAlias.checked_resolve environment unresolved ~dependency () with
          | Resolved alias -> Some alias
          | HasDependents { unparsed; dependencies } ->
              let solve_pair dependency =
                get_aliased_type_for (Reference.create dependency) ~visited
                >>| fun solution -> dependency, solution
              in
              List.map dependencies ~f:solve_pair
              |> Option.all
              >>| String.Map.of_alist_exn
              >>| UnresolvedAlias.unchecked_resolve ~target:current ~unparsed
              >>| fun alias -> Type.TypeAlias alias )
      in
      extract_alias environment current ~dependency >>= handle_extracted
  in
  get_aliased_type_for global_name ~visited:Reference.Set.empty


module UpdateResult = Environment.UpdateResult.Make (PreviousEnvironment)

module Aliases = Environment.EnvironmentTable.NoCache (struct
  module PreviousEnvironment = PreviousEnvironment
  module UpdateResult = UpdateResult
  module Key = SharedMemoryKeys.StringKey
  module Value = AliasValue

  type trigger = Reference.t

  let convert_trigger = Reference.show

  type nonrec t = t

  module TriggerSet = Reference.Set

  let produce_value = produce_alias

  let filter_upstream_dependency = function
    | SharedMemoryKeys.AliasRegister name -> Some name
    | _ -> None


  let added_keys upstream_update =
    UnannotatedGlobalEnvironment.UpdateResult.added_unannotated_globals upstream_update


  let current_and_previous_keys upstream_update =
    UnannotatedGlobalEnvironment.UpdateResult.current_and_previous_unannotated_globals
      upstream_update


  let all_keys unannotated_global_environment =
    UnannotatedGlobalEnvironment.ReadOnly.all_unannotated_globals unannotated_global_environment
    |> List.map ~f:Reference.show


  let serialize_value = Type.show_alias

  let show_key = Fn.id

  let equal_value = Type.equal_alias
end)

let update environment ~scheduler ~configuration upstream =
  let result = Aliases.update environment ~scheduler ~configuration upstream in
  Type.Cache.clear ~scheduler ~configuration;
  result


let read_only { unannotated_global_environment } = Aliases.read_only unannotated_global_environment

module ReadOnly = struct
  include Aliases.ReadOnly

  let get_alias = get

  let unannotated_global_environment = upstream_environment

  let parse_annotation_without_validating_type_parameters
      environment
      ?modify_aliases
      ?dependency
      ?(allow_untracked = false)
      ?(allow_primitives_from_empty_stubs = false)
      expression
    =
    let use_type_create_cache = Option.is_none modify_aliases in
    let modify_aliases = Option.value modify_aliases ~default:Fn.id in
    let parsed =
      let expression = Expression.delocalize expression in
      let aliases name = get_alias environment ?dependency name >>| modify_aliases in
      Type.create ~aliases ~use_cache:use_type_create_cache expression
    in
    let annotation =
      if allow_primitives_from_empty_stubs then
        parsed
      else
        let constraints = function
          | Type.Primitive name ->
              let originates_from_empty_stub =
                let ast_environment =
                  UnannotatedGlobalEnvironment.ReadOnly.ast_environment
                    (unannotated_global_environment environment)
                in
                let reference = Reference.create name in
                AstEnvironment.ReadOnly.from_empty_stub ?dependency ast_environment reference
              in
              if originates_from_empty_stub then
                Some Type.Any
              else
                None
          | _ -> None
        in
        Type.instantiate parsed ~constraints
    in
    let contains_untracked annotation =
      let is_tracked =
        UnannotatedGlobalEnvironment.ReadOnly.class_exists
          (unannotated_global_environment environment)
          ?dependency
      in
      List.exists ~f:(fun annotation -> not (is_tracked annotation)) (Type.elements annotation)
    in
    if contains_untracked annotation && not allow_untracked then
      Type.Top
    else
      annotation


  let parse_as_concatenation environment ?dependency expression =
    Expression.delocalize expression
    |> Type.OrderedTypes.Concatenation.parse ~aliases:(get_alias environment ?dependency)


  let parse_as_parameter_specification_instance_annotation
      environment
      ?dependency
      ~variable_parameter_annotation
      ~keywords_parameter_annotation
    =
    let variable_parameter_annotation, keywords_parameter_annotation =
      ( Expression.delocalize variable_parameter_annotation,
        Expression.delocalize keywords_parameter_annotation )
    in
    Type.Variable.Variadic.Parameters.parse_instance_annotation
      ~aliases:(get_alias environment ?dependency)
      ~variable_parameter_annotation
      ~keywords_parameter_annotation
end

module AliasReadOnly = ReadOnly
