(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open Pyre
module Name = Expression.Name

module Assign = struct
  type t = {
    target: Expression.t;
    annotation: Expression.t option;
    value: Expression.t;
    parent: Reference.t option;
  }
  [@@deriving compare, eq, sexp, show, hash, to_yojson]

  let is_static_attribute_initialization { parent; _ } = Option.is_some parent
end

module Import = struct
  type import = {
    name: Reference.t;
    alias: Reference.t option;
  }
  [@@deriving compare, eq, sexp, show, hash, to_yojson]

  type t = {
    from: Reference.t option;
    imports: import list;
  }
  [@@deriving compare, eq, sexp, show, hash, to_yojson]
end

module Raise = struct
  type t = {
    expression: Expression.t option;
    from: Expression.t option;
  }
  [@@deriving compare, eq, sexp, show, hash, to_yojson]
end

module Return = struct
  type t = {
    is_implicit: bool;
    expression: Expression.t option;
  }
  [@@deriving compare, eq, sexp, show, hash, to_yojson]
end

module rec Assert : sig
  module Origin : sig
    type t =
      | Assertion
      | If of {
          statement: Statement.t;
          true_branch: bool;
        }
      | While
    [@@deriving compare, eq, sexp, show, hash, to_yojson]
  end

  type t = {
    test: Expression.t;
    message: Expression.t option;
    origin: Origin.t;
  }
  [@@deriving compare, eq, sexp, show, hash, to_yojson]
end = struct
  module Origin = struct
    type t =
      | Assertion
      | If of {
          statement: Statement.t;
          true_branch: bool;
        }
      | While
    [@@deriving compare, eq, sexp, show, hash, to_yojson]
  end

  type t = {
    test: Expression.t;
    message: Expression.t option;
    origin: Origin.t;
  }
  [@@deriving compare, eq, sexp, show, hash, to_yojson]
end

and Attribute : sig
  type property_kind =
    | ReadOnly of { getter_annotation: Expression.t option }
    | ReadWrite of {
        getter_annotation: Expression.t option;
        setter_annotation: Expression.t option;
      }
  [@@deriving compare, eq, sexp, show, hash]

  type simple = {
    annotation: Expression.t option;
    value: Expression.t option;
    primitive: bool;
    frozen: bool;
    toplevel: bool;
    implicit: bool;
  }
  [@@deriving compare, eq, sexp, show, hash]

  type kind =
    | Simple of simple
    | Method of {
        signatures: Define.Signature.t list;
        static: bool;
        final: bool;
      }
    | Property of {
        async: bool;
        class_property: bool;
        kind: property_kind;
      }
  [@@deriving compare, eq, sexp, show, hash]

  type attribute = {
    kind: kind;
    name: Identifier.t;
  }
  [@@deriving compare, eq, sexp, show, hash]

  type t = attribute Node.t [@@deriving compare, eq, sexp, show, hash]

  val create_simple
    :  location:Location.t ->
    ?annotation:Expression.t ->
    ?value:Expression.t ->
    ?primitive:bool ->
    ?frozen:bool ->
    ?toplevel:bool ->
    ?implicit:bool ->
    name:string ->
    unit ->
    t

  val name : parent:Reference.t -> Expression.t -> string option
end = struct
  type property_kind =
    | ReadOnly of { getter_annotation: Expression.t option }
    | ReadWrite of {
        getter_annotation: Expression.t option;
        setter_annotation: Expression.t option;
      }
  [@@deriving compare, eq, sexp, show, hash]

  type simple = {
    annotation: Expression.t option;
    value: Expression.t option;
    primitive: bool;
    frozen: bool;
    toplevel: bool;
    implicit: bool;
  }
  [@@deriving compare, eq, sexp, show, hash]

  type kind =
    | Simple of simple
    | Method of {
        signatures: Define.Signature.t list;
        static: bool;
        final: bool;
      }
    | Property of {
        async: bool;
        class_property: bool;
        kind: property_kind;
      }
  [@@deriving compare, eq, sexp, show, hash]

  type attribute = {
    kind: kind;
    name: Identifier.t;
  }
  [@@deriving compare, eq, sexp, show, hash]

  type t = attribute Node.t [@@deriving compare, eq, sexp, show, hash]

  let create_simple
      ~location
      ?annotation
      ?value
      ?(primitive = false)
      ?(frozen = false)
      ?(toplevel = true)
      ?(implicit = false)
      ~name
      ()
    =
    { name; kind = Simple { annotation; value; primitive; frozen; toplevel; implicit } }
    |> Node.create ~location


  let name ~parent target =
    let open Expression in
    match Node.value target with
    | Name (Name.Attribute { base; attribute; _ })
      when Expression.equal
             base
             (Expression.from_reference ~location:Location.Reference.any parent) ->
        Some attribute
    | _ -> None
end

and Class : sig
  type t = {
    name: Reference.t;
    bases: Expression.Call.Argument.t list;
    body: Statement.t list;
    decorators: Expression.t list;
    docstring: string option;
  }
  [@@deriving compare, eq, sexp, show, hash, to_yojson]

  val constructors : ?in_test:bool -> t -> Define.t list

  val defines : t -> Define.t list

  val find_define : t -> method_name:Identifier.t -> Define.t Node.t option

  val is_frozen : t -> bool

  val explicitly_assigned_attributes : t -> Attribute.t Identifier.SerializableMap.t

  type class_t = t [@@deriving compare, eq, sexp, show, hash, to_yojson]

  module AttributeComponents : sig
    type t [@@deriving compare, eq, sexp, show, hash]

    val create : class_t -> t
  end

  val implicit_attributes
    :  ?in_test:bool ->
    AttributeComponents.t ->
    Attribute.t Identifier.SerializableMap.t

  val attributes
    :  ?include_generated_attributes:bool ->
    ?in_test:bool ->
    AttributeComponents.t ->
    Attribute.t Identifier.SerializableMap.t
end = struct
  type t = {
    name: Reference.t;
    bases: Expression.Call.Argument.t list;
    body: Statement.t list;
    decorators: Expression.t list;
    docstring: string option;
  }
  [@@deriving compare, eq, sexp, show, hash, to_yojson]

  type class_t = t [@@deriving compare, eq, sexp, show, hash, to_yojson]

  let constructors ?(in_test = false) { body; _ } =
    let constructor = function
      | { Node.value = Statement.Define define; _ } when Define.is_constructor ~in_test define ->
          Some define
      | _ -> None
    in
    List.filter_map ~f:constructor body


  let test_setups { body; _ } =
    let constructor = function
      | { Node.value = Statement.Define define; _ } when Define.is_test_setup define -> Some define
      | _ -> None
    in
    List.filter_map ~f:constructor body


  let defines { body; _ } =
    let define = function
      | { Node.value = Statement.Define define; _ } -> Some define
      | _ -> None
    in
    List.filter_map ~f:define body


  let find_define { body; _ } ~method_name =
    let is_define = function
      | { Node.value = Statement.Define define; location }
        when String.equal (Define.unqualified_name define) method_name ->
          Some { Node.value = define; location }
      | _ -> None
    in
    List.filter_map ~f:is_define body |> List.hd


  let is_frozen { decorators; _ } =
    let is_frozen_dataclass decorator =
      match decorator with
      | {
       Node.value =
         Expression.Call
           {
             callee =
               {
                 Node.value =
                   Name
                     (Name.Attribute
                       {
                         base = { value = Name (Name.Identifier "dataclasses"); _ };
                         attribute = "dataclass";
                         _;
                       });
                 _;
               };
             arguments;
           };
       _;
      } ->
          let has_frozen_argument Expression.Call.Argument.{ name; value } =
            match name, value with
            | Some { Node.value; _ }, { Node.value = Expression.True; _ } ->
                String.equal "frozen" (Identifier.sanitized value)
            | _, _ -> false
          in
          List.exists arguments ~f:has_frozen_argument
      | _ -> false
    in
    List.exists decorators ~f:is_frozen_dataclass


  let explicitly_assigned_attributes ({ name; body; _ } as definition) =
    let assigned_attributes map { Node.location; value } =
      let open Expression in
      match value with
      (* Handle multiple assignments on same line *)
      | Statement.Assign
          {
            Assign.target = { Node.value = Tuple targets; _ };
            value = { Node.value = Tuple values; _ };
            _;
          } ->
          let add_attribute map ({ Node.location; _ } as target) value =
            Attribute.name ~parent:name target
            |> function
            | Some name ->
                let attribute =
                  Attribute.create_simple ~location ~name ~value ~primitive:true ()
                in
                Identifier.SerializableMap.set map ~key:name ~data:attribute
            | _ -> map
          in
          if List.length targets = List.length values then
            List.fold2_exn ~init:map ~f:add_attribute targets values
          else
            map
      | Assign { Assign.target = { Node.value = Tuple targets; _ }; value; _ } ->
          let add_attribute index map ({ Node.location; _ } as target) =
            Attribute.name ~parent:name target
            |> function
            | Some name ->
                let value =
                  let index = Node.create ~location (Integer index) in
                  match value with
                  | { Node.value = Call _; _ }
                  | { Node.value = Name _; _ } ->
                      Some
                        {
                          value with
                          Node.value =
                            Call
                              {
                                callee =
                                  {
                                    Node.location;
                                    value =
                                      Name
                                        (Name.Attribute
                                           {
                                             base = value;
                                             attribute = "__getitem__";
                                             special = true;
                                           });
                                  };
                                arguments = [{ Call.Argument.name = None; value = index }];
                              };
                        }
                  | _ -> None
                in
                value
                >>| (fun value ->
                      Attribute.create_simple ~location ~name ~value ~primitive:true ())
                >>| (fun data -> Identifier.SerializableMap.set map ~key:name ~data)
                |> Option.value ~default:map
            | _ -> map
          in
          List.foldi ~init:map ~f:add_attribute targets
      | Assign { Assign.target; annotation; value; _ } -> (
          Attribute.name ~parent:name target
          |> function
          | Some name ->
              let frozen = is_frozen definition in
              let attribute =
                Attribute.create_simple
                  ~location
                  ~name
                  ~value
                  ?annotation
                  ~primitive:true
                  ~frozen
                  ()
              in
              Identifier.SerializableMap.set map ~key:name ~data:attribute
          | _ -> map )
      | _ -> map
    in
    List.fold ~init:Identifier.SerializableMap.empty ~f:assigned_attributes body


  module PropertyDefine = struct
    type getter = {
      name: string;
      annotation: Expression.t option;
      location: Location.t;
      async: bool;
      is_class_property: bool;
    }

    type setter = {
      name: string;
      annotation: Expression.t option;
      location: Location.t;
      async: bool;
    }

    type t =
      | Getter of getter
      | Setter of setter

    let create
        ~location
        ({ Define.signature = { name; return_annotation; parameters; parent; _ }; _ } as define)
      =
      let inspect_decorators name =
        let async = Define.is_async define in
        let is_instance_property () =
          String.Set.exists Recognized.property_decorators ~f:(Define.has_decorator define)
        in
        let is_class_property () =
          String.Set.exists Recognized.classproperty_decorators ~f:(Define.has_decorator define)
        in
        let getter ~is_class_property =
          Some
            (Getter { name; annotation = return_annotation; is_class_property; async; location })
        in
        if is_instance_property () then
          getter ~is_class_property:false
        else if is_class_property () then
          getter ~is_class_property:true
        else
          match Define.is_property_setter define, parameters with
          | true, _ :: { Node.value = { Parameter.annotation; _ }; _ } :: _ ->
              Some (Setter { name; annotation; async; location })
          | _ -> None
      in
      parent
      >>= fun parent ->
      Attribute.name ~parent (Expression.from_reference ~location name) >>= inspect_decorators
  end

  module AttributeComponents = struct
    type attribute_map = Attribute.attribute Node.t Identifier.SerializableMap.t
    [@@deriving compare, eq, sexp, show, hash]

    type t = {
      explicitly_assigned_attributes: attribute_map;
      constructor_attributes: attribute_map;
      test_setup_attributes: attribute_map;
      additional_attributes: attribute_map;
    }
    [@@deriving compare, eq, sexp, show, hash]

    let create ({ name; body; _ } as definition) =
      let merge _ left right =
        match right with
        | None -> left
        | Some _ -> right
      in
      let get_implicits defines =
        List.map defines ~f:(Define.implicit_attributes ~definition)
        |> List.fold
             ~init:Identifier.SerializableMap.empty
             ~f:(Identifier.SerializableMap.merge merge)
      in
      let constructor_attributes = constructors ~in_test:false definition |> get_implicits in
      let test_setup_attributes = test_setups definition |> get_implicits in
      let additional_attributes =
        let property_attributes =
          let property_attributes map = function
            | { Node.location; value = Statement.Define define } -> (
              match PropertyDefine.create ~location define with
              | Some (Setter { name; _ } as kind)
              | Some (Getter { name; _ } as kind) ->
                  let data =
                    Identifier.SerializableMap.find_opt name map
                    |> Option.value ~default:(None, None)
                    |> fun (existing_getter, existing_setter) ->
                    match kind with
                    | Setter setter -> existing_getter, Some setter
                    | Getter getter -> Some getter, existing_setter
                  in
                  Identifier.SerializableMap.set map ~key:name ~data
              | None -> map )
            | _ -> map
          in
          let consolidate = function
            | _, (None, None)
            | _, (None, Some _) ->
                None (* not allowed *)
            | ( _,
                ( Some
                    {
                      PropertyDefine.name;
                      annotation = getter_annotation;
                      async;
                      location;
                      is_class_property;
                    },
                  None ) ) ->
                ( name,
                  {
                    Attribute.name;
                    kind =
                      Property
                        {
                          kind = ReadOnly { getter_annotation };
                          async;
                          class_property = is_class_property;
                        };
                  }
                  |> Node.create ~location )
                |> Option.some
            | ( _,
                ( Some
                    {
                      PropertyDefine.name;
                      annotation = getter_annotation;
                      async;
                      location;
                      is_class_property;
                    },
                  Some { PropertyDefine.annotation = setter_annotation; _ } ) ) ->
                ( name,
                  {
                    Attribute.name;
                    kind =
                      Property
                        {
                          kind = ReadWrite { getter_annotation; setter_annotation };
                          async;
                          class_property = is_class_property;
                        };
                  }
                  |> Node.create ~location )
                |> Option.some
          in
          List.fold ~init:Identifier.SerializableMap.empty ~f:property_attributes body
          |> Identifier.SerializableMap.to_seq
          |> Seq.filter_map consolidate
          |> Identifier.SerializableMap.of_seq
        in
        let callable_attributes =
          let callable_attributes map { Node.location; value } =
            match value with
            | Statement.Define
                ({ Define.signature = { name = target; _ } as signature; _ } as define) ->
                Attribute.name (Expression.from_reference ~location target) ~parent:name
                >>| (fun name ->
                      let attribute =
                        match Identifier.SerializableMap.find_opt name map with
                        | Some { Node.value = { Attribute.kind = Method { signatures; _ }; _ }; _ }
                          ->
                            {
                              Attribute.name;
                              kind =
                                Method
                                  {
                                    signatures = signature :: signatures;
                                    static = Define.is_static_method define;
                                    final = Define.is_final_method define;
                                  };
                            }
                            |> Node.create ~location
                        | _ ->
                            {
                              Attribute.name;
                              kind =
                                Method
                                  {
                                    signatures = [signature];
                                    static = Define.is_static_method define;
                                    final = Define.is_final_method define;
                                  };
                            }
                            |> Node.create ~location
                      in
                      Identifier.SerializableMap.set map ~key:name ~data:attribute)
                |> Option.value ~default:map
            | _ -> map
          in
          List.fold ~init:Identifier.SerializableMap.empty ~f:callable_attributes body
        in
        let class_attributes =
          let callable_attributes map { Node.location; value } =
            match value with
            | Statement.Class { name; _ } ->
                let open Expression in
                let annotation =
                  let meta_annotation =
                    {
                      Node.location;
                      value =
                        Call
                          {
                            callee =
                              {
                                Node.location;
                                value =
                                  Name
                                    (Name.Attribute
                                       {
                                         base =
                                           {
                                             Node.location;
                                             value =
                                               Name
                                                 (Name.Attribute
                                                    {
                                                      base =
                                                        {
                                                          Node.location;
                                                          value = Name (Name.Identifier "typing");
                                                        };
                                                      attribute = "Type";
                                                      special = false;
                                                    });
                                           };
                                         attribute = "__getitem__";
                                         special = true;
                                       });
                              };
                            arguments =
                              [
                                {
                                  Call.Argument.name = None;
                                  value =
                                    Expression.from_reference ~location:Location.Reference.any name;
                                };
                              ];
                          };
                    }
                  in
                  {
                    Node.location;
                    value =
                      Call
                        {
                          callee =
                            {
                              Node.location;
                              value =
                                Name
                                  (Name.Attribute
                                     {
                                       base =
                                         {
                                           Node.location;
                                           value =
                                             Name
                                               (Name.Attribute
                                                  {
                                                    base =
                                                      {
                                                        Node.location;
                                                        value = Name (Name.Identifier "typing");
                                                      };
                                                    attribute = "ClassVar";
                                                    special = false;
                                                  });
                                         };
                                       attribute = "__getitem__";
                                       special = true;
                                     });
                            };
                          arguments = [{ Call.Argument.name = None; value = meta_annotation }];
                        };
                  }
                in
                let attribute_name = Reference.last name in
                Identifier.SerializableMap.set
                  map
                  ~key:attribute_name
                  ~data:(Attribute.create_simple ~location ~name:attribute_name ~annotation ())
            | _ -> map
          in
          List.fold ~init:Identifier.SerializableMap.empty ~f:callable_attributes body
        in
        let slots_attributes =
          let slots_attributes map { Node.value; _ } =
            let open Expression in
            let is_slots = function
              | Name (Name.Identifier "__slots__")
              | Name (Name.Attribute { attribute = "__slots__"; _ }) ->
                  true
              | _ -> false
            in
            match value with
            | Statement.Assign
                {
                  Assign.target = { Node.value = target_value; _ };
                  value = { Node.value = List attributes; location };
                  _;
                }
              when is_slots target_value ->
                let add_attribute map { Node.value; _ } =
                  match value with
                  | String { StringLiteral.value; _ } ->
                      Attribute.create_simple ~location ~name:value ()
                      |> fun attribute ->
                      Identifier.SerializableMap.set map ~key:value ~data:attribute
                  | _ -> map
                in
                List.fold ~init:map ~f:add_attribute attributes
            | _ -> map
          in
          List.fold ~init:Identifier.SerializableMap.empty ~f:slots_attributes body
        in
        let merge _ left right =
          match right with
          | None -> left
          | Some _ -> right
        in
        property_attributes
        |> Identifier.SerializableMap.merge merge callable_attributes
        |> Identifier.SerializableMap.merge merge class_attributes
        |> Identifier.SerializableMap.merge merge slots_attributes
      in
      {
        explicitly_assigned_attributes = explicitly_assigned_attributes definition;
        constructor_attributes;
        test_setup_attributes;
        additional_attributes;
      }
  end

  let implicit_attributes
      ?(in_test = false)
      {
        AttributeComponents.constructor_attributes;
        test_setup_attributes;
        additional_attributes;
        _;
      }
    =
    (* Bias towards the right (previously occuring map in the `|> merge other_map` flow). *)
    let merge _ left right =
      match right with
      | None -> left
      | Some _ -> right
    in
    let implicitly_assigned_attributes =
      if in_test then
        Identifier.SerializableMap.merge merge test_setup_attributes constructor_attributes
      else
        constructor_attributes
    in
    (* Merge with decreasing priority. *)
    implicitly_assigned_attributes |> Identifier.SerializableMap.merge merge additional_attributes


  let attributes
      ?(include_generated_attributes = true)
      ?(in_test = false)
      ({ AttributeComponents.explicitly_assigned_attributes; _ } as components)
    =
    let explicit_attributes = explicitly_assigned_attributes in
    if not include_generated_attributes then
      explicit_attributes
    else
      let merge _ left right =
        match right with
        | None -> left
        | Some _ -> right
      in
      explicit_attributes
      |> Identifier.SerializableMap.merge merge (implicit_attributes ~in_test components)
end

and Define : sig
  module Signature : sig
    type t = {
      name: Reference.t;
      parameters: Expression.t Parameter.t list;
      decorators: Expression.t list;
      docstring: string option;
      return_annotation: Expression.t option;
      async: bool;
      generator: bool;
      parent: Reference.t option; (* The class owning the method. *)
    }
    [@@deriving compare, eq, sexp, show, hash, to_yojson]

    val create_toplevel : qualifier:Reference.t option -> t

    val create_class_toplevel : parent:Reference.t -> t

    val unqualified_name : t -> Identifier.t

    val self_identifier : t -> Identifier.t

    val is_method : t -> bool

    val is_coroutine : t -> bool

    val is_abstract_method : t -> bool

    val is_overloaded_method : t -> bool

    val is_static_method : t -> bool

    val is_final_method : t -> bool

    val is_class_method : t -> bool

    val is_class_property : t -> bool

    val is_dunder_method : t -> bool

    val is_constructor : ?in_test:bool -> t -> bool

    val is_property_setter : t -> bool

    val is_property : t -> bool

    val is_untyped : t -> bool

    val is_toplevel : t -> bool

    val is_class_toplevel : t -> bool

    val has_decorator : ?match_prefix:bool -> t -> string -> bool

    val has_return_annotation : t -> bool
  end

  type t = {
    signature: Signature.t;
    body: Statement.t list;
  }
  [@@deriving compare, eq, sexp, show, hash, to_yojson]

  val create_toplevel : qualifier:Reference.t option -> statements:Statement.t list -> t

  val create_class_toplevel : parent:Reference.t -> statements:Statement.t list -> t

  val unqualified_name : t -> Identifier.t

  val self_identifier : t -> Identifier.t

  val is_method : t -> bool

  val is_coroutine : t -> bool

  val is_abstract_method : t -> bool

  val is_overloaded_method : t -> bool

  val is_static_method : t -> bool

  val is_final_method : t -> bool

  val is_class_method : t -> bool

  val is_class_property : t -> bool

  val is_dunder_method : t -> bool

  val is_constructor : ?in_test:bool -> t -> bool

  val is_test_setup : t -> bool

  val is_property_setter : t -> bool

  val is_property : t -> bool

  val is_untyped : t -> bool

  val is_stub : t -> bool

  val is_toplevel : t -> bool

  val is_class_toplevel : t -> bool

  val is_async : t -> bool

  val dump : t -> bool

  val dump_cfg : t -> bool

  val dump_locations : t -> bool

  val show_json : t -> string

  val implicit_attributes : t -> definition:Class.t -> Attribute.t Identifier.SerializableMap.t

  val has_decorator : ?match_prefix:bool -> t -> string -> bool

  val has_return_annotation : t -> bool
end = struct
  module Signature = struct
    type t = {
      name: Reference.t;
      parameters: Expression.t Parameter.t list;
      decorators: Expression.t list;
      docstring: string option;
      return_annotation: Expression.t option;
      async: bool;
      generator: bool;
      parent: Reference.t option; (* The class owning the method. *)
    }
    [@@deriving compare, eq, sexp, show, hash, to_yojson]

    let create_toplevel ~qualifier =
      {
        name = Reference.create ?prefix:qualifier "$toplevel";
        parameters = [];
        decorators = [];
        docstring = None;
        return_annotation = None;
        async = false;
        generator = false;
        parent = None;
      }


    let create_class_toplevel ~parent =
      {
        name = Reference.create ~prefix:parent "$class_toplevel";
        parameters = [];
        decorators = [];
        docstring = None;
        return_annotation = None;
        async = false;
        generator = false;
        parent = Some parent;
      }


    let unqualified_name { name; _ } = Reference.last name

    let self_identifier { parameters; _ } =
      match parameters with
      | { Node.value = { Parameter.name; _ }; _ } :: _ -> name
      | _ -> "self"


    let is_method { parent; _ } = Option.is_some parent

    let has_decorator ?(match_prefix = false) { decorators; _ } decorator =
      Expression.exists_in_list ~match_prefix ~expression_list:decorators decorator


    let has_return_annotation { return_annotation; _ } = Option.is_some return_annotation

    let is_coroutine signature = has_decorator signature "asyncio.coroutines.coroutine"

    let is_abstract_method signature =
      has_decorator signature "abstractmethod"
      || has_decorator signature "abc.abstractmethod"
      || has_decorator signature "abstractproperty"
      || has_decorator signature "abc.abstractproperty"


    let is_overloaded_method signature =
      has_decorator signature "overload" || has_decorator signature "typing.overload"


    let is_static_method signature =
      (* `__new__` is always a static method. See
         `https://docs.python.org/3/reference/datamodel.html#object.__new__`. *)
      String.equal (unqualified_name signature) "__new__" || has_decorator signature "staticmethod"


    let is_final_method signature = has_decorator signature "typing.final"

    let is_dunder_method signature =
      let name = unqualified_name signature in
      String.is_prefix ~prefix:"__" name && String.is_suffix ~suffix:"__" name


    let is_class_method ({ parent; _ } as signature) =
      let valid_names = ["__init_subclass__"; "__new__"; "__class_getitem__"] in
      Option.is_some parent
      && ( Set.exists Recognized.classmethod_decorators ~f:(has_decorator signature)
         || List.mem valid_names (unqualified_name signature) ~equal:String.equal )


    let is_class_property ({ parent; _ } as signature) =
      Option.is_some parent
      && Set.exists Recognized.classproperty_decorators ~f:(has_decorator signature)


    let is_test_setup ({ parent; _ } as signature) =
      let name = unqualified_name signature in
      if Option.is_none parent then
        false
      else
        List.mem
          ~equal:String.equal
          ["async_setUp"; "setUp"; "_setup"; "_async_setup"; "with_context"]
          name


    let is_constructor ?(in_test = false) ({ parent; _ } as signature) =
      let name = unqualified_name signature in
      if Option.is_none parent then
        false
      else
        String.equal name "__init__"
        || String.equal name "__new__"
        || (in_test && is_test_setup signature)


    let is_property_setter signature =
      has_decorator signature (unqualified_name signature ^ ".setter")


    let is_property signature = has_decorator signature "property"

    let is_untyped { return_annotation; _ } = Option.is_none return_annotation

    let is_async { async; _ } = async

    let is_toplevel signature = String.equal (unqualified_name signature) "$toplevel"

    let is_class_toplevel signature = String.equal (unqualified_name signature) "$class_toplevel"
  end

  type t = {
    signature: Signature.t;
    body: Statement.t list;
  }
  [@@deriving compare, eq, sexp, show, hash, to_yojson]

  let create_toplevel ~qualifier ~statements =
    { signature = Signature.create_toplevel ~qualifier; body = statements }


  let create_class_toplevel ~parent ~statements =
    { signature = Signature.create_class_toplevel ~parent; body = statements }


  let unqualified_name { signature; _ } = Signature.unqualified_name signature

  let self_identifier { signature; _ } = Signature.self_identifier signature

  let is_method { signature; _ } = Signature.is_method signature

  let has_decorator ?(match_prefix = false) { signature; _ } decorator =
    Signature.has_decorator ~match_prefix signature decorator


  let has_return_annotation { signature; _ } = Signature.has_return_annotation signature

  let is_coroutine { signature; _ } = Signature.is_coroutine signature

  let is_abstract_method { signature; _ } = Signature.is_abstract_method signature

  let is_overloaded_method { signature; _ } = Signature.is_overloaded_method signature

  let is_static_method { signature; _ } = Signature.is_static_method signature

  let is_final_method { signature; _ } = Signature.is_final_method signature

  let is_dunder_method { signature; _ } = Signature.is_dunder_method signature

  let is_class_method { signature; _ } = Signature.is_class_method signature

  let is_class_property { signature; _ } = Signature.is_class_property signature

  let is_constructor ?(in_test = false) { signature; _ } =
    Signature.is_constructor ~in_test signature


  let is_test_setup { signature; _ } = Signature.is_test_setup signature

  let is_property_setter { signature; _ } = Signature.is_property_setter signature

  let is_property { signature; _ } = Signature.is_property signature

  let is_untyped { signature; _ } = Signature.is_untyped signature

  let is_async { signature; _ } = Signature.is_async signature

  let is_toplevel { signature; _ } = Signature.is_toplevel signature

  let is_class_toplevel { signature; _ } = Signature.is_class_toplevel signature

  let contains_call { body; _ } name =
    let matches = function
      | {
          Node.value =
            Statement.Expression
              {
                Node.value =
                  Expression.Call
                    {
                      callee =
                        { Node.value = Expression.Name (Expression.Name.Identifier identifier); _ };
                      _;
                    };
                _;
              };
          _;
        }
        when String.equal identifier name ->
          true
      | _ -> false
    in
    List.exists ~f:matches body


  let is_stub { body; _ } =
    match List.rev body with
    | { Node.value = Expression { Node.value = Expression.Ellipsis; _ }; _ } :: _
    | _ :: { Node.value = Expression { Node.value = Expression.Ellipsis; _ }; _ } :: _ ->
        true
    | _ -> false


  let dump define = contains_call define "pyre_dump"

  let dump_cfg define = contains_call define "pyre_dump_cfg"

  let dump_locations define = contains_call define "pyre_dump_locations"

  let show_json define = define |> to_yojson |> Yojson.Safe.pretty_to_string

  let implicit_attributes
      ({ body; signature = { parameters; _ } } as define)
      ~definition:{ Class.body = definition_body; _ }
      : Attribute.t Identifier.SerializableMap.t
    =
    let open Expression in
    let parameter_annotations =
      let add_parameter map = function
        | { Node.value = { Parameter.name; annotation = Some annotation; _ }; _ } ->
            Identifier.SerializableMap.set map ~key:name ~data:annotation
        | _ -> map
      in
      List.fold ~init:Identifier.SerializableMap.empty ~f:add_parameter parameters
    in
    let attribute ~toplevel map { Node.value; _ } =
      match value with
      | Statement.Assign { Assign.target; annotation; value; _ } -> (
          let simple_attribute ~map ~target:({ Node.location; _ } as target) ~annotation =
            match target with
            | {
             Node.value =
               Name
                 (Name.Attribute
                   { base = { Node.value = Name (Name.Identifier self); _ }; attribute = name; _ });
             _;
            }
              when Identifier.equal self (self_identifier define) ->
                let simple =
                  {
                    Attribute.annotation;
                    value = Some value;
                    primitive = true;
                    frozen = false;
                    toplevel;
                    implicit = true;
                  }
                  |> Node.create ~location
                in
                let update = function
                  | Some (head, tail) -> Some (simple, head :: tail)
                  | None -> Some (simple, [])
                in
                Identifier.SerializableMap.update name update map
            | _ -> map
          in
          match target with
          | { Node.value = Name _; _ } ->
              let annotation =
                let is_reassignment target value =
                  let target = Identifier.sanitized target in
                  let value = Identifier.sanitized value in
                  String.equal target value || String.equal target ("_" ^ value)
                in
                match toplevel, annotation, target, value with
                | ( true,
                    None,
                    {
                      Node.value =
                        Name
                          (Name.Attribute
                            {
                              base = { Node.value = Name (Name.Identifier _); _ };
                              attribute = target;
                              _;
                            });
                      _;
                    },
                    { Node.value = Name (Name.Identifier value); _ } )
                  when is_reassignment target value ->
                    Identifier.SerializableMap.find_opt value parameter_annotations
                | _ -> annotation
              in
              simple_attribute ~map ~target ~annotation
          | { Node.value = Tuple targets; _ } ->
              List.fold
                ~init:map
                ~f:(fun map target -> simple_attribute ~map ~target ~annotation)
                targets
          | _ -> map )
      | _ -> map
    in
    let merge_attributes name = function
      | { Node.location; value = simple }, [] ->
          { Attribute.kind = Simple simple; name } |> Node.create ~location
      | ({ Node.location; value = simple } as head), tail ->
          let annotation =
            let annotation = function
              | { Node.value = { Attribute.annotation = Some annotation; _ }; _ } ->
                  Some annotation
              | _ -> None
            in
            match List.filter_map ~f:annotation (head :: tail) with
            | [] -> None
            | ({ Node.location; _ } as annotation) :: annotations ->
                let argument_value =
                  Node.create_with_default_location (Tuple (annotation :: annotations))
                in
                if List.for_all ~f:(Expression.equal annotation) annotations then
                  Some annotation
                else
                  Some
                    {
                      Node.location;
                      value =
                        Call
                          {
                            callee =
                              {
                                Node.location;
                                value =
                                  Name
                                    (Name.Attribute
                                       {
                                         base =
                                           {
                                             Node.location;
                                             value =
                                               Name
                                                 (Name.Attribute
                                                    {
                                                      base =
                                                        {
                                                          Node.location;
                                                          value = Name (Name.Identifier "typing");
                                                        };
                                                      attribute = "Union";
                                                      special = false;
                                                    });
                                           };
                                         attribute = "__getitem__";
                                         special = true;
                                       });
                              };
                            arguments = [{ Call.Argument.name = None; value = argument_value }];
                          };
                    }
          in
          {
            Node.location;
            value = { Attribute.name; Attribute.kind = Simple { simple with annotation } };
          }
    in
    let rec gather_nested_statements ~toplevel body =
      (* Can't use `Visit` module due to circularity :( *)
      let expand_statement ({ Node.value; _ } as statement) =
        match value with
        | Statement.If { If.body; orelse; _ }
        | For { For.body; orelse; _ }
        | While { While.body; orelse; _ } ->
            gather_nested_statements ~toplevel:false body
            @ gather_nested_statements ~toplevel:false orelse
        | Try { Try.body; orelse; finally; _ } ->
            gather_nested_statements ~toplevel:false body
            @ gather_nested_statements ~toplevel:false orelse
            @ gather_nested_statements ~toplevel:false finally
        | With { With.body; _ } -> gather_nested_statements ~toplevel:false body
        | Expression
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
                                base = { Node.value = Name (Name.Identifier self); _ };
                                attribute = name;
                                _;
                              });
                        _;
                      };
                    _;
                  };
              _;
            }
          when Identifier.equal self (self_identifier define) ->
            (* Look for method in class definition. *)
            let inline = function
              | {
                  Node.value =
                    Statement.Define
                      { signature = { name = callee; parent = Some parent; _ }; body };
                  _;
                }
                when Reference.equal callee (Reference.create ~prefix:parent name) ->
                  Some body
              | _ -> None
            in
            List.find_map ~f:inline definition_body |> Option.value ~default:[statement]
        | _ ->
            if toplevel then
              []
            else
              [statement]
      in
      List.concat_map ~f:expand_statement body
    in
    let toplevel_attributes =
      body |> List.fold ~init:Identifier.SerializableMap.empty ~f:(attribute ~toplevel:true)
    in
    gather_nested_statements ~toplevel:true body
    |> List.fold ~init:toplevel_attributes ~f:(attribute ~toplevel:false)
    |> Identifier.SerializableMap.mapi merge_attributes
end

and For : sig
  type t = {
    target: Expression.t;
    iterator: Expression.t;
    body: Statement.t list;
    orelse: Statement.t list;
    async: bool;
  }
  [@@deriving compare, eq, sexp, show, hash, to_yojson]

  val preamble : t -> Statement.t
end = struct
  type t = {
    target: Expression.t;
    iterator: Expression.t;
    body: Statement.t list;
    orelse: Statement.t list;
    async: bool;
  }
  [@@deriving compare, eq, sexp, show, hash, to_yojson]

  let preamble { target = { Node.location; _ } as target; iterator; async; _ } =
    let open Expression in
    let value =
      let value =
        let create_call base iterator next =
          Call
            {
              callee =
                {
                  Node.location;
                  value =
                    Name
                      (Name.Attribute
                         {
                           base =
                             {
                               Node.location;
                               value =
                                 Call
                                   {
                                     callee =
                                       {
                                         Node.location;
                                         value =
                                           Name
                                             (Name.Attribute
                                                { base; attribute = iterator; special = true });
                                       };
                                     arguments = [];
                                   };
                             };
                           attribute = next;
                           special = true;
                         });
                };
              arguments = [];
            }
        in
        if async then
          create_call iterator "__aiter__" "__anext__"
        else
          create_call iterator "__iter__" "__next__"
      in
      if async then
        { Node.location; value = Await (Node.create value ~location) }
      else
        { Node.location; value }
    in
    {
      Node.location;
      value = Statement.Assign { Assign.target; annotation = None; value; parent = None };
    }
end

and If : sig
  type t = {
    test: Expression.t;
    body: Statement.t list;
    orelse: Statement.t list;
  }
  [@@deriving compare, eq, sexp, show, hash, to_yojson]
end = struct
  type t = {
    test: Expression.t;
    body: Statement.t list;
    orelse: Statement.t list;
  }
  [@@deriving compare, eq, sexp, show, hash, to_yojson]
end

and Try : sig
  module Handler : sig
    type t = {
      kind: Expression.t option;
      name: Identifier.t option;
      body: Statement.t list;
    }
    [@@deriving compare, eq, sexp, show, hash, to_yojson]
  end

  type t = {
    body: Statement.t list;
    handlers: Handler.t list;
    orelse: Statement.t list;
    finally: Statement.t list;
  }
  [@@deriving compare, eq, sexp, show, hash, to_yojson]

  val preamble : Handler.t -> Statement.t list
end = struct
  module Handler = struct
    type t = {
      kind: Expression.t option;
      name: Identifier.t option;
      body: Statement.t list;
    }
    [@@deriving compare, eq, sexp, show, hash, to_yojson]
  end

  type t = {
    body: Statement.t list;
    handlers: Handler.t list;
    orelse: Statement.t list;
    finally: Statement.t list;
  }
  [@@deriving compare, eq, sexp, show, hash, to_yojson]

  let preamble { Handler.kind; name; _ } =
    let open Expression in
    let assume ~location ~target ~annotation =
      [
        {
          Node.location;
          value =
            Statement.Assign
              {
                Assign.target;
                annotation = None;
                value = Node.create ~location Ellipsis;
                parent = None;
              };
        };
        {
          Node.location;
          value =
            Assert
              {
                Assert.test =
                  {
                    Node.location;
                    value =
                      Call
                        {
                          callee = { Node.location; value = Name (Name.Identifier "isinstance") };
                          arguments =
                            [
                              { Call.Argument.name = None; value = target };
                              { Call.Argument.name = None; value = annotation };
                            ];
                        };
                  };
                message = None;
                origin = Assert.Origin.Assertion;
              };
        };
      ]
    in
    match kind, name with
    | Some ({ Node.location; value = Name _; _ } as annotation), Some name ->
        assume ~location ~target:{ Node.location; value = Name (Name.Identifier name) } ~annotation
    | Some { Node.location; value = Tuple values; _ }, Some name ->
        let annotation =
          {
            Node.location;
            value =
              Call
                {
                  callee =
                    {
                      Node.location;
                      value =
                        Name
                          (Name.Attribute
                             {
                               base =
                                 {
                                   Node.location;
                                   value =
                                     Name
                                       (Name.Attribute
                                          {
                                            base =
                                              {
                                                Node.location;
                                                value = Name (Name.Identifier "typing");
                                              };
                                            attribute = "Union";
                                            special = false;
                                          });
                                 };
                               attribute = "__getitem__";
                               special = true;
                             });
                    };
                  arguments =
                    [
                      { Call.Argument.name = None; value = { Node.location; value = Tuple values } };
                    ];
                };
          }
        in
        assume ~location ~target:{ Node.location; value = Name (Name.Identifier name) } ~annotation
    | Some ({ Node.location; _ } as expression), _ ->
        (* Insert raw `kind` so that we type check the expression. *)
        [Node.create ~location (Statement.Expression expression)]
    | _ -> []
end

and While : sig
  type t = {
    test: Expression.t;
    body: Statement.t list;
    orelse: Statement.t list;
  }
  [@@deriving compare, eq, sexp, show, hash, to_yojson]
end = struct
  type t = {
    test: Expression.t;
    body: Statement.t list;
    orelse: Statement.t list;
  }
  [@@deriving compare, eq, sexp, show, hash, to_yojson]
end

and With : sig
  type t = {
    items: (Expression.t * Expression.t option) list;
    body: Statement.t list;
    async: bool;
  }
  [@@deriving compare, eq, sexp, show, hash, to_yojson]

  val preamble : t -> Statement.t list
end = struct
  type t = {
    items: (Expression.t * Expression.t option) list;
    body: Statement.t list;
    async: bool;
  }
  [@@deriving compare, eq, sexp, show, hash, to_yojson]

  let preamble { items; async; _ } =
    let preamble (({ Node.location; _ } as expression), target) =
      target
      >>| (fun target ->
            let open Expression in
            let enter_call =
              let create_call call_name =
                {
                  Node.location;
                  value =
                    Call
                      {
                        callee =
                          {
                            Node.location;
                            value =
                              Name
                                (Name.Attribute
                                   { base = expression; attribute = call_name; special = true });
                          };
                        arguments = [];
                      };
                }
              in
              if async then
                Node.create ~location (Await (create_call "__aenter__"))
              else
                create_call "__enter__"
            in
            let assign = { Assign.target; annotation = None; value = enter_call; parent = None } in
            Node.create ~location (Statement.Assign assign))
      |> Option.value ~default:(Node.create ~location (Statement.Expression expression))
    in
    List.map items ~f:preamble
end

and Statement : sig
  type statement =
    | Assign of Assign.t
    | Assert of Assert.t
    | Break
    | Class of Class.t
    | Continue
    | Define of Define.t
    | Delete of Expression.t
    | Expression of Expression.t
    | For of For.t
    | Global of Identifier.t list
    | If of If.t
    | Import of Import.t
    | Nonlocal of Identifier.t list
    | Pass
    | Raise of Raise.t
    | Return of Return.t
    | Try of Try.t
    | With of With.t
    | While of While.t
    | Yield of Expression.t
    | YieldFrom of Expression.t
  [@@deriving compare, eq, sexp, hash, to_yojson]

  type t = statement Node.t [@@deriving compare, eq, sexp, show, hash, to_yojson]

  val assume : ?origin:Assert.Origin.t -> Expression.t -> t

  val terminates : t list -> bool

  val generator_assignment : Expression.t Expression.Comprehension.generator -> Assign.t

  val extract_docstring : t list -> string option
end = struct
  type statement =
    | Assign of Assign.t
    | Assert of Assert.t
    | Break
    | Class of Class.t
    | Continue
    | Define of Define.t
    | Delete of Expression.t
    | Expression of Expression.t
    | For of For.t
    | Global of Identifier.t list
    | If of If.t
    | Import of Import.t
    | Nonlocal of Identifier.t list
    | Pass
    | Raise of Raise.t
    | Return of Return.t
    | Try of Try.t
    | With of With.t
    | While of While.t
    | Yield of Expression.t
    | YieldFrom of Expression.t
  [@@deriving compare, eq, sexp, show, hash, to_yojson]

  type t = statement Node.t [@@deriving compare, eq, sexp, show, hash, to_yojson]

  let assume ?(origin = Assert.Origin.Assertion) ({ Node.location; _ } as test) =
    { Node.location; value = Assert { Assert.test; message = None; origin } }


  (* Naive assumptions *)
  let terminates body =
    let find_terminator = function
      | { Node.value = Return _; _ }
      | { Node.value = Raise _; _ }
      | { Node.value = Continue; _ } ->
          true
      | _ -> false
    in
    Option.is_some (List.find ~f:find_terminator body)


  let extract_docstring statements =
    (* See PEP 257 for Docstring formatting. The main idea is that we want to get the shortest
     * indentation from line 2 onwards as the indentation of the docstring. *)
    let unindent docstring =
      let indentation line =
        let line_without_indentation = String.lstrip line in
        String.length line - String.length line_without_indentation
      in
      match String.split ~on:'\n' docstring with
      | [] -> docstring
      | first :: rest ->
          let difference =
            List.map rest ~f:indentation |> List.fold ~init:Int.max_value ~f:Int.min
          in
          let rest = List.map rest ~f:(fun s -> String.drop_prefix s difference) in
          String.concat ~sep:"\n" (first :: rest)
    in
    match statements with
    | {
        Node.value =
          Expression { Node.value = Expression.String { Expression.StringLiteral.value; _ }; _ };
        _;
      }
      :: _ ->
        Some (unindent value)
    | _ -> None


  let generator_assignment
      { Expression.Comprehension.target; iterator = { Node.location; _ } as iterator; async; _ }
    =
    let value =
      if async then
        let aiter =
          {
            Node.location;
            value =
              Expression.Call
                {
                  callee =
                    {
                      Node.location;
                      value =
                        Name
                          (Name.Attribute
                             { base = iterator; attribute = "__aiter__"; special = true });
                    };
                  arguments = [];
                };
          }
        in
        {
          Node.location;
          value =
            Expression.Call
              {
                callee =
                  {
                    Node.location;
                    value =
                      Name
                        (Name.Attribute { base = aiter; attribute = "__anext__"; special = true });
                  };
                arguments = [];
              };
        }
        |> fun target -> Node.create ~location (Expression.Await target)
      else
        let iter =
          {
            Node.location;
            value =
              Expression.Call
                {
                  callee =
                    {
                      Node.location;
                      value =
                        Name
                          (Name.Attribute
                             { base = iterator; attribute = "__iter__"; special = true });
                    };
                  arguments = [];
                };
          }
        in
        {
          Node.location;
          value =
            Expression.Call
              {
                callee =
                  {
                    Node.location;
                    value =
                      Name (Name.Attribute { base = iter; attribute = "__next__"; special = true });
                  };
                arguments = [];
              };
        }
    in
    { Assign.target; annotation = None; value; parent = None }
end

include Statement

let _ = show (* shadowed below *)

module PrettyPrinter = struct
  let pp_decorators formatter = function
    | [] -> ()
    | decorators ->
        Format.fprintf formatter "@[<v>@@(%a)@;@]" Expression.pp_expression_list decorators


  let pp_reference_option formatter = function
    | None -> ()
    | Some reference -> Format.fprintf formatter "%a" Reference.pp reference


  let pp_list formatter pp sep list =
    let rec pp' formatter = function
      | [] -> ()
      | [x] -> Format.fprintf formatter "%a" pp x
      | x :: xs -> Format.fprintf formatter ("%a" ^^ sep ^^ "%a") pp x pp' xs
    in
    pp' formatter list


  let pp_option ?(prefix = "") ?(suffix = "") formatter option pp =
    Option.value_map option ~default:() ~f:(fun value ->
        Format.fprintf formatter "%s%a%s" prefix pp value suffix)


  let pp_expression_option formatter (prefix, option) =
    pp_option ~prefix formatter option Expression.pp


  let pp_async formatter = function
    | true -> Format.fprintf formatter "async@;"
    | false -> ()


  let rec pp_statement_t formatter { Node.value = statement; _ } =
    Format.fprintf formatter "%a" pp_statement statement


  and pp_statement_list formatter = function
    | [] -> ()
    | [statement] -> Format.fprintf formatter "%a" pp_statement_t statement
    | statement :: statement_list ->
        Format.fprintf formatter "%a@;%a" pp_statement_t statement pp_statement_list statement_list


  and pp_assign formatter { Assign.target; annotation; value; parent } =
    Format.fprintf
      formatter
      "%a%a%a = %a"
      pp_reference_option
      parent
      Expression.pp
      target
      pp_expression_option
      (": ", annotation)
      Expression.pp
      value


  and pp_class formatter { Class.name; bases; body; decorators; _ } =
    Format.fprintf
      formatter
      "%a@[<v 2>class %a(%a):@;@[<v>%a@]@;@]"
      pp_decorators
      decorators
      Reference.pp
      name
      Expression.pp_expression_argument_list
      bases
      pp_statement_list
      body


  and pp_define
      formatter
      {
        Define.signature = { name; parameters; decorators; return_annotation; async; parent; _ };
        body;
      }
    =
    let return_annotation =
      match return_annotation with
      | Some annotation -> Format.asprintf " -> %a" Expression.pp annotation
      | _ -> ""
    in
    Format.fprintf
      formatter
      "%a@[<v 2>%adef %a%s%a(%a)%s:@;%a@]@."
      pp_decorators
      decorators
      pp_async
      async
      pp_reference_option
      parent
      (if Option.is_some parent then "#" else "")
      Reference.pp
      name
      Expression.pp_expression_parameter_list
      parameters
      return_annotation
      pp_statement_list
      body


  and pp_statement formatter statement =
    match statement with
    | Assign assign -> Format.fprintf formatter "%a" pp_assign assign
    | Assert { Assert.test; Assert.message; _ } ->
        Format.fprintf
          formatter
          "assert %a, %a"
          Expression.pp
          test
          pp_expression_option
          ("", message)
    | Break -> Format.fprintf formatter "break"
    | Class definition -> Format.fprintf formatter "%a" pp_class definition
    | Continue -> Format.fprintf formatter "continue"
    | Define define -> Format.fprintf formatter "%a" pp_define define
    | Delete expression -> Format.fprintf formatter "del %a" Expression.pp expression
    | Expression expression -> Expression.pp formatter expression
    | For { For.target; iterator; body; orelse; async } ->
        Format.fprintf
          formatter
          "@[<v 2>%afor %a in %a:@;%a@]%a"
          pp_async
          async
          Expression.pp
          target
          Expression.pp
          iterator
          pp_statement_list
          body
          pp_statement_list
          orelse
    | Global globals -> Format.fprintf formatter "global %s" (String.concat globals ~sep:", ")
    | If { If.test; body; orelse } ->
        if List.is_empty orelse then
          Format.fprintf
            formatter
            "@[<v>@[<v 2>if %a:@;%a@]@]@;"
            Expression.pp
            test
            pp_statement_list
            body
        else
          Format.fprintf
            formatter
            "@[<v>@[<v 2>if %a:@;%a@]@]@;@[<v 2>else:@;%a@]"
            Expression.pp
            test
            pp_statement_list
            body
            pp_statement_list
            orelse
    | Import { Import.from; imports } -> (
        let pp_import formatter { Import.name; alias } =
          Format.fprintf formatter "%a%a" Reference.pp name pp_reference_option alias
        in
        let pp_imports formatter import_list = pp_list formatter pp_import ", " import_list in
        match from with
        | None -> Format.fprintf formatter "@[<v>import %a@]" pp_imports imports
        | Some from ->
            Format.fprintf
              formatter
              "@[<v>from %a import %a@]"
              Reference.pp
              from
              pp_imports
              imports )
    | Nonlocal nonlocal_list -> pp_list formatter String.pp "," nonlocal_list
    | Pass -> Format.fprintf formatter "%s" "pass"
    | Raise { Raise.expression; _ } ->
        Format.fprintf formatter "raise %a" pp_expression_option ("", expression)
    | Return { Return.expression; _ } ->
        Format.fprintf formatter "return %a" pp_expression_option ("", expression)
    | Try { Try.body; handlers; orelse; finally } ->
        let pp_try_block formatter body =
          Format.fprintf formatter "@[<v 2>try:@;%a@]" pp_statement_list body
        in
        let pp_except_block formatter handlers =
          let pp_as formatter name = pp_option ~prefix:" as " formatter name String.pp in
          let pp_handler formatter { Try.Handler.kind; name; body } =
            Format.fprintf
              formatter
              "@[<v 2>except%a%a:@;%a@]"
              pp_expression_option
              (" ", kind)
              pp_as
              name
              pp_statement_list
              body
          in
          let pp_handler_list formatter handler_list =
            pp_list formatter pp_handler "@;" handler_list
          in
          Format.fprintf formatter "%a" pp_handler_list handlers
        in
        let pp_else_block formatter = function
          | [] -> ()
          | orelse -> Format.fprintf formatter "@[<v 2>else:@;%a@]" pp_statement_list orelse
        in
        let pp_finally_block formatter = function
          | [] -> ()
          | finally ->
              Format.fprintf formatter "@[<v 2>finally:@;@[<v>%a@]@]" pp_statement_list finally
        in
        Format.fprintf
          formatter
          "@[<v>%a@;%a@;%a@;%a@]"
          pp_try_block
          body
          pp_except_block
          handlers
          pp_else_block
          orelse
          pp_finally_block
          finally
    | With { With.items; body; async } ->
        let pp_item formatter (expression, expression_option) =
          Format.fprintf
            formatter
            "%a%a"
            Expression.pp
            expression
            pp_expression_option
            (" as ", expression_option)
        in
        let rec pp_item_list formatter = function
          | [] -> ()
          | [item] -> Format.fprintf formatter "%a" pp_item item
          | item :: item_list ->
              Format.fprintf formatter "%a,%a" pp_item item pp_item_list item_list
        in
        Format.fprintf
          formatter
          "@[<v 2>%a with %a:@;%a@]"
          pp_async
          async
          pp_item_list
          items
          pp_statement_list
          body
    | While { While.test; body; orelse } ->
        Format.fprintf
          formatter
          "@[<v 2>while %a:@;%a@]@[<v>%a@]"
          Expression.pp
          test
          pp_statement_list
          body
          pp_statement_list
          orelse
    | Yield expression -> Format.fprintf formatter "yield %a" Expression.pp expression
    | YieldFrom expression -> Format.fprintf formatter "yield from %a" Expression.pp expression


  let pp = pp_statement_t
end

let pp = PrettyPrinter.pp

let show statement = Format.asprintf "%a" pp statement

let pp_statement = PrettyPrinter.pp_statement

let show_statement statement = Format.asprintf "%a" pp_statement statement
