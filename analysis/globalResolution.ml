(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open Pyre
open Ast
open Statement

type generic_type_problems =
  | IncorrectNumberOfParameters of {
      actual: int;
      expected: int;
    }
  | ViolateConstraints of {
      actual: Type.t;
      expected: Type.Variable.Unary.t;
    }
  | UnexpectedVariadic of {
      actual: Type.OrderedTypes.t;
      expected: Type.Variable.Unary.t list;
    }
[@@deriving compare, eq, sexp, show, hash]

type type_parameters_mismatch = {
  name: string;
  kind: generic_type_problems;
}
[@@deriving compare, eq, sexp, show, hash]

type global = Annotation.t Node.t [@@deriving eq, show, compare, sexp]

type t = {
  dependency: SharedMemoryKeys.dependency option;
  class_hierarchy_environment: ClassHierarchyEnvironment.ReadOnly.t;
  class_hierarchy: (module ClassHierarchy.Handler);
  aliases: Type.Primitive.t -> Type.alias option;
  module_definition: Reference.t -> Module.t option;
  class_definition: Type.Primitive.t -> ClassSummary.t Node.t option;
  class_metadata: Type.Primitive.t -> ClassMetadataEnvironment.class_metadata option;
  constructor: resolution:t -> Type.Primitive.t -> Type.t option;
  attributes: resolution:t -> Type.t -> AnnotatedAttribute.t list option;
  attribute: resolution:t -> parent:Type.t -> name:string -> AnnotatedAttribute.t option;
  is_protocol: Type.t -> bool;
  undecorated_signature: Reference.t -> Type.t Type.Callable.overload option;
  protocol_assumptions: TypeOrder.ProtocolAssumptions.t;
  global: Reference.t -> global option;
}

type global_resolution_t = t

module type AnnotatedClass = sig
  type t

  type class_data = {
    instantiated: Type.t;
    class_attributes: bool;
    class_definition: t;
  }

  val create : ClassSummary.t Node.t -> t

  val constructor : t -> instantiated:Type.t -> resolution:global_resolution_t -> Type.t

  val is_protocol : t -> bool

  val resolve_class : resolution:global_resolution_t -> Type.t -> class_data list option

  val attributes
    :  ?transitive:bool ->
    ?class_attributes:bool ->
    ?include_generated_attributes:bool ->
    ?instantiated:Type.t ->
    t ->
    resolution:global_resolution_t ->
    AnnotatedAttribute.t list

  val attribute
    :  ?transitive:bool ->
    ?class_attributes:bool ->
    ?special_method:bool ->
    t ->
    resolution:global_resolution_t ->
    name:Identifier.t ->
    instantiated:Type.t ->
    AnnotatedAttribute.t
end

let create ?dependency ~class_metadata_environment ~global (module AnnotatedClass : AnnotatedClass)
  =
  let class_hierarchy_environment =
    ClassMetadataEnvironment.ReadOnly.class_hierarchy_environment class_metadata_environment
  in
  let alias_environment =
    ClassHierarchyEnvironment.ReadOnly.alias_environment class_hierarchy_environment
  in
  let unannotated_global_environment =
    AliasEnvironment.ReadOnly.unannotated_global_environment alias_environment
  in
  let ast_environment =
    UnannotatedGlobalEnvironment.ReadOnly.ast_environment unannotated_global_environment
  in
  let class_definition =
    UnannotatedGlobalEnvironment.ReadOnly.get_class_definition
      unannotated_global_environment
      ?dependency
  in
  let module_definition =
    AstEnvironment.ReadOnly.get_module_metadata ?dependency ast_environment
  in
  let aliases = AliasEnvironment.ReadOnly.get_alias ?dependency alias_environment in
  let edges =
    ClassHierarchyEnvironment.ReadOnly.get_edges ?dependency class_hierarchy_environment
  in
  let constructor ~resolution class_name =
    let instantiated = Type.Primitive class_name in
    class_definition class_name
    >>| AnnotatedClass.create
    >>| AnnotatedClass.constructor ~instantiated ~resolution
  in
  let is_protocol annotation =
    Type.split annotation
    |> fst
    |> Type.primitive_name
    >>= class_definition
    >>| AnnotatedClass.create
    >>| AnnotatedClass.is_protocol
    |> Option.value ~default:false
  in
  let attributes ~resolution annotation =
    match AnnotatedClass.resolve_class ~resolution annotation with
    | None -> None
    | Some [] -> None
    | Some [{ instantiated; class_attributes; class_definition }] ->
        AnnotatedClass.attributes
          class_definition
          ~resolution
          ~transitive:true
          ~instantiated
          ~class_attributes
        |> Option.some
    | Some (_ :: _) ->
        (* These come from calling attributes on Unions, which are handled by solve_less_or_equal
           indirectly by breaking apart the union before doing the instantiate_protocol_parameters.
           Therefore, there is no reason to deal with joining the attributes together here *)
        None
  in
  let attribute ~resolution ~parent:annotation ~name =
    match AnnotatedClass.resolve_class ~resolution annotation with
    | None -> None
    | Some [] -> None
    | Some [{ instantiated; class_attributes; class_definition }] ->
        AnnotatedClass.attribute
          class_definition
          ~resolution
          ~transitive:true
          ~instantiated
          ~class_attributes
          ~name
        |> fun attribute -> Option.some_if (AnnotatedAttribute.defined attribute) attribute
    | Some (_ :: _) -> None
  in
  let class_hierarchy =
    ( module struct
      let edges = edges

      let contains key = class_definition key |> Option.is_some
    end : ClassHierarchy.Handler )
  in
  let class_metadata =
    ClassMetadataEnvironment.ReadOnly.get_class_metadata ?dependency class_metadata_environment
  in
  let undecorated_signature =
    ClassHierarchyEnvironment.ReadOnly.get_undecorated_function
      ?dependency
      class_hierarchy_environment
  in
  {
    dependency;
    class_hierarchy_environment;
    class_hierarchy;
    aliases;
    module_definition;
    class_definition;
    class_metadata;
    constructor;
    undecorated_signature;
    attributes;
    attribute;
    is_protocol;
    protocol_assumptions = TypeOrder.ProtocolAssumptions.empty;
    global;
  }


let alias_environment { class_hierarchy_environment; _ } =
  ClassHierarchyEnvironment.ReadOnly.alias_environment class_hierarchy_environment


let unannotated_global_environment resolution =
  alias_environment resolution |> AliasEnvironment.ReadOnly.unannotated_global_environment


let ast_environment resolution =
  unannotated_global_environment resolution
  |> UnannotatedGlobalEnvironment.ReadOnly.ast_environment


let is_tracked { class_hierarchy; _ } = ClassHierarchy.contains class_hierarchy

let contains_untracked resolution annotation =
  List.exists
    ~f:(fun annotation -> not (is_tracked resolution annotation))
    (Type.elements annotation)


let constructor ({ constructor; _ } as resolution) = constructor ~resolution

let is_protocol { is_protocol; _ } = is_protocol

let primitive_name annotation =
  let primitive, _ = Type.split annotation in
  Type.primitive_name primitive


let class_definition { class_definition; _ } annotation =
  primitive_name annotation >>= class_definition


let class_metadata { class_metadata; _ } annotation = primitive_name annotation >>= class_metadata

let full_order ({ class_hierarchy; attributes = a; protocol_assumptions; _ } as resolution) =
  let constructor instantiated ~protocol_assumptions =
    instantiated |> Type.primitive_name >>= constructor { resolution with protocol_assumptions }
  in
  let attributes t ~protocol_assumptions =
    a ~resolution:{ resolution with protocol_assumptions } t
  in
  let is_protocol annotation ~protocol_assumptions =
    is_protocol { resolution with protocol_assumptions } annotation
  in
  {
    TypeOrder.handler = class_hierarchy;
    constructor;
    attributes;
    is_protocol;
    protocol_assumptions;
  }


let variables ?(default = None) { class_hierarchy; _ } =
  ClassHierarchy.variables ~default class_hierarchy


let check_invalid_type_parameters resolution annotation =
  let module InvalidTypeParametersTransform = Type.Transform.Make (struct
    type state = type_parameters_mismatch list

    let visit_children_before _ _ = false

    let visit_children_after = true

    let visit sofar annotation =
      let transformed_annotation, new_state =
        let generics_for_name name =
          match name with
          | "type"
          | "typing.Type"
          | "typing.ClassVar"
          | "typing.Iterator"
          | "Optional"
          | "typing.Final"
          | "typing_extensions.Final"
          | "typing.Optional" ->
              ClassHierarchy.Unaries [Type.Variable.Unary.create "T"]
          | _ -> variables resolution name |> Option.value ~default:(ClassHierarchy.Unaries [])
        in
        let invalid_type_parameters ~name ~given =
          let generics = generics_for_name name in
          let open ClassHierarchy in
          match generics, given with
          | Unaries generics, Type.OrderedTypes.Concrete given -> (
            match List.zip generics given with
            | Ok [] -> Type.Primitive name, sofar
            | Ok paired ->
                let check_parameter (generic, given) =
                  let invalid =
                    let order = full_order resolution in
                    let pair = Type.Variable.UnaryPair (generic, given) in
                    TypeOrder.OrderedConstraints.add_lower_bound TypeConstraints.empty ~order ~pair
                    >>| TypeOrder.OrderedConstraints.add_upper_bound ~order ~pair
                    |> Option.is_none
                  in
                  if invalid then
                    ( Type.Any,
                      Some
                        { name; kind = ViolateConstraints { actual = given; expected = generic } }
                    )
                  else
                    given, None
                in
                List.map paired ~f:check_parameter
                |> List.unzip
                |> fun (parameters, errors) ->
                Type.parametric name (Concrete parameters), List.filter_map errors ~f:Fn.id @ sofar
            | Unequal_lengths ->
                let mismatch =
                  {
                    name;
                    kind =
                      IncorrectNumberOfParameters
                        { actual = List.length given; expected = List.length generics };
                  }
                in
                ( Type.parametric name (Concrete (List.map generics ~f:(fun _ -> Type.Any))),
                  mismatch :: sofar ) )
          | Concatenation _, Any -> Type.parametric name given, sofar
          | Unaries generics, Concatenation _
          | Unaries generics, Any ->
              let mismatch =
                { name; kind = UnexpectedVariadic { expected = generics; actual = given } }
              in
              Type.parametric name given, mismatch :: sofar
          | Concatenation _, Concatenation _
          | Concatenation _, Concrete _ ->
              (* TODO(T47346673): accept w/ new kind of validation *)
              Type.parametric name given, sofar
        in
        match annotation with
        | Type.Primitive name -> invalid_type_parameters ~name ~given:(Concrete [])
        (* natural variadics *)
        | Type.Parametric { name = "typing.Protocol"; _ }
        | Type.Parametric { name = "typing.Generic"; _ } ->
            annotation, sofar
        | Type.Parametric { name; parameters } -> invalid_type_parameters ~name ~given:parameters
        | _ -> annotation, sofar
      in
      { Type.Transform.transformed_annotation; new_state }
  end)
  in
  InvalidTypeParametersTransform.visit [] annotation


module AnnotationCache = struct
  type t = {
    allow_untracked: bool;
    allow_invalid_type_parameters: bool;
    allow_primitives_from_empty_stubs: bool;
    expression: Expression.t;
  }
  [@@deriving compare, sexp, hash]

  include Hashable.Make (struct
    type nonrec t = t

    let compare = compare

    let hash = Hashtbl.hash

    let hash_fold_t = hash_fold_t

    let sexp_of_t = sexp_of_t

    let t_of_sexp = t_of_sexp
  end)

  let cache = Table.create ~size:1023 ()

  let clear ~scheduler ~configuration =
    (* We need to clear the cache in each of the workers :( *)
    Scheduler.once_per_worker scheduler ~configuration ~f:(fun () -> Hashtbl.clear cache);
    Hashtbl.clear cache
end

let parse_annotation
    ?(allow_untracked = false)
    ?(allow_invalid_type_parameters = false)
    ?(allow_primitives_from_empty_stubs = false)
    ({ dependency; _ } as resolution)
    expression
  =
  let key =
    {
      AnnotationCache.allow_untracked;
      allow_invalid_type_parameters;
      allow_primitives_from_empty_stubs;
      expression;
    }
  in
  match Hashtbl.find AnnotationCache.cache key with
  | Some result -> result
  | None ->
      let modify_aliases = function
        | Type.TypeAlias alias ->
            check_invalid_type_parameters resolution alias
            |> snd
            |> fun alias -> Type.TypeAlias alias
        | result -> result
      in
      let annotation =
        AliasEnvironment.ReadOnly.parse_annotation_without_validating_type_parameters
          (alias_environment resolution)
          ~modify_aliases
          ?dependency
          ~allow_untracked
          ~allow_primitives_from_empty_stubs
          expression
      in
      let result =
        if not allow_invalid_type_parameters then
          check_invalid_type_parameters resolution annotation |> snd
        else
          annotation
      in
      Hashtbl.set ~key ~data:result AnnotationCache.cache;
      result


let join resolution = full_order resolution |> TypeOrder.join

let meet resolution = full_order resolution |> TypeOrder.meet

let widen resolution = full_order resolution |> TypeOrder.widen

(* In general, python expressions can be self-referential. This resolution only checks literals and
   annotations found in the resolution map, without resolving expressions. *)
let rec resolve_literal ({ class_definition; _ } as resolution) expression =
  let open Ast.Expression in
  let is_concrete_constructable class_type =
    primitive_name class_type
    >>= class_definition
    >>| (fun { Node.value = { name; _ }; _ } -> Reference.show name)
    >>= variables ~default:(Some (ClassHierarchy.Unaries [])) resolution
    >>| ClassHierarchy.equal_variables (ClassHierarchy.Unaries [])
    |> Option.value ~default:false
  in
  match Node.value expression with
  | Await expression ->
      resolve_literal resolution expression
      |> Type.awaitable_value
      |> Option.value ~default:Type.Top
  | BooleanOperator { BooleanOperator.left; right; _ } ->
      let annotation =
        join resolution (resolve_literal resolution left) (resolve_literal resolution right)
      in
      if Type.is_concrete annotation then annotation else Type.Any
  | Call { callee = { Node.value = Name name; _ } as callee; _ }
    when Expression.is_simple_name name ->
      let class_type = parse_annotation resolution callee in
      if is_concrete_constructable class_type then
        class_type
      else
        Type.Top
  | Call _
  | Name _
    when Expression.has_identifier_base expression ->
      let class_type = parse_annotation resolution expression in
      (* None is a special type that doesn't have a constructor. *)
      if Type.is_none class_type then
        Type.none
      else if is_concrete_constructable class_type then
        Type.meta class_type
      else
        Type.Top
  | Complex _ -> Type.complex
  | Dictionary { Dictionary.entries; keywords = [] } ->
      let key_annotation, value_annotation =
        let join_entry (key_annotation, value_annotation) { Dictionary.key; value } =
          ( join resolution key_annotation (resolve_literal resolution key),
            join resolution value_annotation (resolve_literal resolution value) )
        in
        List.fold ~init:(Type.Bottom, Type.Bottom) ~f:join_entry entries
      in
      if Type.is_concrete key_annotation && Type.is_concrete value_annotation then
        Type.dictionary ~key:key_annotation ~value:value_annotation
      else
        Type.Any
  | False -> Type.bool
  | Float _ -> Type.float
  | Integer _ -> Type.integer
  | List elements ->
      let parameter =
        let join sofar element = join resolution sofar (resolve_literal resolution element) in
        List.fold ~init:Type.Bottom ~f:join elements
      in
      if Type.is_concrete parameter then Type.list parameter else Type.Any
  | Set elements ->
      let parameter =
        let join sofar element = join resolution sofar (resolve_literal resolution element) in
        List.fold ~init:Type.Bottom ~f:join elements
      in
      if Type.is_concrete parameter then Type.set parameter else Type.Any
  | String { StringLiteral.kind; _ } -> (
    match kind with
    | StringLiteral.Bytes -> Type.bytes
    | _ -> Type.string )
  | Ternary { Ternary.target; alternative; _ } ->
      let annotation =
        join
          resolution
          (resolve_literal resolution target)
          (resolve_literal resolution alternative)
      in
      if Type.is_concrete annotation then annotation else Type.Any
  | True -> Type.bool
  | Tuple elements -> Type.tuple (List.map elements ~f:(resolve_literal resolution))
  | Expression.Yield _ -> Type.yield Type.Any
  | _ -> Type.Any


let undecorated_signature { undecorated_signature; _ } = undecorated_signature

let aliases { aliases; _ } = aliases

let module_definition { module_definition; _ } = module_definition

module FunctionDefinitionsCache = struct
  let cache = Reference.Table.create ()

  let enabled =
    (* Only enable this in nonincremental mode for now. *)
    ref false


  let enable () = enabled := true

  let set key value = Hashtbl.set cache ~key ~data:value

  let get key =
    if !enabled then
      Hashtbl.find cache key
    else
      None


  let invalidate () = Hashtbl.clear cache
end

let containing_source resolution reference =
  let ast_environment = ast_environment resolution in
  let rec qualifier ~lead ~tail =
    match tail with
    | head :: tail ->
        let new_lead = Reference.create ~prefix:lead head in
        if Option.is_none (module_definition resolution new_lead) then
          lead
        else
          qualifier ~lead:new_lead ~tail
    | _ -> lead
  in
  qualifier ~lead:Reference.empty ~tail:(Reference.as_list reference)
  |> AstEnvironment.ReadOnly.get_source ast_environment


let function_definitions resolution reference =
  match FunctionDefinitionsCache.get reference with
  | Some result -> result
  | None ->
      let result =
        containing_source resolution reference
        >>| Preprocessing.defines ~include_stubs:true ~include_nested:true
        >>| List.filter ~f:(fun { Node.value = { Define.signature = { name; _ }; _ }; _ } ->
                Reference.equal reference name)
      in
      FunctionDefinitionsCache.set reference result;
      result


let class_definitions resolution reference =
  containing_source resolution reference
  >>| Preprocessing.classes
  >>| List.filter ~f:(fun { Node.value = { Class.name; _ }; _ } -> Reference.equal reference name)


let is_suppressed_module resolution reference =
  AstEnvironment.ReadOnly.from_empty_stub (ast_environment resolution) reference


let solve_less_or_equal resolution ~constraints ~left ~right =
  full_order resolution |> TypeOrder.solve_less_or_equal ~constraints ~left ~right


let constraints_solution_exists ~left ~right resolution =
  not
    ( solve_less_or_equal resolution ~left ~right ~constraints:TypeConstraints.empty
    |> List.filter_map ~f:(TypeOrder.OrderedConstraints.solve ~order:(full_order resolution))
    |> List.is_empty )


let solve_constraints resolution =
  let order = full_order resolution in
  TypeOrder.OrderedConstraints.solve ~order


let partial_solve_constraints resolution =
  TypeOrder.OrderedConstraints.extract_partial_solution ~order:(full_order resolution)


let less_or_equal resolution = full_order resolution |> TypeOrder.always_less_or_equal

let is_compatible_with resolution = full_order resolution |> TypeOrder.is_compatible_with

let is_instantiated { class_hierarchy; _ } = ClassHierarchy.is_instantiated class_hierarchy

let parse_reference ?(allow_untracked = false) resolution reference =
  Expression.from_reference ~location:Location.Reference.any reference
  |> parse_annotation ~allow_untracked ~allow_invalid_type_parameters:true resolution


let parse_as_list_variadic ({ aliases; _ } as resolution) name =
  let parsed_as_type_variable =
    parse_annotation resolution name ~allow_untracked:true |> Type.primitive_name >>= aliases
  in
  match parsed_as_type_variable with
  | Some (VariableAlias (ListVariadic variable)) -> Some variable
  | _ -> None


let parse_as_concatenation ({ dependency; _ } as resolution) =
  AliasEnvironment.ReadOnly.parse_as_concatenation (alias_environment resolution) ?dependency


let parse_as_parameter_specification_instance_annotation ({ dependency; _ } as resolution) =
  AliasEnvironment.ReadOnly.parse_as_parameter_specification_instance_annotation
    (alias_environment resolution)
    ?dependency


let is_invariance_mismatch ({ class_hierarchy; _ } as resolution) ~left ~right =
  match left, right with
  | ( Type.Parametric { name = left_name; parameters = left_parameters },
      Type.Parametric { name = right_name; parameters = right_parameters } )
    when Identifier.equal left_name right_name ->
      let zipped =
        match
          ClassHierarchy.variables class_hierarchy left_name, left_parameters, right_parameters
        with
        | Some (Unaries variables), Concrete left_parameters, Concrete right_parameters -> (
            List.map3
              variables
              left_parameters
              right_parameters
              ~f:(fun { variance; _ } left right -> variance, left, right)
            |> function
            | List.Or_unequal_lengths.Ok list -> Some list
            | _ -> None )
        | Some (Concatenation _), _, _ ->
            (* TODO(T47346673): Do this check when list variadics have variance *)
            None
        | _ -> None
      in
      let due_to_invariant_variable (variance, left, right) =
        match variance with
        | Type.Variable.Invariant -> less_or_equal resolution ~left ~right
        | _ -> false
      in
      zipped >>| List.exists ~f:due_to_invariant_variable |> Option.value ~default:false
  | _ -> false


let resolve_exports resolution ~reference =
  (* Resolve exports. Fixpoint is necessary due to export/module name conflicts: P59503092 *)
  let widening_threshold = 25 in
  let rec resolve_exports_fixpoint ~reference ~visited ~count =
    if Set.mem visited reference || count > widening_threshold then
      reference
    else
      let rec resolve_exports ~lead ~tail =
        match tail with
        | head :: tail ->
            module_definition resolution (Reference.create_from_list lead)
            >>| (fun definition ->
                  match Module.aliased_export definition (Reference.create head) with
                  | Some export -> Reference.combine export (Reference.create_from_list tail)
                  | _ -> resolve_exports ~lead:(lead @ [head]) ~tail)
            |> Option.value ~default:reference
        | _ -> reference
      in
      match Reference.as_list reference with
      | head :: tail ->
          let exported_reference = resolve_exports ~lead:[head] ~tail in
          if Reference.is_strict_prefix ~prefix:reference exported_reference then
            reference
          else
            resolve_exports_fixpoint
              ~reference:exported_reference
              ~visited:(Set.add visited reference)
              ~count:(count + 1)
      | _ -> reference
  in
  resolve_exports_fixpoint ~reference ~visited:Reference.Set.empty ~count:0


let solve_ordered_types_less_or_equal resolution =
  TypeOrder.solve_ordered_types_less_or_equal (full_order resolution)


(* There isn't a great way of testing whether a file only contains tests in Python. Due to the
   difficulty of handling nested classes within test cases, etc., we use the heuristic that a class
   which inherits from unittest.TestCase indicates that the entire file is a test file. *)
let source_is_unit_test resolution ~source =
  let is_unittest { Node.value = { Class.name; _ }; _ } =
    let annotation = parse_reference resolution name in
    less_or_equal resolution ~left:annotation ~right:(Type.Primitive "unittest.case.TestCase")
  in
  List.exists (Preprocessing.classes source) ~f:is_unittest


let class_extends_placeholder_stub_class resolution { ClassSummary.bases; _ } =
  let is_from_placeholder_stub { Expression.Call.Argument.value; _ } =
    let parsed =
      parse_annotation
        ~allow_untracked:true
        ~allow_invalid_type_parameters:true
        ~allow_primitives_from_empty_stubs:true
        resolution
        value
    in
    match parsed with
    | Type.Primitive primitive
    | Parametric { name = primitive; _ } ->
        Reference.create primitive
        |> fun reference ->
        AstEnvironment.ReadOnly.from_empty_stub (ast_environment resolution) reference
    | _ -> false
  in
  List.exists bases ~f:is_from_placeholder_stub


let global { global; _ } reference =
  (* TODO (T41143153): We might want to properly support this by unifying attribute lookup logic
     for module and for class *)
  match Reference.last reference with
  | "__doc__"
  | "__file__"
  | "__name__" ->
      let annotation =
        Annotation.create_immutable ~global:true Type.string |> Node.create_with_default_location
      in
      Some annotation
  | "__dict__" ->
      let annotation =
        Type.dictionary ~key:Type.string ~value:Type.Any
        |> Annotation.create_immutable ~global:true
        |> Node.create_with_default_location
      in
      Some annotation
  | _ -> global reference


let class_hierarchy { class_hierarchy; _ } = class_hierarchy

let attribute ({ attribute; _ } as resolution) = attribute ~resolution

let annotation_parser resolution =
  {
    AnnotatedCallable.parse_annotation = parse_annotation resolution;
    parse_as_concatenation = parse_as_concatenation resolution;
    parse_as_parameter_specification_instance_annotation =
      parse_as_parameter_specification_instance_annotation resolution;
  }


let check_class_hierarchy_integrity ({ class_hierarchy_environment; _ } as resolution) =
  let indices =
    class_hierarchy_environment
    |> ClassHierarchyEnvironment.ReadOnly.alias_environment
    |> AliasEnvironment.ReadOnly.unannotated_global_environment
    |> UnannotatedGlobalEnvironment.ReadOnly.all_indices
  in
  class_hierarchy resolution |> ClassHierarchy.check_integrity ~indices
