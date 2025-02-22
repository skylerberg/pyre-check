(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Ast
open Analysis
open Expression

val is_local : Identifier.t -> bool

(* Evaluates to the representation of literal strings, integers and enums. *)
val extract_constant_name : Expression.t -> string option

val get_global_targets
  :  resolution:Resolution.t ->
  global:Reference.t ->
  (Callable.t * Type.Callable.implicit option) list

(* Evaluates to the list of indirect targets and the implicit self that needs to be passed in, if
   any. *)
val get_indirect_targets
  :  resolution:Resolution.t ->
  receiver:Expression.t ->
  method_name:Identifier.t ->
  (Callable.t * Type.Callable.implicit option) list * Call.Argument.t option

(* Given an attribute self.x, returns the underlying callable if x is a @property. *)
val resolve_property_targets
  :  resolution:Resolution.t ->
  base:Expression.t ->
  attribute:string ->
  (Callable.t * Type.Callable.implicit option) list option

(* Returns a normalized path and optional addition parameter prefix, e.g. for constructor calls *)
val normalize_global : resolution:Resolution.t -> Reference.t -> Reference.t * Call.Argument.t list

(* Returns all call targets from Call expressions in the given access *)
val resolve_call_targets
  :  resolution:Resolution.t ->
  Expression.Call.t ->
  (Callable.t * Type.Callable.implicit option) list

val resolve_ignoring_optional : resolution:Resolution.t -> Expression.t -> Type.t
