(*
 * Copyright 2018, Data61
 * Commonwealth Scientific and Industrial Research Organisation (CSIRO)
 * ABN 41 687 119 230.
 *
 * This software may be distributed and modified according to the terms of
 * the BSD 2-Clause license. Note that NO WARRANTY is provided.
 * See "LICENSE_BSD2.txt" for details.
 *
 * @TAG(DATA61_BSD)
 *)

theory ProofTrace
  imports
    Main
    "ML_Old"
    Data
    CogentHelper
begin

(* begin: tactic trace code *)
(* Proof of concept implementation. DO NOT USE THIS CODE *)
ML \<open>
datatype 'tag TraceSuccess = TraceSuccess of { goal : thm
                                             , succeeded : 'tag TraceSubgoal list
                                             , theorem : thm
                                             }
     and 'tag TraceFailure = TraceFailure of { goal : thm
                                             , failed_subgoal : thm
                                             , fail_steps : 'tag TraceFailure list
                                             }
     and 'tag TraceSubgoal = TraceSubgoal of { subgoal : thm
                                             , subtheorem : thm (* same as `#theorem subproof` *) 
                                             , subproof : 'tag TraceSuccess
                                             }

fun TraceSuccess_erase_backtracking x = x
\<close>


ML \<open>

type ttag = TTyping_Tactics.tac option

fun trace_solve_tac (ctxt : Proof.context)
                    (get_tacs : 'data -> ('data * ttag * tactic))
                    (data0 : 'data)
                    (goal0 : thm)
                    : 'data * (ttag TraceFailure, ttag TraceSuccess) Either =
  let val subgoals0 = Thm.prems_of goal0
  in
  (* special case, technically would be covered by solve *)
  if null subgoals0 then (data0, TraceSuccess { goal = goal0, theorem = goal0, succeeded = [] } |> Right) else
  let
    fun solve data goal subproofs_rev =
        case Thm.nprems_of goal of
          0 => (data, TraceSuccess { goal = goal0
                                    , theorem = goal
                                    , succeeded = rev subproofs_rev
                                    } |> Right)
        | _ =>
              let
                val subgoal_term = Thm.cprem_of goal 1
                (* Try all results from all tactics until we obtain a successful proof.
                 * NB: tactics should return finite results! *)
                val subgoal = Goal.init subgoal_term
                (* try all the tactics in the list to solve subgoal *)
                val (data', tag, tactic) = get_tacs data
                (* try to find a result from the tactic which solves the subgoal  *)
                fun try_results tactic_results fails =
                    case Seq.pull tactic_results of
                        NONE => (data', Left fails) (* the tactic failed *)
                      | SOME (subgoal', _) => solve_subgoal subgoal' fails
                (* recursively solve subgoal' *)
                and solve_subgoal subgoal' _ =
                  case trace_solve_tac ctxt get_tacs data' subgoal'
                  of
                    (_, Left fail) => (data', Left [ fail ])
                  | (data, Right (trace as TraceSuccess trace')) =>
                      (data, TraceSubgoal { subgoal = subgoal
                                          , subtheorem = #theorem trace'
                                          , subproof = trace
                                          } |> Right)
               in case try_results (tactic subgoal) [] of
                      (_, Left fails) => (data, TraceFailure
                                                { goal = goal0
                                                , failed_subgoal = subgoal
                                                , fail_steps = fails
                                                } |> Left)
                    | (data, Right (subproof as TraceSubgoal subproof')) =>
                          let val subtheorem = #subtheorem subproof' in
                          case resolve_tac ctxt [Goal.finish ctxt subtheorem] 1 goal |> Seq.pull of
                              NONE =>
                                let
                                  val errval = ("trace_solve_tac: could not apply subgoal proof, no resolve",
                                                 0, [goal, subtheorem])
                                  val _ = log_error (@{make_string} errval)
                                in
                                  raise THM errval
                                end
                            | SOME (goal', _) =>
                                  if Thm.nprems_of goal' + 1 = Thm.nprems_of goal then
                                     solve data goal' (subproof :: subproofs_rev)
                                  else
                                    let
                                      val errval = ("trace_solve_tac: could not apply subgoal proof, resolve didn't solve",
                                                  0, [goal, subtheorem])
                                      val _ = log_error (@{make_string} errval)
                                    in
                                      raise THM errval
                                    end
                          end
               end
    in solve data0 goal0 [] end
  end
\<close>
(* end: tactic trace code *)

(* extract relevant subproofs *)
ML \<open>
fun filter_trace PSuccess PSubgoal (TraceSuccess tr) =
      if not (PSuccess tr) then [] else
        [ Tree (#theorem tr,
                List.concat (map (filter_TraceSubgoal PSuccess PSubgoal) (#succeeded tr))) ]
and filter_TraceSubgoal PSuccess PSubgoal (TraceSubgoal tr) =
      if not (PSubgoal tr) then [] else filter_trace PSuccess PSubgoal (#subproof tr);


fun get_failing_goal (TraceFailure {failed_subgoal, fail_steps = (trace :: _), ...}) =
  failed_subgoal :: get_failing_goal trace
| get_failing_goal (TraceFailure {failed_subgoal, fail_steps = [], ...}) =
  failed_subgoal :: []

fun is_const n (Const (name, _)) = n = name
  | is_const _ _ = false;

fun unprop (Const (@{const_name Pure.prop}, _) $ t) = unprop t
  | unprop (Const (@{const_name Pure.imp}, _) $ _ $ t) = unprop t
  | unprop (Const (@{const_name Pure.all}, _) $ t) = unprop t
  | unprop (Const (@{const_name HOL.Trueprop}, _) $ t) = unprop t
  | unprop t = t;
\<close>

ML \<open>
fun extract_subproofs goal tactics is_interesting ctxt =
  trace_solve_tac ctxt
    (fn n => (if n >= length tactics
              then raise (ERROR ("bad subscript for tactics list, len: " ^ (@{make_string} (length tactics)) ^ ", idx: " ^ (@{make_string} n)))
              else nth tactics n |> (fn (tag, tac) => (n+1, tag, tac))))
    0
    (Goal.init goal)
  |> (fn (_, result) =>
        mapEitherR
          (fn tr => filter_trace (is_interesting o unprop o Thm.prop_of o #theorem) (K true) tr)
          result)
\<close>

end