(* This file is part of the Catala build system, a specification language for
   tax and social benefits computation rules. Copyright (C) 2020 Inria,
   contributor: Emile Rolley <emile.rolley@tuta.io>

   Licensed under the Apache License, Version 2.0 (the "License"); you may not
   use this file except in compliance with the License. You may obtain a copy of
   the License at

   http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
   WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
   License for the specific language governing permissions and limitations under
   the License. *)

(** This library contains the implementations of utility functions used to
    generate {{:https://ninja-build.org} Ninja} build files in OCaml with almost
    no dependencies -- it only depends on
    {{:https://v3.ocaml.org/p/re/1.10.3/doc/Re/index.html} Re}. It's currently
    developed to be used by
    {{:https://github.com/CatalaLang/catala/tree/master/build_system} Clerk},
    the {{:https://catala-lang.org} Catala} build system. Therefore, the library
    {b supports only very basic features} required by Clerk. *)

(** {2 What is Ninja?} *)

(** {{:https://ninja-build.org} Ninja} is a low-level build system. It's
    designed to have its input files ({i build.ninja}) generated by a
    higher-level build system, and to run builds as fast as possible by
    supporting native cross-platform (Windows and Unix) parallel builds.

    See the {{:https://ninja-build.org/manual.html} manual} for more details. *)

(** {1 Ninja expressions} *)

(** Helper module to build ninja expressions. *)
module Expr : sig
  (** Represents a ninja expression. Which could be either a literal, a
      {{:https://ninja-build.org/manual.html#_variables} variable references}
      ($_) or a sequence of sub-expressions.

      {b Note:} for now, there are no visible differences between an [Expr.Seq]
      and a list of {!type: Expr.t}, indeed, in both cases, one space is added
      between each expression -- resp. sub-expression. The difference only comes
      from the semantic: an [Expr.Seq] is {b a unique} Ninja expression. *)
  type t =
    | Lit of string
    (* Literal string. *)
    | Var of string
    (* Variable reference. *)
    | Seq of t list
  (* Sequence of sub-expressions. *)

  val format : Format.formatter -> t -> unit
  (** [format fmt exp] outputs in [fmt] the string representation of the ninja
      expression [exp]. *)

  val format_list : Format.formatter -> t list -> unit
  (** [format fmt ls] outputs in [fmt] the string representation of a list [ls]
      of ninja expressions [exp] by adding a space between each expression. *)
end

(** {1 Ninja rules} *)

(** Helper module to build
    {{:https://ninja-build.org/manual.html#_rules} ninja rules}. *)
module Rule : sig
  type t = { name : string; command : Expr.t; description : Expr.t option }
  (** Represents the minimal ninja rule representation for Clerk:

      {[
        rule <name>
          command = <command>
          [description = <description>]
      ]} *)

  val make : string -> command:Expr.t -> description:Expr.t -> t
  (** [make name ~command ~description] returns the corresponding ninja
      {!type:Rule.t}. *)

  val format : Format.formatter -> t -> unit
  (** [format fmt rule] outputs in [fmt] the string representation of the ninja
      [rule]. *)
end

(** {1 Ninja builds} *)

(** Helper module to build ninja
    {{:https://ninja-build.org/manual.html#_build_statements} build statements}. *)
module Build : sig
  type t = {
    outputs : Expr.t list;
    rule : string;
    inputs : Expr.t list option;
    vars : (string * Expr.t) list;
  }
  (** Represents the minimal ninja build statement representation for Clerk:

      {[
        build <outputs>: <rule> [<inputs>]
          [<vars>]
      ]}*)

  val make : outputs:Expr.t list -> rule:string -> t
  (** [make ~outputs ~rule] returns the corresponding ninja {!type:Build.t} with
      no {!field:inputs} or {!field:vars}. *)

  val make_with_vars :
    outputs:Expr.t list -> rule:string -> vars:(string * Expr.t) list -> t
  (** [make_with_vars ~outputs ~rule ~vars] returns the corresponding ninja
      {!type:Build.t} with no {!field:inputs}. *)

  val make_with_inputs :
    outputs:Expr.t list -> rule:string -> inputs:Expr.t list -> t
  (** [make_with_vars ~outputs ~rule ~inputs] returns the corresponding ninja
      {!type:Build.t} with no {!field:vars}. *)

  val make_with_vars_and_inputs :
    outputs:Expr.t list ->
    rule:string ->
    inputs:Expr.t list ->
    vars:(string * Expr.t) list ->
    t
  (** [make_with_vars ~outputs ~rule ~inputs ~vars] returns the corresponding
      ninja {!type: Build.t}. *)

  val empty : t
  (** [empty] is the minimal ninja {!type:Build.t} with ["empty"] as
      {!field:outputs} and ["phony"] as {!field: rule}. *)

  val unpath : ?sep:string -> string -> string
  (** [unpath ~sep path] replaces all [/] occurences with [sep] in [path] to
      avoid ninja writing the corresponding file and use it as sub command. By
      default, [sep] is set to ["-"]. *)

  val format : Format.formatter -> t -> unit
  (** [format fmt build] outputs in [fmt] the string representation of the ninja
      [build]. *)
end

(** {1 Maps} *)

module RuleMap : Map.S with type key = String.t
module BuildMap : Map.S with type key = String.t

(** {1 Ninja} *)

type ninja = { rules : Rule.t RuleMap.t; builds : Build.t BuildMap.t }
(** Represents the minimal ninja architecture (list of rule and build
    statements) needed for clerk. *)

val empty : ninja
(** [empty] returns the empty empty ninja structure. *)

val format : Format.formatter -> ninja -> unit
(** [format fmt build] outputs in [fmt] the string representation of all
    [ninja.rules] and [ninja.builds]. *)
