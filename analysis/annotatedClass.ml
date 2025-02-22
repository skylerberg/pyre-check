(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open Ast
open Expression
open Pyre
open Statement
module StatementAttribute = Attribute
module Callable = AnnotatedCallable
module Attribute = AnnotatedAttribute

type t = ClassSummary.t Node.t [@@deriving compare, eq, sexp, show, hash]

type decorator = {
  name: string;
  arguments: Expression.Call.Argument.t list option;
}
[@@deriving compare, eq, sexp, show, hash]

module AttributeCache = struct
  type t = {
    transitive: bool;
    class_attributes: bool;
    include_generated_attributes: bool;
    special_method: bool;
    name: Reference.t;
    instantiated: Type.t option;
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

  let cache : AnnotatedAttribute.Table.t Table.t = Table.create ~size:1023 ()

  let clear () = Table.clear cache
end

type class_data = {
  instantiated: Type.t;
  class_attributes: bool;
  class_definition: t;
}

let name_equal
    { Node.value = { ClassSummary.name = left; _ }; _ }
    { Node.value = { ClassSummary.name = right; _ }; _ }
  =
  Reference.equal left right


let create definition = definition

let name { Node.value = { ClassSummary.name; _ }; _ } = name

let bases { Node.value = { ClassSummary.bases; _ }; _ } = bases

let matches_decorator decorator ~target ~resolution =
  let name_resolves_to_target ~name =
    let name =
      GlobalResolution.resolve_exports resolution ~reference:(Reference.create name)
      |> Reference.show
    in
    String.equal name target
  in
  match decorator with
  | { Node.value = Call { callee; arguments }; _ }
    when name_resolves_to_target ~name:(Expression.show callee) ->
      Some { name = target; arguments = Some arguments }
  | { Node.value = Name _; _ } when name_resolves_to_target ~name:(Expression.show decorator) ->
      Some { name = target; arguments = None }
  | _ -> None


let get_decorator { Node.value = { ClassSummary.decorators; _ }; _ } ~resolution ~decorator =
  List.filter_map ~f:(matches_decorator ~target:decorator ~resolution) decorators


let annotation { Node.value = { ClassSummary.name; _ }; _ } = Type.Primitive (Reference.show name)

let successors { Node.value = { ClassSummary.name; _ }; _ } ~resolution =
  Type.Primitive (Reference.show name)
  |> GlobalResolution.class_metadata resolution
  >>| (fun { ClassMetadataEnvironment.successors; _ } -> successors)
  |> Option.value ~default:[]


let successors_fold class_node ~resolution ~f ~initial =
  successors class_node ~resolution |> List.fold ~init:initial ~f


let is_unit_test { Node.value; _ } = ClassSummary.is_unit_test value

let resolve_class ~resolution annotation =
  let rec extract ~is_meta original_annotation =
    let annotation =
      match original_annotation with
      | Type.Variable variable -> Type.Variable.Unary.upper_bound variable
      | _ -> original_annotation
    in
    match annotation with
    | Type.Top
    | Type.Bottom
    | Type.Any ->
        Some []
    | Type.Union annotations ->
        let flatten_optional sofar optional =
          match sofar, optional with
          | Some sofar, Some optional -> Some (optional :: sofar)
          | _ -> None
        in
        List.map ~f:(extract ~is_meta) annotations
        |> List.fold ~init:(Some []) ~f:flatten_optional
        >>| List.concat
        >>| List.rev
    | annotation when Type.is_meta annotation ->
        Type.single_parameter annotation |> extract ~is_meta:true
    | _ -> (
      match GlobalResolution.class_definition resolution annotation with
      | Some class_definition ->
          Some
            [
              {
                instantiated = original_annotation;
                class_attributes = is_meta;
                class_definition = create class_definition;
              };
            ]
      | None -> None )
  in
  extract ~is_meta:false annotation


let generics { Node.value = { ClassSummary.bases; _ }; _ } ~resolution =
  let parse_annotation =
    GlobalResolution.parse_annotation ~allow_invalid_type_parameters:true resolution
  in
  let generic { Expression.Call.Argument.value; _ } =
    match parse_annotation value with
    | Type.Parametric { name = "typing.Generic"; parameters } -> Some parameters
    | Type.Parametric { name = "typing.Protocol"; parameters } -> Some parameters
    | _ -> None
  in
  match List.find_map ~f:generic bases with
  | None -> AnnotatedBases.find_propagated_type_variables bases ~parse_annotation
  | Some parameters -> parameters


let constraints ?target ?parameters definition ~instantiated ~resolution =
  let target = Option.value ~default:definition target in
  let parameters =
    match parameters with
    | None -> generics ~resolution target
    | Some parameters -> parameters
  in
  let right =
    let target = annotation target in
    match target with
    | Primitive name -> Type.parametric name parameters
    | _ -> target
  in
  match instantiated, right with
  | Type.Primitive name, Parametric { name = right_name; _ } when String.equal name right_name ->
      (* TODO(T42259381) This special case is only necessary because constructor calls attributes
         with an "instantiated" type of a bare parametric, which will fill with Anys *)
      TypeConstraints.Solution.empty
  | _ ->
      GlobalResolution.solve_less_or_equal
        resolution
        ~constraints:TypeConstraints.empty
        ~left:instantiated
        ~right
      |> List.filter_map ~f:(GlobalResolution.solve_constraints resolution)
      |> List.hd
      (* TODO(T39598018): error in this case somehow, something must be wrong *)
      |> Option.value ~default:TypeConstraints.Solution.empty


let superclasses definition ~resolution =
  successors ~resolution definition
  |> List.filter_map ~f:(fun name ->
         GlobalResolution.class_definition resolution (Type.Primitive name))
  |> List.map ~f:create


let rec metaclass ({ Node.value = { ClassSummary.bases; _ }; _ } as original) ~resolution =
  (* See https://docs.python.org/3/reference/datamodel.html#determining-the-appropriate-metaclass
     for why we need to consider all metaclasses. *)
  let metaclass_candidates =
    let explicit_metaclass =
      let find_explicit_metaclass = function
        | { Expression.Call.Argument.name = Some { Node.value = "metaclass"; _ }; value } ->
            Some (GlobalResolution.parse_annotation resolution value)
        | _ -> None
      in
      List.find_map ~f:find_explicit_metaclass bases
    in
    let metaclass_of_bases =
      let explicit_bases =
        let base_to_class { Call.Argument.value; _ } =
          Expression.delocalize value
          |> GlobalResolution.parse_annotation resolution
          |> Type.split
          |> fst
        in
        List.filter
          ~f:(function
            | { Expression.Call.Argument.name = None; _ } -> true
            | _ -> false)
          bases
        |> List.map ~f:base_to_class
        |> List.filter_map ~f:(GlobalResolution.class_definition resolution)
        |> List.filter ~f:(fun base_class -> not (equal base_class original))
      in
      let filter_generic_meta base_metaclasses =
        (* We only want a class directly inheriting from Generic to have a metaclass of
           GenericMeta. *)
        if
          List.exists
            ~f:(fun base -> Reference.equal (Reference.create "typing.Generic") (name base))
            explicit_bases
        then
          base_metaclasses
        else
          List.filter
            ~f:(fun metaclass -> not (Type.equal (Type.Primitive "typing.GenericMeta") metaclass))
            base_metaclasses
      in
      explicit_bases |> List.map ~f:(metaclass ~resolution) |> filter_generic_meta
    in
    match explicit_metaclass with
    | Some metaclass -> metaclass :: metaclass_of_bases
    | None -> metaclass_of_bases
  in
  match metaclass_candidates with
  | [] -> Type.Primitive "type"
  | first :: candidates -> (
      let candidate = List.fold candidates ~init:first ~f:(GlobalResolution.meet resolution) in
      match candidate with
      | Type.Bottom ->
          (* If we get Bottom here, we don't have a "most derived metaclass", so default to one. *)
          first
      | _ -> candidate )


let is_protocol { Node.value; _ } = ClassSummary.is_protocol value

let create_attribute
    ~resolution
    ~parent
    ?instantiated
    ?(defined = true)
    ?(inherited = false)
    ?(default_class_attribute = false)
    { Node.location; value = { StatementAttribute.name = attribute_name; kind } }
  =
  let class_annotation = annotation parent in
  let annotation, value, class_attribute, final =
    match kind with
    | Simple { annotation; value; frozen = _; toplevel; implicit; primitive } ->
        let parsed_annotation = annotation >>| GlobalResolution.parse_annotation resolution in
        (* Account for class attributes. *)
        let annotation, class_attribute =
          parsed_annotation
          >>| (fun annotation ->
                let annotation_value =
                  if Type.is_final annotation then
                    Type.final_value annotation
                  else
                    Type.class_variable_value annotation
                in
                match annotation_value with
                | Some annotation -> Some annotation, true
                | _ -> Some annotation, false)
          |> Option.value ~default:(None, default_class_attribute)
        in
        (* Handle enumeration attributes. *)
        let annotation, value, class_attribute =
          let superclasses =
            superclasses ~resolution parent
            |> List.map ~f:(fun definition -> name definition |> Reference.show)
            |> String.Set.of_list
          in
          if
            (not (Set.mem Recognized.enumeration_classes (Type.show class_annotation)))
            && (not (Set.is_empty (Set.inter Recognized.enumeration_classes superclasses)))
            && (not inherited)
            && primitive
            && defined
            && not implicit
          then
            Some class_annotation, None, true (* Enums override values. *)
          else
            annotation, value, class_attribute
        in
        let final = parsed_annotation >>| Type.is_final |> Option.value ~default:false in
        let annotation =
          match annotation, value with
          | Some annotation, Some _ ->
              Annotation.create_immutable
                ~global:true
                ~final
                ~original:(Some annotation)
                annotation
          | Some annotation, None -> Annotation.create_immutable ~global:true ~final annotation
          | None, Some value ->
              let literal_value_annotation = GlobalResolution.resolve_literal resolution value in
              let is_dataclass_attribute =
                let get_dataclass_decorator annotated =
                  get_decorator annotated ~resolution ~decorator:"dataclasses.dataclass"
                  @ get_decorator annotated ~resolution ~decorator:"dataclass"
                in
                not (List.is_empty (get_dataclass_decorator parent))
              in
              if
                (not (Type.is_partially_typed literal_value_annotation))
                && (not is_dataclass_attribute)
                && toplevel
              then (* Treat literal attributes as having been explicitly annotated. *)
                Annotation.create_immutable ~global:true ~final literal_value_annotation
              else
                Annotation.create_immutable
                  ~global:true
                  ~final
                  ~original:(Some Type.Top)
                  (GlobalResolution.parse_annotation resolution value)
          | _ -> Annotation.create_immutable ~global:true ~final Type.Top
        in
        annotation, value, class_attribute, final
    | Method { signatures; static = _; final } ->
        (* Handle Callables *)
        let annotation =
          let instantiated =
            match instantiated with
            | Some instantiated -> instantiated
            | None -> class_annotation
          in
          match signatures with
          | ({ Define.Signature.name; _ } as define) :: _ as defines ->
              let parent =
                (* TODO(T45029821): __new__ is special cased to be a static method. It doesn't play
                   well with our logic here - we should clean up the call logic to handle passing
                   the extra argument, and eliminate the special fields from here. *)
                if
                  Define.Signature.is_static_method define
                  && not (String.equal (Define.Signature.unqualified_name define) "__new__")
                then
                  None
                else if Define.Signature.is_class_method define then
                  Some (Type.meta instantiated)
                else if default_class_attribute then
                  (* Keep first argument around when calling instance methods from class
                     attributes. *)
                  None
                else
                  Some instantiated
              in
              let apply_decorators define =
                ( Define.Signature.is_overloaded_method define,
                  ResolvedCallable.apply_decorators ~resolution (Node.create define ~location) )
              in
              List.map defines ~f:apply_decorators
              |> ResolvedCallable.create_callable ~resolution ~parent ~name:(Reference.show name)
              |> fun callable -> Some (Type.Callable callable)
          | [] -> failwith "impossible"
        in
        (* Special cases *)
        let annotation =
          match instantiated, attribute_name, annotation with
          | ( Some (Type.TypedDictionary { fields; total; _ }),
              method_name,
              Some (Type.Callable callable) ) ->
              Type.TypedDictionary.special_overloads ~fields ~method_name ~total
              >>| (fun overloads ->
                    Some
                      (Type.Callable
                         {
                           callable with
                           implementation =
                             {
                               annotation = Type.Top;
                               parameters = Undefined;
                               define_location = None;
                             };
                           overloads;
                         }))
              |> Option.value ~default:annotation
          | ( Some (Type.Tuple (Bounded (Concrete members))),
              "__getitem__",
              Some (Type.Callable ({ overloads; _ } as callable)) ) ->
              let overload index member =
                {
                  Type.Callable.annotation = member;
                  parameters =
                    Defined
                      [
                        Named
                          { name = "x"; annotation = Type.literal_integer index; default = false };
                      ];
                  define_location = None;
                }
              in
              let overloads = List.mapi ~f:overload members @ overloads in
              Some (Type.Callable { callable with overloads })
          | ( Some (Parametric { name = "type"; parameters = Concrete [Type.Primitive name] }),
              "__getitem__",
              Some (Type.Callable ({ kind = Named callable_name; _ } as callable)) )
            when String.equal (Reference.show callable_name) "typing.GenericMeta.__getitem__" ->
              let implementation =
                let generics =
                  GlobalResolution.class_definition resolution (Type.Primitive name)
                  >>| create
                  >>| generics ~resolution
                  |> Option.value ~default:(Type.OrderedTypes.Concrete [])
                in
                match generics with
                | Concrete generics ->
                    let parameters =
                      let create_parameter annotation =
                        Type.Callable.Parameter.Anonymous
                          { index = 0; annotation; default = false }
                      in
                      match generics with
                      | [] -> []
                      | [generic] -> [create_parameter (Type.meta generic)]
                      | generics ->
                          [create_parameter (Type.tuple (List.map ~f:Type.meta generics))]
                    in
                    {
                      Type.Callable.annotation =
                        Type.meta (Type.Parametric { name; parameters = Concrete generics });
                      parameters = Defined parameters;
                      define_location = None;
                    }
                | _ ->
                    (* TODO(T47347970): make this a *args: Ts -> X[Ts] for that case, and ignore
                       the others *)
                    {
                      Type.Callable.annotation =
                        Type.meta (Type.Parametric { name; parameters = generics });
                      parameters = Undefined;
                      define_location = None;
                    }
              in
              Some (Type.Callable { callable with implementation; overloads = [] })
          | _ -> annotation
        in
        let annotation =
          match annotation with
          | Some annotation -> Annotation.create_immutable ~global:true ~final annotation
          | None -> Annotation.create_immutable ~global:true ~final Type.Top
        in
        annotation, None, default_class_attribute, final
    | Property { kind; class_property; _ } ->
        let annotation =
          match kind with
          | ReadWrite { setter_annotation; getter_annotation } ->
              let current =
                getter_annotation
                >>| GlobalResolution.parse_annotation resolution
                |> Option.value ~default:Type.Top
              in
              let original =
                setter_annotation
                >>| GlobalResolution.parse_annotation resolution
                |> Option.value ~default:Type.Top
                |> Option.some
              in
              Annotation.create_immutable ~global:true ~final:false ~original current
          | ReadOnly { getter_annotation } ->
              getter_annotation
              >>| GlobalResolution.parse_annotation resolution
              |> Option.value ~default:Type.Top
              |> Annotation.create_immutable ~global:true ~final:false
        in
        (* Special case properties with type variables. *)
        (* TODO(T44676629): handle this correctly *)
        let annotation =
          let free_variables =
            let variables =
              Annotation.annotation annotation
              |> Type.Variable.all_free_variables
              |> List.filter_map ~f:(function
                     | Type.Variable.Unary variable -> Some (Type.Variable variable)
                     | _ -> None)
              |> Type.Set.of_list
            in
            let generics =
              match generics parent ~resolution with
              | Concrete generics -> Type.Set.of_list generics
              | _ ->
                  (* TODO(T44676629): This case should be handled when we re-do this handling *)
                  Type.Set.empty
            in
            Set.diff variables generics |> Set.to_list
          in
          if not (List.is_empty free_variables) then
            let constraints =
              let instantiated = Option.value instantiated ~default:class_annotation in
              List.fold free_variables ~init:Type.Map.empty ~f:(fun map variable ->
                  Map.set map ~key:variable ~data:instantiated)
              |> Map.find
            in
            Annotation.annotation annotation
            |> Type.instantiate ~constraints
            |> Annotation.create_immutable ~global:true ~final:false
          else
            annotation
        in
        annotation, None, class_property, false
  in
  {
    Node.location;
    value =
      {
        (* We need to distinguish between unannotated attributes and non-existent ones - ensure
           that the annotation is viewed as mutable to distinguish from user-defined globals. *)
        AnnotatedAttribute.annotation =
          ( if not defined then
              { annotation with Annotation.mutability = Annotation.Mutable }
          else
            annotation );
        abstract =
          ( match kind with
          | Method { signatures; _ } ->
              List.exists signatures ~f:Define.Signature.is_abstract_method
          | _ -> false );
        async =
          ( match kind with
          | Property { async; _ } -> async
          | _ -> false );
        class_attribute;
        defined;
        initialized =
          ( match kind with
          | Simple { value = Some { Node.value = Ellipsis; _ }; _ }
          | Simple { value = None; _ } ->
              false
          | Simple { value = Some _; _ }
          | Method _
          | Property _ ->
              true );
        final;
        name = attribute_name;
        parent = class_annotation;
        property =
          ( match kind with
          | Property { kind = ReadWrite _; _ } -> Some AnnotatedAttribute.ReadWrite
          | Property { kind = ReadOnly _; _ } -> Some AnnotatedAttribute.ReadOnly
          | Simple { frozen; _ } when frozen -> Some AnnotatedAttribute.ReadOnly
          | _ -> None );
        static =
          ( match kind with
          | Method { static; _ } -> static
          | _ -> false );
        value = Option.value value ~default:(Node.create Ellipsis ~location);
      };
  }


let implicit_attributes { Node.value = { ClassSummary.attribute_components; _ }; _ } =
  Class.implicit_attributes attribute_components


module ClassDecorators = struct
  type options = {
    init: bool;
    repr: bool;
    eq: bool;
    order: bool;
  }

  let extract_options
      ~resolution
      ~names
      ~default
      ~init
      ~repr
      ~eq
      ~order
      { Node.value = { ClassSummary.decorators; _ }; _ }
    =
    let get_decorators ~names =
      let get_decorator decorator =
        List.filter_map ~f:(matches_decorator ~target:decorator ~resolution) decorators
      in
      names |> List.map ~f:get_decorator |> List.concat
    in
    let extract_options_from_arguments =
      let apply_arguments default argument =
        let recognize_value ~default = function
          | False -> false
          | True -> true
          | _ -> default
        in
        match argument with
        | {
         Expression.Call.Argument.name = Some { Node.value = argument_name; _ };
         value = { Node.value; _ };
        } ->
            let argument_name = Identifier.sanitized argument_name in
            (* We need to check each keyword sequentially because different keywords may correspond
               to the same string. *)
            let default =
              if String.equal argument_name init then
                { default with init = recognize_value value ~default:default.init }
              else
                default
            in
            let default =
              if String.equal argument_name repr then
                { default with repr = recognize_value value ~default:default.repr }
              else
                default
            in
            let default =
              if String.equal argument_name eq then
                { default with eq = recognize_value value ~default:default.eq }
              else
                default
            in
            let default =
              if String.equal argument_name order then
                { default with order = recognize_value value ~default:default.order }
              else
                default
            in
            default
        | _ -> default
      in
      List.fold ~init:default ~f:apply_arguments
    in
    match get_decorators ~names with
    | [] -> None
    | { arguments = Some arguments; _ } :: _ -> Some (extract_options_from_arguments arguments)
    | _ -> Some default


  let dataclass_options =
    extract_options
      ~names:["dataclasses.dataclass"; "dataclass"]
      ~default:{ init = true; repr = true; eq = true; order = false }
      ~init:"init"
      ~repr:"repr"
      ~eq:"eq"
      ~order:"order"


  let attrs_attributes =
    extract_options
      ~names:["attr.s"; "attr.attrs"]
      ~default:{ init = true; repr = true; eq = true; order = true }
      ~init:"init"
      ~repr:"repr"
      ~eq:"cmp"
      ~order:"cmp"


  let apply ~definition ~resolution ~class_attributes ~get_table table =
    let parent_dataclasses = superclasses definition ~resolution in
    let name = name definition in
    let generate_attributes ~options =
      let already_in_table name =
        AnnotatedAttribute.Table.lookup_name table name |> Option.is_some
      in
      let make_callable ~parameters ~annotation ~attribute_name =
        let parameters =
          if class_attributes then
            { Type.Callable.Parameter.name = "self"; annotation = Type.Top; default = false }
            :: parameters
          else
            parameters
        in
        ( attribute_name,
          Type.Callable.create
            ~implicit:
              { implicit_annotation = Primitive (Reference.show name); name = "$parameter$self" }
            ~name:(Reference.combine name (Reference.create attribute_name))
            ~parameters:(Defined (Type.Callable.Parameter.create parameters))
            ~annotation
            () )
      in
      match options definition with
      | None -> []
      | Some { init; repr; eq; order } ->
          let generated_methods =
            let methods =
              if init && not (already_in_table "__init__") then
                let parameters =
                  let extract_dataclass_field_arguments
                      { Node.value = { AnnotatedAttribute.value; _ }; _ }
                    =
                    match value with
                    | {
                     Node.value =
                       Expression.Call
                         {
                           callee =
                             {
                               Node.value =
                                 Expression.Name
                                   (Name.Attribute
                                     {
                                       base =
                                         {
                                           Node.value =
                                             Expression.Name (Name.Identifier "dataclasses");
                                           _;
                                         };
                                       attribute = "field";
                                       _;
                                     });
                               _;
                             };
                           arguments;
                           _;
                         };
                     _;
                    } ->
                        Some arguments
                    | _ -> None
                  in
                  let init_not_disabled attribute =
                    let is_disable_init { Call.Argument.name; value = { Node.value; _ } } =
                      match name, value with
                      | Some { Node.value = parameter_name; _ }, Expression.False
                        when String.equal "init" (Identifier.sanitized parameter_name) ->
                          true
                      | _ -> false
                    in
                    match extract_dataclass_field_arguments attribute with
                    | Some arguments -> not (List.exists arguments ~f:is_disable_init)
                    | _ -> true
                  in
                  let extract_init_value
                      ( { Node.value = { AnnotatedAttribute.initialized; value; _ }; _ } as
                      attribute )
                    =
                    let get_default_value { Call.Argument.name; value } : expression_t option =
                      match name with
                      | Some { Node.value = parameter_name; _ } ->
                          if String.equal "default" (Identifier.sanitized parameter_name) then
                            Some value
                          else if
                            String.equal "default_factory" (Identifier.sanitized parameter_name)
                          then
                            let { Node.location; _ } = value in
                            Some
                              {
                                Node.value =
                                  Expression.Call { Call.callee = value; arguments = [] };
                                location;
                              }
                          else
                            None
                      | _ -> None
                    in
                    match initialized with
                    | false -> None
                    | true -> (
                      match extract_dataclass_field_arguments attribute with
                      | Some arguments -> List.find_map arguments ~f:get_default_value
                      | _ -> Some value )
                  in
                  let collect_parameters parameters attribute =
                    (* Parameters must be annotated attributes *)
                    let annotation =
                      AnnotatedAttribute.annotation attribute
                      |> Annotation.original
                      |> function
                      | Type.Parametric
                          {
                            name = "dataclasses.InitVar";
                            parameters = Concrete [single_parameter];
                          } ->
                          single_parameter
                      | annotation -> annotation
                    in
                    match AnnotatedAttribute.name attribute with
                    | name when not (Type.is_unknown annotation) ->
                        let name = "$parameter$" ^ name in
                        let value = extract_init_value attribute in
                        let rec override_existing_parameters unchecked_parameters =
                          match unchecked_parameters with
                          | [] ->
                              [
                                {
                                  Type.Callable.Parameter.name;
                                  annotation;
                                  default = Option.is_some value;
                                };
                              ]
                          | { Type.Callable.Parameter.name = old_name; default = old_default; _ }
                            :: tail
                            when Identifier.equal old_name name ->
                              { name; annotation; default = Option.is_some value || old_default }
                              :: tail
                          | head :: tail -> head :: override_existing_parameters tail
                        in
                        override_existing_parameters parameters
                    | _ -> parameters
                  in
                  let parent_attribute_tables =
                    parent_dataclasses
                    |> List.filter ~f:(fun definition -> options definition |> Option.is_some)
                    |> List.rev
                    |> List.map ~f:get_table
                  in
                  let parent_attributes parent =
                    let compare_by_location left right =
                      Ast.Location.compare (Node.location left) (Node.location right)
                    in
                    AnnotatedAttribute.Table.to_list parent
                    |> List.sort ~compare:compare_by_location
                  in
                  parent_attribute_tables @ [get_table definition]
                  |> List.map ~f:parent_attributes
                  |> List.map ~f:(List.filter ~f:init_not_disabled)
                  |> List.fold ~init:[] ~f:(fun parameters ->
                         List.fold ~init:parameters ~f:collect_parameters)
                in
                [make_callable ~parameters ~annotation:Type.none ~attribute_name:"__init__"]
              else
                []
            in
            let methods =
              if repr && not (already_in_table "__repr__") then
                let new_method =
                  make_callable ~parameters:[] ~annotation:Type.string ~attribute_name:"__repr__"
                in
                new_method :: methods
              else
                methods
            in
            let add_order_method methods name =
              let annotation = Type.object_primitive in
              if not (already_in_table name) then
                make_callable
                  ~parameters:[{ name = "$parameter$o"; annotation; default = false }]
                  ~annotation:Type.bool
                  ~attribute_name:name
                :: methods
              else
                methods
            in
            let methods =
              if eq then
                add_order_method methods "__eq__"
              else
                methods
            in
            let methods =
              if order then
                ["__lt__"; "__le__"; "__gt__"; "__ge__"]
                |> List.fold ~init:methods ~f:add_order_method
              else
                methods
            in
            methods
          in
          let make_attribute (attribute_name, annotation) =
            Node.create_with_default_location
              {
                AnnotatedAttribute.annotation = Annotation.create_immutable ~global:true annotation;
                abstract = false;
                async = false;
                class_attribute = false;
                defined = true;
                final = false;
                initialized = true;
                name = attribute_name;
                parent = Type.Primitive (Reference.show name);
                property = None;
                static = false;
                value = Node.create_with_default_location Expression.Ellipsis;
              }
          in
          List.map generated_methods ~f:make_attribute
    in
    let dataclass_attributes () =
      (* TODO (T43210531): Warn about inconsistent annotations *)
      generate_attributes ~options:(dataclass_options ~resolution)
    in
    let attrs_attributes () =
      (* TODO (T41039225): Add support for other methods *)
      generate_attributes ~options:(attrs_attributes ~resolution)
    in
    dataclass_attributes () @ attrs_attributes ()
    |> List.iter ~f:(AnnotatedAttribute.Table.add table)
end

let rec attribute_table
    ~transitive
    ~class_attributes
    ~include_generated_attributes
    ?(special_method = false)
    ?instantiated
    ({ Node.value = { ClassSummary.name; _ }; _ } as definition)
    ~resolution
  =
  let key =
    {
      AttributeCache.transitive;
      class_attributes;
      special_method;
      include_generated_attributes;
      name;
      instantiated;
    }
  in
  match Hashtbl.find AttributeCache.cache key with
  | Some result -> result
  | None ->
      let original_instantiated = instantiated in
      let instantiated = Option.value instantiated ~default:(annotation definition) in
      let definition_attributes
          ~in_test
          ~instantiated
          ~class_attributes
          ~table
          ( { Node.value = { ClassSummary.name = parent_name; attribute_components; _ }; _ } as
          parent )
        =
        let add_actual () =
          let collect_attributes attribute =
            create_attribute
              attribute
              ~resolution
              ~parent
              ~instantiated
              ~inherited:(not (Reference.equal name parent_name))
              ~default_class_attribute:class_attributes
            |> AnnotatedAttribute.Table.add table
          in
          Class.attributes ~include_generated_attributes ~in_test attribute_components
          |> fun attribute_map ->
          Identifier.SerializableMap.iter (fun _ data -> collect_attributes data) attribute_map
        in
        let add_placeholder_stub_inheritances () =
          if Option.is_none (AnnotatedAttribute.Table.lookup_name table "__init__") then
            AnnotatedAttribute.Table.add
              table
              (Node.create_with_default_location
                 {
                   AnnotatedAttribute.annotation =
                     Annotation.create (Type.Callable.create ~annotation:Type.none ());
                   abstract = false;
                   async = false;
                   class_attribute = false;
                   defined = true;
                   final = false;
                   initialized = true;
                   name = "__init__";
                   parent = Primitive (Reference.show name);
                   property = None;
                   static = true;
                   value = Node.create_with_default_location Ellipsis;
                 });
          if Option.is_none (AnnotatedAttribute.Table.lookup_name table "__getattr__") then
            AnnotatedAttribute.Table.add
              table
              (Node.create_with_default_location
                 {
                   AnnotatedAttribute.annotation =
                     Annotation.create (Type.Callable.create ~annotation:Type.Any ());
                   abstract = false;
                   async = false;
                   class_attribute = false;
                   defined = true;
                   final = false;
                   initialized = true;
                   name = "__getattr__";
                   parent = Primitive (Reference.show name);
                   property = None;
                   static = true;
                   value = Node.create_with_default_location Ellipsis;
                 })
        in
        add_actual ();
        if
          AnnotatedBases.extends_placeholder_stub_class
            parent
            ~aliases:(GlobalResolution.aliases resolution)
            ~from_empty_stub:(GlobalResolution.is_suppressed_module resolution)
        then
          add_placeholder_stub_inheritances ();
        let get_table =
          attribute_table
            ~transitive:false
            ~class_attributes:false
            ~include_generated_attributes:false
            ~special_method:false
            ?instantiated:None
            ~resolution
        in
        if include_generated_attributes then
          ClassDecorators.apply ~definition:parent ~resolution ~class_attributes ~get_table table
      in
      let superclass_definitions = superclasses ~resolution definition in
      let in_test =
        List.exists (definition :: superclass_definitions) ~f:(fun { Node.value; _ } ->
            ClassSummary.is_unit_test value)
      in
      let table = AnnotatedAttribute.Table.create () in
      (* Pass over normal class hierarchy. *)
      let definitions =
        if class_attributes && special_method then
          []
        else if transitive then
          definition :: superclass_definitions
        else
          [definition]
      in
      List.iter
        definitions
        ~f:(definition_attributes ~in_test ~instantiated ~class_attributes ~table);

      (* Class over meta hierarchy if necessary. *)
      let meta_definitions =
        if class_attributes then
          metaclass ~resolution definition
          |> GlobalResolution.class_definition resolution
          >>| (fun definition -> definition :: superclasses ~resolution definition)
          |> Option.value ~default:[]
        else
          []
      in
      List.iter
        meta_definitions
        ~f:
          (definition_attributes
             ~in_test
             ~instantiated:(Type.meta instantiated)
             ~class_attributes:false
             ~table);
      let instantiate ~instantiated attribute =
        AnnotatedAttribute.parent attribute
        |> GlobalResolution.class_definition resolution
        >>| fun target ->
        let solution = constraints ~target ~instantiated ~resolution definition in
        AnnotatedAttribute.instantiate
          ~constraints:(fun annotation ->
            Some (TypeConstraints.Solution.instantiate solution annotation))
          attribute
      in
      Option.iter original_instantiated ~f:(fun instantiated ->
          AnnotatedAttribute.Table.filter_map table ~f:(instantiate ~instantiated));
      Hashtbl.set ~key ~data:table AttributeCache.cache;
      table


let attributes
    ?(transitive = false)
    ?(class_attributes = false)
    ?(include_generated_attributes = true)
    ?instantiated
    definition
    ~resolution
  =
  attribute_table
    ~transitive
    ~class_attributes
    ~include_generated_attributes
    ?instantiated
    definition
    ~resolution
  |> AnnotatedAttribute.Table.to_list


let attribute_fold
    ?(transitive = false)
    ?(class_attributes = false)
    ?(include_generated_attributes = true)
    definition
    ~initial
    ~f
    ~resolution
  =
  attributes ~transitive ~class_attributes ~include_generated_attributes ~resolution definition
  |> List.fold ~init:initial ~f


let attribute
    ?(transitive = false)
    ?(class_attributes = false)
    ?(special_method = false)
    ({ Node.location; _ } as definition)
    ~resolution
    ~name
    ~instantiated
  =
  let table =
    attribute_table
      ~instantiated
      ~transitive
      ~class_attributes
      ~special_method
      ~include_generated_attributes:true
      ~resolution
      definition
  in
  match AnnotatedAttribute.Table.lookup_name table name with
  | Some attribute -> attribute
  | None ->
      create_attribute
        ~resolution
        ~parent:definition
        ~defined:false
        ~default_class_attribute:class_attributes
        {
          Node.location;
          value =
            {
              StatementAttribute.name;
              kind =
                Simple
                  {
                    annotation = None;
                    value = None;
                    primitive = true;
                    toplevel = true;
                    frozen = false;
                    implicit = false;
                  };
            };
        }


let rec fallback_attribute
    ~(resolution : Resolution.t)
    ~name
    ({ Node.value = { ClassSummary.name = class_name; _ }; _ } as definition)
  =
  let compound_backup =
    let name =
      match name with
      | "__iadd__" -> Some "__add__"
      | "__isub__" -> Some "__sub__"
      | "__imul__" -> Some "__mul__"
      | "__imatmul__" -> Some "__matmul__"
      | "__itruediv__" -> Some "__truediv__"
      | "__ifloordiv__" -> Some "__floordiv__"
      | "__imod__" -> Some "__mod__"
      | "__idivmod__" -> Some "__divmod__"
      | "__ipow__" -> Some "__pow__"
      | "__ilshift__" -> Some "__lshift__"
      | "__irshift__" -> Some "__rshift__"
      | "__iand__" -> Some "__and__"
      | "__ixor__" -> Some "__xor__"
      | "__ior__" -> Some "__or__"
      | _ -> None
    in
    match name with
    | Some name ->
        attribute
          definition
          ~class_attributes:false
          ~transitive:true
          ~resolution:(Resolution.global_resolution resolution)
          ~name
          ~instantiated:(annotation definition)
        |> Option.some
    | _ -> None
  in
  let getitem_backup () =
    let fallback =
      attribute
        definition
        ~class_attributes:true
        ~transitive:true
        ~resolution:(Resolution.global_resolution resolution)
        ~name:"__getattr__"
        ~instantiated:(annotation definition)
    in
    if AnnotatedAttribute.defined fallback then
      let annotation = fallback |> AnnotatedAttribute.annotation |> Annotation.annotation in
      match annotation with
      | Type.Callable ({ implementation; _ } as callable) ->
          let location = AnnotatedAttribute.location fallback in
          let arguments =
            let self_argument =
              { Call.Argument.name = None; value = Expression.from_reference ~location class_name }
            in
            let name_argument =
              {
                Call.Argument.name = None;
                value = { Node.location; value = Expression.String (StringLiteral.create name) };
              }
            in
            [self_argument; name_argument]
          in
          let implementation =
            match AnnotatedSignature.select ~resolution ~arguments ~callable with
            | AnnotatedSignature.Found { Type.Callable.implementation; _ } -> implementation
            | AnnotatedSignature.NotFound _ -> implementation
          in
          let return_annotation = Type.Callable.Overload.return_annotation implementation in
          Some
            (create_attribute
               ~resolution:(Resolution.global_resolution resolution)
               ~parent:definition
               {
                 Node.location;
                 value =
                   {
                     StatementAttribute.name;
                     kind =
                       Simple
                         {
                           annotation = Some (Type.expression return_annotation);
                           value = None;
                           primitive = true;
                           toplevel = true;
                           frozen = false;
                           implicit = false;
                         };
                   };
               })
      | _ -> None
    else
      None
  in
  match compound_backup with
  | Some backup when AnnotatedAttribute.defined backup -> Some backup
  | _ -> getitem_backup ()


let constructor definition ~instantiated ~resolution =
  let return_annotation =
    let class_annotation = annotation definition in
    match class_annotation with
    | Type.Primitive name
    | Type.Parametric { name; _ } -> (
        let generics = generics definition ~resolution in
        (* Tuples are special. *)
        if String.equal name "tuple" then
          match generics with
          | Concrete [tuple_variable] -> Type.Tuple (Type.Unbounded tuple_variable)
          | _ -> Type.Tuple (Type.Unbounded Type.Any)
        else
          let backup = Type.Parametric { name; parameters = generics } in
          match instantiated, generics with
          | _, Concrete [] -> instantiated
          | Type.Primitive instantiated_name, _ when String.equal instantiated_name name -> backup
          | ( Type.Parametric { parameters = Concrete parameters; name = instantiated_name },
              Concrete generics )
            when String.equal instantiated_name name
                 && List.length parameters <> List.length generics ->
              backup
          | _ -> instantiated )
    | _ -> instantiated
  in
  let definitions =
    definition :: superclasses ~resolution definition
    |> List.map ~f:(fun definition -> annotation definition)
  in
  let definition_index attribute =
    attribute
    |> AnnotatedAttribute.parent
    |> (fun class_annotation ->
         List.findi definitions ~f:(fun _ annotation -> Type.equal annotation class_annotation))
    >>| fst
    |> Option.value ~default:Int.max_value
  in
  let constructor_signature, constructor_index =
    let attribute =
      attribute definition ~transitive:true ~resolution ~name:"__init__" ~instantiated
    in
    let signature = attribute |> AnnotatedAttribute.annotation |> Annotation.annotation in
    signature, definition_index attribute
  in
  let new_signature, new_index =
    let attribute =
      attribute definition ~transitive:true ~resolution ~name:"__new__" ~instantiated
    in
    let signature = attribute |> AnnotatedAttribute.annotation |> Annotation.annotation in
    signature, definition_index attribute
  in
  let signature =
    if new_index < constructor_index then
      new_signature
    else
      constructor_signature
  in
  match signature with
  | Type.Callable callable ->
      Type.Callable (Type.Callable.with_return_annotation ~annotation:return_annotation callable)
  | _ -> signature


let has_explicit_constructor definition ~resolution =
  let table =
    attribute_table
      ~transitive:false
      ~class_attributes:false
      ~include_generated_attributes:true
      ?instantiated:None
      definition
      ~resolution
  in
  let in_test =
    let superclasses = superclasses ~resolution definition in
    List.exists ~f:is_unit_test (definition :: superclasses)
  in
  let mem name = AnnotatedAttribute.Table.lookup_name table name |> Option.is_some in
  mem "__init__"
  || mem "__new__"
  || in_test
     && ( mem "async_setUp"
        || mem "setUp"
        || mem "_setup"
        || mem "_async_setup"
        || mem "with_context" )


let overrides definition ~resolution ~name =
  let find_override parent =
    let potential_override =
      attribute
        ~transitive:false
        ~class_attributes:true
        parent
        ~resolution
        ~name
        ~instantiated:(annotation parent)
    in
    if AnnotatedAttribute.defined potential_override then
      annotation definition
      |> (fun instantiated -> constraints ~target:parent definition ~resolution ~instantiated)
      |> (fun solution ->
           AnnotatedAttribute.instantiate
             ~constraints:(fun annotation ->
               Some (TypeConstraints.Solution.instantiate solution annotation))
             potential_override)
      |> Option.some
    else
      None
  in
  superclasses definition ~resolution |> List.find_map ~f:find_override


let has_method ?transitive definition ~resolution ~name =
  attribute ?transitive definition ~resolution ~name ~instantiated:(annotation definition)
  |> AnnotatedAttribute.annotation
  |> Annotation.annotation
  |> Type.is_callable


let has_abstract_base { Node.value = summary; _ } = ClassSummary.is_abstract summary

let get_abstract_attributes ~resolution definition =
  let attributes =
    attributes ~transitive:true ~instantiated:(annotation definition) definition ~resolution
  in
  List.filter attributes ~f:AnnotatedAttribute.abstract
