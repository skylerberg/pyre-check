(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open Ast
open Analysis
open Expression
open Pyre
open PyreParser
open Interprocedural
open Statement
open Domains
open TaintResult

type t = {
  is_obscure: bool;
  call_target: Callable.t;
  model: TaintResult.call_model;
}
[@@deriving show, sexp]

type breadcrumbs = Features.Simple.t list [@@deriving show, sexp]

let _ = show_breadcrumbs (* unused but derived *)

type taint_annotation =
  | Sink of {
      sink: Sinks.t;
      breadcrumbs: breadcrumbs;
    }
  | Source of {
      source: Sources.t;
      breadcrumbs: breadcrumbs;
    }
  | Tito of {
      tito: Sinks.t;
      breadcrumbs: breadcrumbs;
    }
  | SkipAnalysis (* Don't analyze methods with SkipAnalysis *)
  | Sanitize (* Don't propagate inferred model of methods with Sanitize *)
[@@deriving sexp]

exception InvalidModel of string

let raise_invalid_model message = raise (InvalidModel message)

let add_breadcrumbs breadcrumbs init = List.rev_append breadcrumbs init

let introduce_sink_taint
    ~root
    ({ TaintResult.backward = { sink_taint; _ }; _ } as taint)
    taint_sink_kind
    breadcrumbs
  =
  let backward =
    let assign_backward_taint environment taint =
      BackwardState.assign ~weak:true ~root ~path:[] taint environment
    in
    match taint_sink_kind with
    | Sinks.LocalReturn -> raise_invalid_model "Invalid TaintSink annotation `LocalReturn`"
    | _ ->
        let leaf_taint =
          BackwardTaint.singleton taint_sink_kind
          |> BackwardTaint.transform
               BackwardTaint.simple_feature_set
               ~f:(add_breadcrumbs breadcrumbs)
          |> BackwardState.Tree.create_leaf
        in
        let sink_taint = assign_backward_taint sink_taint leaf_taint in
        { taint.backward with sink_taint }
  in
  { taint with backward }


let introduce_taint_in_taint_out
    ~root
    ({ TaintResult.backward = { taint_in_taint_out; _ }; _ } as taint)
    taint_sink_kind
    breadcrumbs
  =
  let backward =
    let assign_backward_taint environment taint =
      BackwardState.assign ~weak:true ~root ~path:[] taint environment
    in
    match taint_sink_kind with
    | Sinks.LocalReturn ->
        let return_taint =
          Domains.local_return_taint
          |> BackwardTaint.transform
               BackwardTaint.simple_feature_set
               ~f:(add_breadcrumbs breadcrumbs)
          |> BackwardState.Tree.create_leaf
        in
        let taint_in_taint_out = assign_backward_taint taint_in_taint_out return_taint in
        { taint.backward with taint_in_taint_out }
    | Sinks.Attach when List.is_empty breadcrumbs ->
        raise_invalid_model "`Attach` must be accompanied by a list of features to attach."
    | Sinks.ParameterUpdate _
    | Sinks.Attach ->
        let update_taint =
          BackwardTaint.singleton taint_sink_kind
          |> BackwardTaint.transform
               BackwardTaint.simple_feature_set
               ~f:(add_breadcrumbs breadcrumbs)
          |> BackwardState.Tree.create_leaf
        in
        let taint_in_taint_out = assign_backward_taint taint_in_taint_out update_taint in
        { taint.backward with taint_in_taint_out }
    | _ ->
        Format.asprintf "Invalid TaintInTaintOut annotation `%s`" (Sinks.show taint_sink_kind)
        |> raise_invalid_model
  in
  { taint with backward }


let introduce_source_taint
    ~root
    ({ TaintResult.forward = { source_taint }; _ } as taint)
    taint_source_kind
    breadcrumbs
  =
  if Sources.equal taint_source_kind Sources.Attach && List.is_empty breadcrumbs then
    raise_invalid_model "`Attach` must be accompanied by a list of features to attach.";
  let source_taint =
    let leaf_taint =
      ForwardTaint.singleton taint_source_kind
      |> ForwardTaint.transform ForwardTaint.simple_feature_set ~f:(add_breadcrumbs breadcrumbs)
      |> ForwardState.Tree.create_leaf
    in
    ForwardState.assign ~weak:true ~root ~path:[] leaf_taint source_taint
  in
  { taint with forward = { source_taint } }


type leaf_kind =
  | Leaf of string
  | Breadcrumbs of breadcrumbs

let rec parse_annotations ~configuration ~parameters annotation =
  let get_parameter_position name =
    let matches_parameter_name index { Node.value = parameter; _ } =
      if parameter.Parameter.name = name then
        Some index
      else
        None
    in
    match List.find_mapi parameters ~f:matches_parameter_name with
    | Some index -> index
    | None -> raise_invalid_model (Format.sprintf "No such parameter `%s`" name)
  in
  let rec extract_breadcrumbs expression =
    let open Configuration in
    match expression.Node.value with
    | Name (Name.Identifier breadcrumb) ->
        [Features.simple_via ~allowed:configuration.features breadcrumb]
    | Tuple expressions -> List.concat_map ~f:extract_breadcrumbs expressions
    | _ -> []
  in
  let rec extract_via_value_of expression =
    match expression.Node.value with
    | Name (Name.Identifier name) ->
        [Features.Simple.ViaValueOf { position = get_parameter_position name }]
    | Tuple expressions -> List.concat_map ~f:extract_via_value_of expressions
    | _ -> []
  in
  let rec extract_names expression =
    match expression.Node.value with
    | Name (Name.Identifier name) -> [name]
    | Tuple expressions -> List.concat_map ~f:extract_names expressions
    | _ -> []
  in
  let base_matches expected = function
    | {
        Node.value =
          Name (Name.Attribute { base = { Node.value = Name (Name.Identifier identifier); _ }; _ });
        _;
      } ->
        Identifier.equal expected identifier
    | _ -> false
  in
  let rec extract_kinds expression =
    match expression.Node.value with
    | Name (Name.Identifier taint_kind) -> [Leaf taint_kind]
    | Name (Name.Attribute { base; _ }) -> extract_kinds base
    | Call { callee; arguments = { Call.Argument.value = expression; _ } :: _ }
      when base_matches "Via" callee ->
        [Breadcrumbs (extract_breadcrumbs expression)]
    | Call { callee; arguments = { Call.Argument.value = expression; _ } :: _ }
      when base_matches "ViaValueOf" callee ->
        [Breadcrumbs (extract_via_value_of expression)]
    | Call { callee; arguments = { Call.Argument.value = expression; _ } :: _ }
      when base_matches "Updates" callee ->
        extract_names expression
        |> List.map ~f:(fun name ->
               Leaf (Format.sprintf "ParameterUpdate%d" (get_parameter_position name)))
    | Call { callee; _ } -> extract_kinds callee
    | Tuple expressions -> List.concat_map ~f:extract_kinds expressions
    | _ -> []
  in
  let extract_leafs expression =
    let kinds, breadcrumbs =
      extract_kinds expression
      |> List.partition_map ~f:(function
             | Leaf l -> `Fst l
             | Breadcrumbs b -> `Snd b)
    in
    kinds, List.concat breadcrumbs
  in
  let get_source_kinds expression =
    let open Configuration in
    let kinds, breadcrumbs = extract_leafs expression in
    List.map kinds ~f:(fun kind ->
        Source { source = Sources.parse ~allowed:configuration.sources kind; breadcrumbs })
  in
  let get_sink_kinds expression =
    let open Configuration in
    let kinds, breadcrumbs = extract_leafs expression in
    List.map kinds ~f:(fun kind ->
        Sink { sink = Sinks.parse ~allowed:configuration.sinks kind; breadcrumbs })
  in
  let get_taint_in_taint_out expression =
    let open Configuration in
    let kinds, breadcrumbs = extract_leafs expression in
    match kinds with
    | [] -> [Tito { tito = Sinks.LocalReturn; breadcrumbs }]
    | _ ->
        List.map kinds ~f:(fun kind ->
            Tito { tito = Sinks.parse ~allowed:configuration.sinks kind; breadcrumbs })
  in
  let extract_attach_features ~name expression =
    let keep_features = function
      | Breadcrumbs breadcrumbs -> Some breadcrumbs
      | _ -> None
    in
    (* Ensure AttachToX annotations don't have any non-Via annotations for now. *)
    extract_kinds expression
    |> List.map ~f:keep_features
    |> Option.all
    >>| List.concat
    |> function
    | Some features -> features
    | None ->
        raise_invalid_model
          (Format.sprintf "All parameters to `%s` must be of the form `Via[feature]`." name)
  in
  match annotation with
  | Some ({ Node.value; _ } as expression) ->
      let rec parse_annotation = function
        | Call
            {
              callee;
              arguments = { Call.Argument.value = { value = Tuple expressions; _ }; _ } :: _;
            }
          when base_matches "Union" callee ->
            List.concat_map expressions ~f:(fun expression ->
                parse_annotations ~configuration ~parameters (Some expression))
        | Call { callee; arguments = { Call.Argument.value = expression; _ } :: _ }
          when base_matches "TaintSink" callee ->
            get_sink_kinds expression
        | Call { callee; arguments = { Call.Argument.value = expression; _ } :: _ }
          when base_matches "TaintSource" callee ->
            get_source_kinds expression
        | Call { callee; arguments = { Call.Argument.value = expression; _ } :: _ }
          when base_matches "TaintInTaintOut" callee ->
            get_taint_in_taint_out expression
        | Call { callee; arguments = { Call.Argument.value = expression; _ } :: _ }
          when base_matches "AttachToSink" callee ->
            [
              Sink
                {
                  sink = Sinks.Attach;
                  breadcrumbs = extract_attach_features ~name:"AttachToSink" expression;
                };
            ]
        | Call { callee; arguments = { Call.Argument.value = expression; _ } :: _ }
          when base_matches "AttachToTito" callee ->
            [
              Tito
                {
                  tito = Sinks.Attach;
                  breadcrumbs = extract_attach_features ~name:"AttachToTito" expression;
                };
            ]
        | Call { callee; arguments = { Call.Argument.value = expression; _ } :: _ }
          when base_matches "AttachToSource" callee ->
            [
              Source
                {
                  source = Sources.Attach;
                  breadcrumbs = extract_attach_features ~name:"AttachToSource" expression;
                };
            ]
        | Name (Name.Identifier "TaintInTaintOut") ->
            [Tito { tito = Sinks.LocalReturn; breadcrumbs = [] }]
        | Name (Name.Identifier "SkipAnalysis") -> [SkipAnalysis]
        | Name (Name.Identifier "Sanitize") -> [Sanitize]
        | _ ->
            Format.asprintf "Unrecognized taint annotation `%s`" (Expression.show expression)
            |> raise_invalid_model
      in
      parse_annotation value
  | None -> []


let find_positional_parameter_annotation position parameters =
  List.nth parameters position >>= Type.Record.Callable.RecordParameter.annotation


let find_named_parameter_annotation search_name parameters =
  let has_name = function
    | Type.Record.Callable.RecordParameter.KeywordOnly { name; _ } ->
        name = "$parameter$" ^ search_name
    | Type.Record.Callable.RecordParameter.Named { name; _ } -> name = search_name
    | _ -> false
  in
  List.find ~f:has_name parameters >>= Type.Record.Callable.RecordParameter.annotation


let add_signature_based_breadcrumbs ~resolution root ~callable_annotation breadcrumbs =
  match root, callable_annotation with
  | ( AccessPath.Root.PositionalParameter { position; _ },
      Some
        {
          Type.Callable.implementation =
            { Type.Callable.parameters = Type.Callable.Defined implementation_parameters; _ };
          _;
        } ) ->
      let parameter_annotation =
        find_positional_parameter_annotation position implementation_parameters
      in
      Features.add_type_breadcrumb ~resolution parameter_annotation breadcrumbs
  | ( AccessPath.Root.NamedParameter { name; _ },
      Some
        {
          Type.Callable.implementation =
            { Type.Callable.parameters = Type.Callable.Defined implementation_parameters; _ };
          _;
        } ) ->
      let parameter_annotation = find_named_parameter_annotation name implementation_parameters in
      Features.add_type_breadcrumb ~resolution parameter_annotation breadcrumbs
  | ( AccessPath.Root.LocalResult,
      Some { Type.Callable.implementation = { Type.Callable.annotation; _ }; _ } ) ->
      Features.add_type_breadcrumb ~resolution (Some annotation) breadcrumbs
  | _ -> breadcrumbs


let taint_parameter
    ~configuration
    ~resolution
    ~parameters
    model
    (root, _name, parameter)
    ~callable_annotation
  =
  let add_to_model model annotation =
    match annotation with
    | Sink { sink; breadcrumbs } ->
        List.map ~f:Features.SimpleSet.element breadcrumbs
        |> add_signature_based_breadcrumbs ~resolution root ~callable_annotation
        |> introduce_sink_taint ~root model sink
    | Source { source; breadcrumbs } ->
        List.map ~f:Features.SimpleSet.element breadcrumbs
        |> add_signature_based_breadcrumbs ~resolution root ~callable_annotation
        |> introduce_source_taint ~root model source
    | Tito { tito; breadcrumbs } ->
        (* For tito, both the parameter and the return type can provide type based breadcrumbs *)
        List.map ~f:Features.SimpleSet.element breadcrumbs
        |> add_signature_based_breadcrumbs ~resolution root ~callable_annotation
        |> add_signature_based_breadcrumbs
             ~resolution
             AccessPath.Root.LocalResult
             ~callable_annotation
        |> introduce_taint_in_taint_out ~root model tito
    | SkipAnalysis -> raise_invalid_model "SkipAnalysis annotation must be in return position"
    | Sanitize -> raise_invalid_model "Sanitize annotation must be in return position"
  in
  let annotation = parameter.Node.value.Parameter.annotation in
  parse_annotations ~configuration ~parameters annotation |> List.fold ~init:model ~f:add_to_model


let taint_return ~configuration ~resolution ~parameters model expression ~callable_annotation =
  let add_to_model model annotation =
    let root = AccessPath.Root.LocalResult in
    match annotation with
    | Sink { sink; breadcrumbs } ->
        List.map ~f:Features.SimpleSet.element breadcrumbs
        |> add_signature_based_breadcrumbs ~resolution root ~callable_annotation
        |> introduce_sink_taint ~root model sink
    | Source { source; breadcrumbs } ->
        List.map ~f:Features.SimpleSet.element breadcrumbs
        |> add_signature_based_breadcrumbs ~resolution root ~callable_annotation
        |> introduce_source_taint ~root model source
    | Tito _ -> raise_invalid_model "Invalid return annotation: TaintInTaintOut"
    | SkipAnalysis -> { model with mode = TaintResult.SkipAnalysis }
    | Sanitize -> { model with mode = TaintResult.Sanitize }
  in
  parse_annotations ~configuration ~parameters expression |> List.fold ~init:model ~f:add_to_model


type parameter_requirements = {
  required_anonymous_parameters_count: int;
  optional_anonymous_parameters_count: int;
  required_parameter_set: String.Set.t;
  optional_parameter_set: String.Set.t;
  has_star_parameter: bool;
  has_star_star_parameter: bool;
}

let create_parameters_requirements ~type_parameters =
  let get_parameters_requirements requirements type_parameter =
    let open Type.Callable.RecordParameter in
    match type_parameter with
    | Anonymous { default; _ } ->
        if default then
          {
            requirements with
            optional_anonymous_parameters_count =
              requirements.optional_anonymous_parameters_count + 1;
          }
        else
          {
            requirements with
            required_anonymous_parameters_count =
              requirements.required_anonymous_parameters_count + 1;
          }
    | Named { name; default; _ }
    | KeywordOnly { name; default; _ } ->
        let name = Identifier.sanitized name in
        if default then
          {
            requirements with
            optional_parameter_set = String.Set.add requirements.optional_parameter_set name;
          }
        else
          {
            requirements with
            required_parameter_set = String.Set.add requirements.required_parameter_set name;
          }
    | Variable _ -> { requirements with has_star_parameter = true }
    | Keywords _ -> { requirements with has_star_star_parameter = true }
  in
  let init =
    {
      required_anonymous_parameters_count = 0;
      optional_anonymous_parameters_count = 0;
      required_parameter_set = String.Set.empty;
      optional_parameter_set = String.Set.empty;
      has_star_parameter = false;
      has_star_star_parameter = false;
    }
  in
  List.fold_left type_parameters ~f:get_parameters_requirements ~init


let model_compatible ~type_parameters ~normalized_model_parameters =
  let parameter_requirements = create_parameters_requirements ~type_parameters in
  (* Once a requirement has been satisfied, it is removed from requirement object. At the end, we
     check whether there remains unsatisfied requirements. *)
  let validate_model_parameter (errors, requirements) (model_parameter, _, original) =
    (* Ensure that the parameter's default value is either not present or `...` to catch common
       errors when declaring models. *)
    let () =
      match Node.value original with
      | { Parameter.value = Some expression; name; _ } ->
          if not (Expression.equal_expression (Node.value expression) Expression.Ellipsis) then
            let message =
              Format.sprintf
                "Default values of parameters must be `...`. Did you mean to write `%s: %s`?"
                name
                (Expression.show expression)
            in
            raise_invalid_model message
      | _ -> ()
    in
    let open AccessPath.Root in
    match model_parameter with
    | LocalResult
    | Variable _ ->
        failwith
          ( "LocalResult|Variable won't be generated by AccessPath.Root.normalize_parameters, "
          ^ "and they cannot be compared with type_parameters." )
    | PositionalParameter { name; _ }
    | NamedParameter { name } ->
        let name = Identifier.sanitized name in
        if String.is_prefix name ~prefix:"__" then (* It is an anonymous parameter. *)
          let {
            required_anonymous_parameters_count;
            optional_anonymous_parameters_count;
            has_star_parameter;
            _;
          }
            =
            requirements
          in
          if required_anonymous_parameters_count >= 1 then
            ( errors,
              {
                requirements with
                required_anonymous_parameters_count = required_anonymous_parameters_count - 1;
              } )
          else if optional_anonymous_parameters_count >= 1 then
            ( errors,
              {
                requirements with
                optional_anonymous_parameters_count = optional_anonymous_parameters_count - 1;
              } )
          else if has_star_parameter then
            (* If all anonymous parameter quota is used, it might be covered by a `*args` *)
            errors, requirements
          else
            Format.sprintf "unexpected anonymous parameter: `%s`" name :: errors, requirements
        else
          let {
            required_parameter_set;
            optional_parameter_set;
            has_star_parameter;
            has_star_star_parameter;
            _;
          }
            =
            requirements
          in
          (* Consume an required or optional named parameter. *)
          if String.Set.mem required_parameter_set name then
            let required_parameter_set = String.Set.remove required_parameter_set name in
            errors, { requirements with required_parameter_set }
          else if String.Set.mem optional_parameter_set name then
            let optional_parameter_set = String.Set.remove optional_parameter_set name in
            errors, { requirements with optional_parameter_set }
          else if has_star_parameter || has_star_star_parameter then
            (* If the name is not found in the set, it might be covered by ``**kwargs` *)
            errors, requirements
          else
            Format.sprintf "unexpected named parameter: `%s`" name :: errors, requirements
    | StarParameter _ ->
        if requirements.has_star_parameter then
          errors, requirements
        else
          "unexpected star parameter" :: errors, requirements
    | StarStarParameter _ ->
        if requirements.has_star_star_parameter then
          errors, requirements
        else
          "unexpected star star parameter" :: errors, requirements
  in
  let errors, left_over =
    List.fold_left
      normalized_model_parameters
      ~f:validate_model_parameter
      ~init:([], parameter_requirements)
  in
  let { required_anonymous_parameters_count; required_parameter_set; _ } = left_over in
  let errors =
    if required_anonymous_parameters_count > 0 then
      Format.sprintf "missing %d anonymous parameters" required_anonymous_parameters_count
      :: errors
    else
      errors
  in
  let errors =
    if String.Set.is_empty required_parameter_set then
      errors
    else
      Format.sprintf
        "missing named parameters: `%s`"
        (required_parameter_set |> String.Set.to_list |> String.concat ~sep:", ")
      :: errors
  in
  errors


let demangle_class_attribute name =
  if String.is_substring ~substring:"__class__" name then
    String.split name ~on:'.'
    |> List.rev
    |> function
    | attribute :: "__class__" :: rest -> List.rev (attribute :: rest) |> String.concat ~sep:"."
    | _ -> name
  else
    name


let create ~resolution ?path ~configuration ~verify source =
  let global_resolution = Resolution.global_resolution resolution in
  let signatures =
    let filter_define_signature = function
      | { Node.value = Statement.Define { signature = { name; _ } as signature; _ }; location } ->
          let class_candidate =
            Reference.prefix name
            >>| GlobalResolution.parse_reference global_resolution
            >>= GlobalResolution.class_definition global_resolution
          in
          let call_target =
            match class_candidate with
            | Some _ -> Callable.create_method name
            | None -> Callable.create_function name
          in
          [signature, location, call_target]
      | { Node.value = Class { Class.name; bases; body; _ }; _ } ->
          begin
            match body with
            | [
             { Node.value = Statement.Expression { Node.value = Ast.Expression.Ellipsis; _ }; _ };
            ] ->
                ()
            | _ -> raise_invalid_model "Class models must have a body of `...`."
          end;
          let sink_annotation =
            let class_sink_base { Call.Argument.value; _ } =
              if Expression.show value |> String.is_prefix ~prefix:"TaintSink[" then
                Some value
              else
                None
            in
            List.find_map bases ~f:class_sink_base
          in
          let source_annotation =
            let class_source_base { Call.Argument.value; _ } =
              if Expression.show value |> String.is_prefix ~prefix:"TaintSource[" then
                Some value
              else
                None
            in
            List.find_map bases ~f:class_source_base
          in
          if Option.is_some sink_annotation || Option.is_some source_annotation then
            GlobalResolution.class_definitions global_resolution name
            >>= List.hd
            >>| (fun { Node.value = { Class.body; _ }; _ } ->
                  let signature { Node.value; location } =
                    match value with
                    | Statement.Define
                        {
                          Define.signature =
                            { Define.Signature.name; parameters; decorators; _ } as signature;
                          _;
                        } ->
                        let signature =
                          let parameters =
                            let sink_parameter parameter =
                              let update_annotation { Parameter.name; value; _ } =
                                let value =
                                  match value with
                                  | None -> None
                                  | Some _ ->
                                      Some (Node.create_with_default_location Expression.Ellipsis)
                                in
                                { Parameter.name; annotation = sink_annotation; value }
                              in
                              Node.map parameter ~f:update_annotation
                            in
                            List.map parameters ~f:sink_parameter
                          in
                          let decorators =
                            if
                              Define.Signature.is_property signature
                              || Define.Signature.is_property_setter signature
                            then
                              decorators
                            else
                              []
                          in
                          {
                            signature with
                            Define.Signature.parameters;
                            return_annotation = source_annotation;
                            decorators;
                          }
                        in
                        Some (signature, location, Callable.create_method name)
                    | _ -> None
                  in
                  List.filter_map body ~f:signature)
            |> Option.value ~default:[]
          else
            []
      | {
          Node.value =
            Assign
              { Assign.target = { Node.value = Name name; _ }; annotation = Some annotation; _ };
          location;
        }
        when Expression.is_simple_name name
             && Expression.show annotation |> String.is_prefix ~prefix:"TaintSource[" ->
          let name = Expression.name_to_reference_exn name in
          let signature =
            {
              Define.Signature.name;
              parameters = [];
              decorators = [];
              docstring = None;
              return_annotation = Some annotation;
              async = false;
              generator = false;
              parent = None;
            }
          in
          [signature, location, Callable.create_object name]
      | {
          Node.value =
            Assign
              { Assign.target = { Node.value = Name name; _ }; annotation = Some annotation; _ };
          location;
        }
        when Expression.is_simple_name name
             && Expression.show annotation |> String.is_prefix ~prefix:"TaintSink[" ->
          let name = Expression.name_to_reference_exn name in
          let signature =
            {
              Define.Signature.name;
              parameters =
                [Parameter.create ~location:Location.Reference.any ~annotation ~name:"$global" ()];
              decorators = [];
              docstring = None;
              return_annotation = None;
              async = false;
              generator = false;
              parent = None;
            }
          in
          [signature, location, Callable.create_object name]
      | _ -> []
    in
    String.split ~on:'\n' source
    |> Parser.parse
    |> Source.create
    |> Source.statements
    |> List.concat_map ~f:filter_define_signature
  in
  let verify_signature ~normalized_model_parameters callable_annotation =
    match callable_annotation with
    | Some
        ( {
            Type.Callable.implementation =
              { Type.Callable.parameters = Type.Callable.Defined implementation_parameters; _ };
            implicit;
            _;
          } as callable ) ->
        let model_compatibility_errors =
          (* Make self as an explicit parameter in type's parameter list *)
          let implicit_to_explicit_self { Type.Callable.name; implicit_annotation } =
            let name = demangle_class_attribute name in
            let open Type.Callable.RecordParameter in
            Named { name; annotation = implicit_annotation; default = false }
          in
          let type_parameters =
            implicit
            >>| implicit_to_explicit_self
            >>| (fun explicit_self -> explicit_self :: implementation_parameters)
            |> Option.value ~default:implementation_parameters
          in
          model_compatible ~type_parameters ~normalized_model_parameters
        in
        if not (List.is_empty model_compatibility_errors) then (
          let message =
            Format.asprintf
              "Model signature parameters do not match implementation `%s`. Reason(s): %s."
              (Type.show_for_hover (Type.Callable callable))
              (String.concat model_compatibility_errors ~sep:"; ")
          in
          Log.error "%s" message;
          raise_invalid_model message )
    | _ -> ()
  in
  let create_model
      ( ({ Define.Signature.name; parameters; return_annotation; decorators; _ } as define),
        location,
        call_target )
    =
    (* Make sure we know about what we model. *)
    let global_resolution = Resolution.global_resolution resolution in
    try
      let call_target = (call_target :> Callable.t) in
      let callable_annotation =
        (* Since properties and setters share the same undecorated name, we need to special-case
           them. *)
        let global_type () =
          name
          |> Expression.from_reference ~location:Location.Reference.any
          |> Resolution.resolve_to_annotation resolution
        in
        let parent =
          name
          |> Reference.as_list
          |> List.rev
          |> (fun list -> List.drop list 1)
          |> List.rev
          |> Reference.create_from_list
        in
        let get_matching_method ~predicate =
          let get_matching_define = function
            | { Node.value = Statement.Define ({ signature; _ } as define); location } ->
                if
                  predicate define
                  && Reference.equal define.Define.signature.Define.Signature.name name
                then
                  let parser = GlobalResolution.annotation_parser global_resolution in
                  Node.create signature ~location
                  |> Annotated.Define.Callable.create_overload ~parser
                  |> Type.Callable.create_from_implementation
                  |> Option.some
                else
                  None
            | _ -> None
          in
          GlobalResolution.class_definitions global_resolution parent
          >>= List.hd
          >>| (fun definition -> definition.Node.value.Class.body)
          >>= List.find_map ~f:get_matching_define
          >>| Annotation.create
          |> function
          | Some annotation -> annotation
          | None -> global_type ()
        in
        if Define.Signature.is_property define then
          get_matching_method ~predicate:Define.is_property
        else if Define.Signature.is_property_setter define then
          get_matching_method ~predicate:Define.is_property_setter
        else if not (List.is_empty decorators) then
          (* Ensure that models don't declare decorators that our taint analyses doesn't
             understand. *)
          raise_invalid_model
            (Format.sprintf
               "Unexpected decorators found when parsing model: `%s`"
               (List.map decorators ~f:Expression.show |> String.concat ~sep:", "))
        else
          global_type ()
      in
      let () =
        if
          Type.is_top (Annotation.annotation callable_annotation)
          && not (Annotation.is_global callable_annotation)
        then
          raise_invalid_model "Modeled entity is not part of the environment!"
      in
      let normalized_model_parameters = AccessPath.Root.normalize_parameters parameters in
      (* Check model matches callables primary signature. *)
      let callable_annotation =
        callable_annotation
        |> Annotation.annotation
        |> function
        | Type.Callable t -> Some t
        | _ -> None
      in
      let () = verify_signature ~normalized_model_parameters callable_annotation in
      normalized_model_parameters
      |> List.fold
           ~init:TaintResult.empty_model
           ~f:
             (taint_parameter
                ~configuration
                ~resolution:global_resolution
                ~parameters
                ~callable_annotation)
      |> (fun model ->
           taint_return
             ~configuration
             ~resolution:global_resolution
             ~parameters
             model
             return_annotation
             ~callable_annotation)
      |> fun model -> Some { model; call_target; is_obscure = false }
    with
    | Failure message
    | InvalidModel message ->
        let model_origin =
          match path with
          | None -> ""
          | Some path ->
              Format.sprintf
                " defined in `%s:%d`"
                (Path.absolute path)
                location.Location.start.Location.line
        in
        let message =
          Format.asprintf "Invalid model for `%a`%s: %s" Reference.pp name model_origin message
        in
        if verify then
          raise_invalid_model message
        else (
          Log.error "%s" message;
          None )
  in
  List.filter_map signatures ~f:create_model


let get_callsite_model ~call_target ~arguments =
  let call_target = (call_target :> Callable.t) in
  match Interprocedural.Fixpoint.get_model call_target with
  | None -> { is_obscure = true; call_target; model = TaintResult.empty_model }
  | Some model ->
      let expand_via_value_of
          { forward = { source_taint }; backward = { sink_taint; taint_in_taint_out }; mode }
        =
        let expand features =
          let transform feature =
            let open Features in
            match feature.SimpleSet.element with
            | Simple.ViaValueOf { position } ->
                List.nth arguments position
                >>= fun argument -> Simple.via_value_of_breadcrumb ~argument >>| SimpleSet.element
            | _ -> Some feature
          in
          List.filter_map features ~f:transform
        in
        let source_taint =
          ForwardState.transform ForwardTaint.simple_feature_set ~f:expand source_taint
        in
        let sink_taint =
          BackwardState.transform BackwardTaint.simple_feature_set ~f:expand sink_taint
        in
        let taint_in_taint_out =
          BackwardState.transform BackwardTaint.simple_feature_set ~f:expand taint_in_taint_out
        in
        { forward = { source_taint }; backward = { sink_taint; taint_in_taint_out }; mode }
      in
      let taint_model =
        Interprocedural.Result.get_model TaintResult.kind model
        |> Option.value ~default:TaintResult.empty_model
        |> expand_via_value_of
      in
      { is_obscure = model.is_obscure; call_target; model = taint_model }


let get_global_model ~resolution ~expression =
  let call_target =
    match Node.value expression, AccessPath.get_global ~resolution expression with
    | _, Some global -> Some global
    | Name (Name.Attribute { base; attribute; _ }), _ ->
        let is_meta, annotation =
          let rec is_meta = function
            | Type.Optional annotation -> is_meta annotation
            | annotation ->
                if Type.is_meta annotation then
                  true, Type.single_parameter annotation
                else
                  false, annotation
          in
          is_meta (Resolution.resolve resolution base)
        in
        let global_resolution = Resolution.global_resolution resolution in
        let parent =
          let attribute =
            GlobalResolution.class_definition global_resolution annotation
            >>| Annotated.Class.create
            >>| fun definition ->
            Annotated.Class.attribute
              ~transitive:true
              definition
              ~resolution:global_resolution
              ~name:attribute
              ~instantiated:annotation
          in
          match attribute with
          | Some attribute when Annotated.Attribute.defined attribute ->
              Annotated.Attribute.parent attribute |> Type.class_name
          | _ -> Type.class_name annotation
        in
        let attribute =
          if is_meta then
            Format.sprintf "__class__.%s" attribute
          else
            attribute
        in
        Some (Reference.create ~prefix:parent attribute)
    | _ -> None
  in
  match call_target with
  | Some target ->
      let model =
        Callable.create_object target
        |> fun call_target -> get_callsite_model ~call_target ~arguments:[]
      in
      Some (target, model)
  | None -> None


let get_global_sink_model ~resolution ~location ~expression =
  let to_sink
      (name, { model = { TaintResult.backward = { TaintResult.Backward.sink_taint; _ }; _ }; _ })
    =
    BackwardState.read
      ~root:(AccessPath.Root.PositionalParameter { position = 0; name = "$global" })
      ~path:[]
      sink_taint
    |> BackwardState.Tree.apply_call
         location
         ~callees:[`Function (Reference.show name)]
         ~port:AccessPath.Root.LocalResult
  in
  get_global_model ~resolution ~expression >>| to_sink


let parse ~resolution ?path ?(verify = true) ~source ~configuration models =
  create ~resolution ?path ~verify ~configuration source
  |> List.map ~f:(fun model -> model.call_target, model.model)
  |> Callable.Map.of_alist_reduce ~f:(join ~iteration:0)
  |> Callable.Map.merge models ~f:(fun ~key:_ ->
       function
       | `Both (a, b) -> Some (join ~iteration:0 a b)
       | `Left model
       | `Right model ->
           Some model)
