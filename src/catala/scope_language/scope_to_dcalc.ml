(* This file is part of the Catala compiler, a specification language for tax and social benefits
   computation rules. Copyright (C) 2020 Inria, contributor: Denis Merigoux
   <denis.merigoux@inria.fr>

   Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except
   in compliance with the License. You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software distributed under the License
   is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
   or implied. See the License for the specific language governing permissions and limitations under
   the License. *)

module Pos = Utils.Pos
module Errors = Utils.Errors
module Cli = Utils.Cli

type scope_sigs_ctx = ((Ast.ScopeVar.t * Dcalc.Ast.typ) list * Dcalc.Ast.Var.t) Ast.ScopeMap.t

type ctx = {
  scopes_parameters : scope_sigs_ctx;
  scope_vars : (Dcalc.Ast.Var.t * Dcalc.Ast.typ) Ast.ScopeVarMap.t;
  subscope_vars : (Dcalc.Ast.Var.t * Dcalc.Ast.typ) Ast.ScopeVarMap.t Ast.SubScopeMap.t;
  local_vars : Dcalc.Ast.Var.t Ast.VarMap.t;
}

let empty_ctx (scopes_ctx : scope_sigs_ctx) =
  {
    scopes_parameters = scopes_ctx;
    scope_vars = Ast.ScopeVarMap.empty;
    subscope_vars = Ast.SubScopeMap.empty;
    local_vars = Ast.VarMap.empty;
  }

type scope_ctx = Dcalc.Ast.Var.t Ast.ScopeMap.t

let hole_var : Dcalc.Ast.Var.t = Dcalc.Ast.Var.make ("·", Pos.no_pos)

let merge_defaults (caller : Dcalc.Ast.expr Pos.marked Bindlib.box)
    (callee : Dcalc.Ast.expr Pos.marked Bindlib.box) : Dcalc.Ast.expr Pos.marked Bindlib.box =
  let caller =
    Dcalc.Ast.make_app caller
      [ Bindlib.box (Dcalc.Ast.ELit Dcalc.Ast.LUnit, Pos.no_pos) ]
      Pos.no_pos
  in
  let body =
    Bindlib.box_apply2
      (fun caller callee ->
        ( Dcalc.Ast.EDefault
            ((Dcalc.Ast.ELit (Dcalc.Ast.LBool true), Pos.no_pos), caller, [ callee ]),
          Pos.no_pos ))
      caller callee
  in
  let silent = Dcalc.Ast.Var.make ("_", Pos.no_pos) in
  Dcalc.Ast.make_abs
    (Array.of_list [ silent ])
    body Pos.no_pos [ (Dcalc.Ast.TUnit, Pos.no_pos) ] Pos.no_pos

let rec translate_expr (ctx : ctx) (e : Ast.expr Pos.marked) : Dcalc.Ast.expr Pos.marked Bindlib.box
    =
  Bindlib.box_apply
    (fun (x : Dcalc.Ast.expr) -> Pos.same_pos_as x e)
    ( match Pos.unmark e with
    | EVar v -> Bindlib.box_apply Pos.unmark (Bindlib.box_var (Ast.VarMap.find v ctx.local_vars))
    | ELit l -> Bindlib.box (Dcalc.Ast.ELit l)
    | EApp (e1, args) ->
        Bindlib.box_apply2
          (fun e u -> Dcalc.Ast.EApp (e, u))
          (translate_expr ctx e1)
          (Bindlib.box_list (List.map (translate_expr ctx) args))
    | EAbs (pos_binder, binder, typ) ->
        let xs, body = Bindlib.unmbind binder in
        let new_xs = Array.map (fun x -> Dcalc.Ast.Var.make (Bindlib.name_of x, pos_binder)) xs in
        let both_xs = Array.map2 (fun x new_x -> (x, new_x)) xs new_xs in
        let body =
          translate_expr
            {
              ctx with
              local_vars =
                Array.fold_left
                  (fun local_vars (x, new_x) -> Ast.VarMap.add x new_x local_vars)
                  ctx.local_vars both_xs;
            }
            body
        in
        let binder = Bindlib.bind_mvar new_xs body in
        Bindlib.box_apply (fun b -> Dcalc.Ast.EAbs (pos_binder, b, typ)) binder
    | EDefault (just, cons, subs) ->
        Bindlib.box_apply3
          (fun j c s -> Dcalc.Ast.EDefault (j, c, s))
          (translate_expr ctx just) (translate_expr ctx cons)
          (Bindlib.box_list (List.map (translate_expr ctx) subs))
    | ELocation (ScopeVar a) ->
        Bindlib.box_apply Pos.unmark
          (Bindlib.box_var (fst (Ast.ScopeVarMap.find (Pos.unmark a) ctx.scope_vars)))
    | ELocation (SubScopeVar (_, s, a)) -> (
        try
          Bindlib.box_apply Pos.unmark
            (Bindlib.box_var
               (fst
                  (Ast.ScopeVarMap.find (Pos.unmark a)
                     (Ast.SubScopeMap.find (Pos.unmark s) ctx.subscope_vars))))
        with Not_found ->
          Errors.raise_spanned_error
            (Format.asprintf
               "The variable %a.%a cannot be used here, as subscope %a's results will not have \
                been computed yet"
               Ast.SubScopeName.format_t (Pos.unmark s) Ast.ScopeVar.format_t (Pos.unmark a)
               Ast.SubScopeName.format_t (Pos.unmark s))
            (Pos.get_position e) )
    | EIfThenElse (cond, et, ef) ->
        Bindlib.box_apply3
          (fun c t f -> Dcalc.Ast.EIfThenElse (c, t, f))
          (translate_expr ctx cond) (translate_expr ctx et) (translate_expr ctx ef)
    | EOp op -> Bindlib.box (Dcalc.Ast.EOp op) )

let rec translate_rule (ctx : ctx) (rule : Ast.rule) (rest : Ast.rule list) (pos_sigma : Pos.t) :
    Dcalc.Ast.expr Pos.marked Bindlib.box * ctx =
  match rule with
  | Definition ((ScopeVar a, var_def_pos), tau, e) ->
      let a_name = Ast.ScopeVar.get_info (Pos.unmark a) in
      let a_var = Dcalc.Ast.Var.make a_name in
      let apply_thunked =
        Bindlib.box_apply2
          (fun e u -> (Dcalc.Ast.EApp (e, u), var_def_pos))
          (Bindlib.box_var a_var)
          (Bindlib.box_list [ Bindlib.box (Dcalc.Ast.ELit LUnit, var_def_pos) ])
      in
      let new_ctx =
        {
          ctx with
          scope_vars = Ast.ScopeVarMap.add (Pos.unmark a) (a_var, Pos.unmark tau) ctx.scope_vars;
        }
      in
      let next_e, new_ctx = translate_rules new_ctx rest pos_sigma in
      let next_e =
        Dcalc.Ast.make_let_in (a_var, var_def_pos) tau apply_thunked next_e (Pos.get_position a)
      in
      let intermediate_e =
        Dcalc.Ast.make_abs
          (Array.of_list [ a_var ])
          next_e (Pos.get_position a)
          [ (Dcalc.Ast.TArrow ((TUnit, var_def_pos), tau), var_def_pos) ]
          (Pos.get_position e)
      in
      let new_e = translate_expr ctx e in
      let a_expr = Dcalc.Ast.make_var a_var in
      let merged_expr = merge_defaults a_expr new_e in
      let out_e = Dcalc.Ast.make_app intermediate_e [ merged_expr ] (Pos.get_position e) in
      (out_e, new_ctx)
  | Definition ((SubScopeVar (_subs_name, subs_index, subs_var), var_def_pos), tau, e) ->
      let a_name =
        Pos.map_under_mark
          (fun str -> str ^ "." ^ Pos.unmark (Ast.ScopeVar.get_info (Pos.unmark subs_var)))
          (Ast.SubScopeName.get_info (Pos.unmark subs_index))
      in
      let a_var = Dcalc.Ast.Var.make a_name in
      let new_ctx =
        {
          ctx with
          subscope_vars =
            Ast.SubScopeMap.update (Pos.unmark subs_index)
              (fun map ->
                match map with
                | Some map ->
                    Some (Ast.ScopeVarMap.add (Pos.unmark subs_var) (a_var, Pos.unmark tau) map)
                | None ->
                    Some (Ast.ScopeVarMap.singleton (Pos.unmark subs_var) (a_var, Pos.unmark tau)))
              ctx.subscope_vars;
        }
      in
      let next_e, new_ctx = translate_rules new_ctx rest pos_sigma in
      let intermediate_e =
        Dcalc.Ast.make_abs
          (Array.of_list [ a_var ])
          next_e var_def_pos
          [ (Dcalc.Ast.TArrow ((TUnit, var_def_pos), tau), var_def_pos) ]
          (Pos.get_position e)
      in
      let new_e = translate_expr ctx e in
      let silent_var = Dcalc.Ast.Var.make ("_", Pos.no_pos) in
      let thunked_new_e =
        Dcalc.Ast.make_abs
          (Array.of_list [ silent_var ])
          new_e var_def_pos
          [ (Dcalc.Ast.TUnit, var_def_pos) ]
          var_def_pos
      in
      let out_e = Dcalc.Ast.make_app intermediate_e [ thunked_new_e ] (Pos.get_position e) in
      (out_e, new_ctx)
  | Call (subname, subindex) ->
      let all_subscope_vars, scope_dcalc_var = Ast.ScopeMap.find subname ctx.scopes_parameters in
      let subscope_vars_defined =
        try Ast.SubScopeMap.find subindex ctx.subscope_vars
        with Not_found -> Ast.ScopeVarMap.empty
      in
      let subscope_var_not_yet_defined subvar =
        not (Ast.ScopeVarMap.mem subvar subscope_vars_defined)
      in
      let subscope_args =
        List.map
          (fun (subvar, _) ->
            if subscope_var_not_yet_defined subvar then
              Bindlib.box Dcalc.Interpreter.empty_thunked_term
            else
              let a_var, _ = Ast.ScopeVarMap.find subvar subscope_vars_defined in
              Bindlib.box_var a_var)
          all_subscope_vars
      in
      let all_subscope_vars_dcalc =
        List.map
          (fun (subvar, tau) ->
            let sub_dcalc_var =
              Dcalc.Ast.Var.make
                (Pos.map_under_mark
                   (fun s -> Pos.unmark (Ast.SubScopeName.get_info subindex) ^ "." ^ s)
                   (Ast.ScopeVar.get_info subvar))
            in
            (subvar, tau, sub_dcalc_var))
          all_subscope_vars
      in
      let new_ctx =
        {
          ctx with
          subscope_vars =
            Ast.SubScopeMap.add subindex
              (List.fold_left
                 (fun acc (var, tau, dvar) -> Ast.ScopeVarMap.add var (dvar, tau) acc)
                 Ast.ScopeVarMap.empty all_subscope_vars_dcalc)
              ctx.subscope_vars;
        }
      in
      let call_expr =
        Bindlib.box_apply2
          (fun e u -> (Dcalc.Ast.EApp (e, u), Pos.no_pos))
          (Bindlib.box_var scope_dcalc_var) (Bindlib.box_list subscope_args)
      in
      let result_tuple_var = Dcalc.Ast.Var.make ("result", Pos.no_pos) in
      let next_e, new_ctx = translate_rules new_ctx rest pos_sigma in
      let results_bindings, _ =
        List.fold_right
          (fun (_, tau, dvar) (acc, i) ->
            let result_access =
              Bindlib.box_apply
                (fun r -> (Dcalc.Ast.ETupleAccess (r, i), pos_sigma))
                (Bindlib.box_var result_tuple_var)
            in
            ( Dcalc.Ast.make_let_in (dvar, pos_sigma) (tau, pos_sigma) result_access acc pos_sigma,
              i - 1 ))
          all_subscope_vars_dcalc
          (next_e, List.length all_subscope_vars_dcalc - 1)
      in
      ( Dcalc.Ast.make_let_in (result_tuple_var, pos_sigma)
          ( Dcalc.Ast.TTuple (List.map (fun (_, tau, _) -> (tau, pos_sigma)) all_subscope_vars_dcalc),
            pos_sigma )
          call_expr results_bindings pos_sigma,
        new_ctx )

and translate_rules (ctx : ctx) (rules : Ast.rule list) (pos_sigma : Pos.t) :
    Dcalc.Ast.expr Pos.marked Bindlib.box * ctx =
  match rules with
  | [] ->
      let scope_variables = Ast.ScopeVarMap.bindings ctx.scope_vars in
      let return_exp =
        Bindlib.box_apply
          (fun args -> (Dcalc.Ast.ETuple args, pos_sigma))
          (Bindlib.box_list
             (List.map (fun (_, (dcalc_var, _)) -> Bindlib.box_var dcalc_var) scope_variables))
      in
      (return_exp, ctx)
  | hd :: tl -> translate_rule ctx hd tl pos_sigma

let translate_scope_decl (sctx : scope_sigs_ctx) (sigma : Ast.scope_decl) :
    Dcalc.Ast.expr Pos.marked Bindlib.box =
  let ctx = empty_ctx sctx in
  let pos_sigma = Pos.get_position (Ast.ScopeName.get_info sigma.scope_decl_name) in
  let rules, ctx = translate_rules ctx sigma.scope_decl_rules pos_sigma in
  let scope_variables, _ = Ast.ScopeMap.find sigma.scope_decl_name sctx in
  let scope_variables =
    List.map
      (fun (x, tau) ->
        let dcalc_x, _ = Ast.ScopeVarMap.find x ctx.scope_vars in
        (x, tau, dcalc_x))
      scope_variables
  in
  Dcalc.Ast.make_abs
    (Array.of_list ((List.map (fun (_, _, x) -> x)) scope_variables))
    rules pos_sigma
    (List.map
       (fun (_, tau, _) ->
         (Dcalc.Ast.TArrow ((Dcalc.Ast.TUnit, pos_sigma), (tau, pos_sigma)), pos_sigma))
       scope_variables)
    pos_sigma

let build_scope_typ_from_sig (scope_sig : (Ast.ScopeVar.t * Dcalc.Ast.typ) list) (pos : Pos.t) :
    Dcalc.Ast.typ Pos.marked =
  let result_typ = (Dcalc.Ast.TTuple (List.map (fun (_, tau) -> (tau, pos)) scope_sig), pos) in
  List.fold_right
    (fun (_, arg_t) acc ->
      (Dcalc.Ast.TArrow ((Dcalc.Ast.TArrow ((TUnit, pos), (arg_t, pos)), pos), acc), pos))
    scope_sig result_typ

let translate_program (prgm : Ast.program) (top_level_scope_name : Ast.ScopeName.t) :
    Dcalc.Ast.expr Pos.marked =
  let scope_dependencies = Dependency.build_program_dep_graph prgm in
  Dependency.check_for_cycle scope_dependencies;
  let scope_ordering = Dependency.get_scope_ordering scope_dependencies in
  let sctx : scope_sigs_ctx =
    Ast.ScopeMap.map
      (fun scope ->
        let scope_dvar = Dcalc.Ast.Var.make (Ast.ScopeName.get_info scope.Ast.scope_decl_name) in
        ( List.map
            (fun (scope_var, tau) -> (scope_var, Pos.unmark tau))
            (Ast.ScopeVarMap.bindings scope.scope_sig),
          scope_dvar ))
      prgm
  in
  (* the final expression on which we build on is the variable of the top-level scope that we are
     returning *)
  let acc = Bindlib.box_var (snd (Ast.ScopeMap.find top_level_scope_name sctx)) in
  (* the resulting expression is the list of definitions of all the scopes, ending with the
     top-level scope. *)
  Bindlib.unbox
    (let acc =
       List.fold_right
         (fun scope_name (acc : Dcalc.Ast.expr Pos.marked Bindlib.box) ->
           let scope = Ast.ScopeMap.find scope_name prgm in
           let pos_scope = Pos.get_position (Ast.ScopeName.get_info scope.scope_decl_name) in
           let scope_expr = translate_scope_decl sctx scope in
           let scope_sig, dvar = Ast.ScopeMap.find scope_name sctx in
           let scope_typ = build_scope_typ_from_sig scope_sig pos_scope in
           Dcalc.Ast.make_let_in (dvar, pos_scope) scope_typ scope_expr acc pos_scope)
         scope_ordering acc
     in
     acc)
