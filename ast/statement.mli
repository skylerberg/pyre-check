(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

module Assign : sig
  type t = {
    target: Expression.t;
    annotation: Expression.t option;
    value: Expression.t;
    parent: Reference.t option;
  }
  [@@deriving compare, eq, sexp, show, hash]

  val is_static_attribute_initialization : t -> bool
end

module Import : sig
  type import = {
    name: Reference.t;
    alias: Reference.t option;
  }
  [@@deriving compare, eq, sexp, show, hash]

  type t = {
    from: Reference.t option;
    imports: import list;
  }
  [@@deriving compare, eq, sexp, show, hash]
end

module Raise : sig
  type t = {
    expression: Expression.t option;
    from: Expression.t option;
  }
  [@@deriving compare, eq, sexp, show, hash, to_yojson]
end

module Return : sig
  type t = {
    is_implicit: bool;
    expression: Expression.t option;
  }
  [@@deriving compare, eq, sexp, show, hash]
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

    val has_return_annotation : t -> bool [@@deriving compare, eq, sexp, show, hash, to_yojson]
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

  val is_property_setter : t -> bool

  val is_property : t -> bool

  val is_untyped : t -> bool

  val is_stub : t -> bool

  val is_toplevel : t -> bool

  val is_class_toplevel : t -> bool

  val dump : t -> bool

  val dump_cfg : t -> bool

  val dump_locations : t -> bool

  val show_json : t -> string

  val implicit_attributes : t -> definition:Class.t -> Attribute.t Identifier.SerializableMap.t

  val has_decorator : ?match_prefix:bool -> t -> string -> bool

  val has_return_annotation : t -> bool
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
end

and If : sig
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
end

and While : sig
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
end

type statement = Statement.statement [@@deriving compare, eq, sexp, show, hash, to_yojson]

type t = Statement.t [@@deriving compare, eq, sexp, show, hash, to_yojson]
