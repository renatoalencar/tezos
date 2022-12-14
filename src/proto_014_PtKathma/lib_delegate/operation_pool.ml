(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2021 Nomadic Labs <contact@nomadic-labs.com>                *)
(*                                                                           *)
(* Permission is hereby granted, free of charge, to any person obtaining a   *)
(* copy of this software and associated documentation files (the "Software"),*)
(* to deal in the Software without restriction, including without limitation *)
(* the rights to use, copy, modify, merge, publish, distribute, sublicense,  *)
(* and/or sell copies of the Software, and to permit persons to whom the     *)
(* Software is furnished to do so, subject to the following conditions:      *)
(*                                                                           *)
(* The above copyright notice and this permission notice shall be included   *)
(* in all copies or substantial portions of the Software.                    *)
(*                                                                           *)
(* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR*)
(* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,  *)
(* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL   *)
(* THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER*)
(* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING   *)
(* FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER       *)
(* DEALINGS IN THE SOFTWARE.                                                 *)
(*                                                                           *)
(*****************************************************************************)

open Protocol
open Alpha_context

(* Should we use a better ordering ? *)

type 'collection t = {
  consensus : 'collection;
  votes : 'collection;
  anonymous : 'collection;
  managers : 'collection;
}

let compare_op op1 op2 =
  try Stdlib.compare op1 op2
  with _ ->
    (* FIXME some operations (e.g. tx_rollup_rejection) pack
       functional values which could raise an exception. In this
       specific case, we default to comparing their hashes. *)
    Operation_hash.compare
      (Alpha_context.Operation.hash_packed op1)
      (Alpha_context.Operation.hash_packed op2)

module Prioritized_operation = struct
  (* Higher priority operations will be included first *)
  type t = Prioritized of int * packed_operation | Low of packed_operation

  let extern ?(priority = 1) op = Prioritized (priority, op)

  let node op = Low op

  let packed = function Prioritized (_, op) | Low op -> op

  let compare_priority t1 t2 =
    match (t1, t2) with
    | Prioritized _, Low _ -> 1
    | Low _, Prioritized _ -> -1
    | Low _, Low _ -> 0
    | Prioritized (p0, _), Prioritized (p1, _) -> Compare.Int.compare p0 p1

  let compare a b =
    let c = compare_priority a b in
    if c <> 0 then c else compare_op (packed a) (packed b)
end

module Operation_set = Set.Make (struct
  type t = packed_operation

  let compare = compare_op
end)

module Prioritized_operation_set = struct
  include Set.Make (struct
    type t = Prioritized_operation.t

    let compare = Prioritized_operation.compare
  end)

  let operations set = elements set |> List.map Prioritized_operation.packed
end

(* TODO refine this: unpack operations *)
type pool = Operation_set.t t

(* TODO refine this: unpack operations *)
type ordered_pool = packed_operation list t

let ordered_pool_encoding =
  let open Data_encoding in
  conv
    (fun {consensus; votes; anonymous; managers} ->
      (consensus, votes, anonymous, managers))
    (fun (consensus, votes, anonymous, managers) ->
      {consensus; votes; anonymous; managers})
    (obj4
       (req "ordered_consensus" (list (dynamic_size Operation.encoding)))
       (req "ordered_votes" (list (dynamic_size Operation.encoding)))
       (req "ordered_anonymouns" (list (dynamic_size Operation.encoding)))
       (req "ordered_managers" (list (dynamic_size Operation.encoding))))

type payload = {
  votes_payload : packed_operation list;
  anonymous_payload : packed_operation list;
  managers_payload : packed_operation list;
}

let empty_payload =
  {votes_payload = []; anonymous_payload = []; managers_payload = []}

let payload_encoding =
  let open Data_encoding in
  conv
    (fun {votes_payload; anonymous_payload; managers_payload} ->
      (votes_payload, anonymous_payload, managers_payload))
    (fun (votes_payload, anonymous_payload, managers_payload) ->
      {votes_payload; anonymous_payload; managers_payload})
    (obj3
       (req "votes_payload" (list (dynamic_size Operation.encoding)))
       (req "anonymous_payload" (list (dynamic_size Operation.encoding)))
       (req "managers_payload" (list (dynamic_size Operation.encoding))))

let pp_payload fmt {votes_payload; anonymous_payload; managers_payload} =
  Format.fprintf
    fmt
    "[votes: %d, anonymous: %d, managers: %d]"
    (List.length votes_payload)
    (List.length anonymous_payload)
    (List.length managers_payload)

let empty =
  {
    consensus = Operation_set.empty;
    votes = Operation_set.empty;
    anonymous = Operation_set.empty;
    managers = Operation_set.empty;
  }

let empty_ordered = {consensus = []; votes = []; anonymous = []; managers = []}

let pp_pool fmt {consensus; votes; anonymous; managers} =
  Format.fprintf
    fmt
    "[consensus: %d, votes: %d, anonymous: %d, managers: %d]"
    (Operation_set.cardinal consensus)
    (Operation_set.cardinal votes)
    (Operation_set.cardinal anonymous)
    (Operation_set.cardinal managers)

let pp_ordered_pool fmt {consensus; votes; anonymous; managers} =
  Format.fprintf
    fmt
    "[consensus: %d, votes: %d, anonymous: %d, managers: %d]"
    (List.length consensus)
    (List.length votes)
    (List.length anonymous)
    (List.length managers)

(* Hypothesis : we suppose [List.length Protocol.Main.validation_passes = 4] *)
let consensus_index = 0

let votes_index = 1

let anonymous_index = 2

let managers_index = 3

let classify op =
  (* Hypothesis: acceptable passes returns a size at most 1 list  *)
  match Main.acceptable_passes op with
  | [pass] ->
      if pass = consensus_index then `Consensus
        (* TODO filter outdated consensus ops ? *)
      else if pass = votes_index then `Votes
      else if pass = anonymous_index then `Anonymous
      else if pass = managers_index then `Managers
      else `Bad
  | _ -> `Bad

let add_operation_to_pool add classify pool operation =
  match classify operation with
  | `Consensus ->
      let consensus = add operation pool.consensus in
      {pool with consensus}
  | `Votes ->
      let votes = add operation pool.votes in
      {pool with votes}
  | `Anonymous ->
      let anonymous = add operation pool.anonymous in
      {pool with anonymous}
  | `Managers ->
      let managers = add operation pool.managers in
      {pool with managers}
  | `Bad -> pool

let add_operation = add_operation_to_pool Operation_set.add classify

let add_operations pool ops = List.fold_left add_operation pool ops

type consensus_filter = {
  level : int32;
  round : Round.t;
  payload_hash : Block_payload_hash.t;
}

(** From a pool of operations [operation_pool], the function filters
    out the endorsements that are different from the [current_level],
    the [current_round] or the optional [current_block_payload_hash],
    as well as preendorsements. *)
let filter_with_relevant_consensus_ops ~(endorsement_filter : consensus_filter)
    ~(preendorsement_filter : consensus_filter option) operation_set =
  Operation_set.filter
    (fun {protocol_data; _} ->
      match (protocol_data, preendorsement_filter) with
      (* 1a. Remove preendorsements. *)
      | Operation_data {contents = Single (Preendorsement _); _}, None -> false
      (* 1b. Filter preendorsements. *)
      | ( Operation_data
            {
              contents =
                Single (Preendorsement {level; round; block_payload_hash; _});
              _;
            },
          Some
            {level = level'; round = round'; payload_hash = block_payload_hash'}
        ) ->
          Compare.Int32.(Raw_level.to_int32 level = level')
          && Round.(round = round')
          && Block_payload_hash.(block_payload_hash = block_payload_hash')
      (* 2. Filter endorsements. *)
      | ( Operation_data
            {
              contents =
                Single (Endorsement {level; round; block_payload_hash; _});
              _;
            },
          _ ) ->
          Compare.Int32.(Raw_level.to_int32 level = endorsement_filter.level)
          && Round.(round = endorsement_filter.round)
          && Block_payload_hash.(
               block_payload_hash = endorsement_filter.payload_hash)
      (* 3. Preserve all non-consensus operations. *)
      | _ -> true)
    operation_set

let unpack_preendorsement packed_preendorsement =
  let {shell; protocol_data = Operation_data data} = packed_preendorsement in
  match data with
  | {contents = Single (Preendorsement _); _} ->
      Some ({shell; protocol_data = data} : Kind.preendorsement Operation.t)
  | _ -> None

let unpack_endorsement packed_endorsement =
  let {shell; protocol_data = Operation_data data} = packed_endorsement in
  match data with
  | {contents = Single (Endorsement _); _} ->
      Some ({shell; protocol_data = data} : Kind.endorsement Operation.t)
  | _ -> None

let filter_preendorsements ops =
  List.filter_map
    (function
      | {
          shell = {branch};
          protocol_data =
            Operation_data
              ({contents = Single (Preendorsement _); _} as content);
          _;
        } ->
          Some
            ({shell = {branch}; protocol_data = content}
              : Kind.preendorsement operation)
      | _ -> None)
    ops

let filter_endorsements ops =
  List.filter_map
    (function
      | {
          shell = {branch};
          protocol_data =
            Operation_data ({contents = Single (Endorsement _); _} as content);
          _;
        } ->
          Some
            ({shell = {branch}; protocol_data = content}
              : Kind.endorsement operation)
      | _ -> None)
    ops

let ordered_to_list_list {consensus; votes; anonymous; managers} =
  [consensus; votes; anonymous; managers]

let ordered_of_list_list = function
  | [consensus; votes; anonymous; managers] ->
      Some {consensus; votes; anonymous; managers}
  | _ -> None

let payload_of_ordered_pool {votes; anonymous; managers; _} =
  {
    votes_payload = votes;
    anonymous_payload = anonymous;
    managers_payload = managers;
  }

let ordered_pool_of_payload ~consensus_operations
    {votes_payload; anonymous_payload; managers_payload} =
  {
    consensus = consensus_operations;
    votes = votes_payload;
    anonymous = anonymous_payload;
    managers = managers_payload;
  }

let extract_operations_of_list_list = function
  | [consensus; votes_payload; anonymous_payload; managers_payload] ->
      let preendorsements, endorsements =
        List.fold_left
          (fun ( (preendorsements : Kind.preendorsement Operation.t list),
                 (endorsements : Kind.endorsement Operation.t list) )
               packed_op ->
            let {shell; protocol_data = Operation_data data} = packed_op in
            match data with
            | {contents = Single (Preendorsement _); _} ->
                ({shell; protocol_data = data} :: preendorsements, endorsements)
            | {contents = Single (Endorsement _); _} ->
                (preendorsements, {shell; protocol_data = data} :: endorsements)
            | _ ->
                (* unreachable *)
                (preendorsements, endorsements))
          ([], [])
          consensus
        (* N.b. the order doesn't matter *)
      in
      let preendorsements =
        if preendorsements = [] then None else Some preendorsements
      in
      let payload = {votes_payload; anonymous_payload; managers_payload} in
      Some (preendorsements, endorsements, payload)
  | _ -> None

let filter_pool p {consensus; votes; anonymous; managers} =
  {
    consensus = Operation_set.filter p consensus;
    votes = Operation_set.filter p votes;
    anonymous = Operation_set.filter p anonymous;
    managers = Operation_set.filter p managers;
  }

module Prioritized = struct
  type nonrec t = Prioritized_operation_set.t t

  let of_operation_set (operation_set : Operation_set.t) =
    Operation_set.fold
      (fun elt set ->
        Prioritized_operation_set.add (Prioritized_operation.node elt) set)
      operation_set
      Prioritized_operation_set.empty

  let of_pool (pool : pool) : t =
    {
      consensus = of_operation_set pool.consensus;
      votes = of_operation_set pool.votes;
      anonymous = of_operation_set pool.anonymous;
      managers = of_operation_set pool.managers;
    }

  let add_operation =
    add_operation_to_pool Prioritized_operation_set.add (fun op ->
        classify (Prioritized_operation.packed op))

  let add_external_operation pool priority operation =
    add_operation pool (Prioritized_operation.extern ~priority operation)

  let add_operations prioritized_pool operations =
    List.fold_left add_operation prioritized_pool operations

  (* [merge_external_operations] considers that the list of operation
     represents an ordererd list of operation with the head having the highest
     prioritiy.
  *)
  let merge_external_operations pool
      (external_operations : packed_operation list) =
    List.fold_left_i
      (fun i pool op -> add_external_operation pool (-i) op)
      pool
      external_operations

  let filter p {consensus; votes; anonymous; managers} =
    let filter =
      Prioritized_operation_set.filter (fun pop ->
          p (Prioritized_operation.packed pop))
    in
    {
      consensus = filter consensus;
      votes = filter votes;
      anonymous = filter anonymous;
      managers = filter managers;
    }
end
