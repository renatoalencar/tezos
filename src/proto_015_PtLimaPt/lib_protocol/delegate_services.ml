(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(* Copyright (c) 2020 Metastate AG <hello@metastate.dev>                     *)
(* Copyright (c) 2021 Nomadic Labs, <contact@nomadic-labs.com>               *)
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

open Alpha_context

type error += Balance_rpc_non_delegate of public_key_hash

type error += (* `Temporary *) Not_registered of Signature.Public_key_hash.t

let () =
  register_error_kind
    `Temporary
    ~id:"delegate.not_registered"
    ~title:"Not a registered delegate"
    ~description:
      "The provided public key hash is not the address of a registered \
       delegate."
    ~pp:(fun ppf pkh ->
      Format.fprintf
        ppf
        "The provided public key hash (%a) is not the address of a registered \
         delegate. If you own this account and want to register it as a \
         delegate, use a delegation operation to delegate the account to \
         itself."
        Signature.Public_key_hash.pp
        pkh)
    Data_encoding.(obj1 (req "pkh" Signature.Public_key_hash.encoding))
    (function Not_registered pkh -> Some pkh | _ -> None)
    (fun pkh -> Not_registered pkh)

let () =
  register_error_kind
    `Temporary
    ~id:"delegate_service.balance_rpc_on_non_delegate"
    ~title:"Balance request for an unregistered delegate"
    ~description:"The account whose balance was requested is not a delegate."
    ~pp:(fun ppf pkh ->
      Format.fprintf
        ppf
        "The implicit account (%a) whose balance was requested is not a \
         registered delegate. To get the balance of this account you can use \
         the ../context/contracts/%a/balance RPC."
        Signature.Public_key_hash.pp
        pkh
        Signature.Public_key_hash.pp
        pkh)
    Data_encoding.(obj1 (req "pkh" Signature.Public_key_hash.encoding))
    (function Balance_rpc_non_delegate pkh -> Some pkh | _ -> None)
    (fun pkh -> Balance_rpc_non_delegate pkh)

type info = {
  full_balance : Tez.t;
  current_frozen_deposits : Tez.t;
  frozen_deposits : Tez.t;
  staking_balance : Tez.t;
  frozen_deposits_limit : Tez.t option;
  delegated_contracts : Contract.t list;
  delegated_balance : Tez.t;
  deactivated : bool;
  grace_period : Cycle.t;
  voting_info : Vote.delegate_info;
  active_consensus_key : Signature.Public_key_hash.t;
  pending_consensus_keys : (Cycle.t * Signature.Public_key_hash.t) list;
}

let info_encoding =
  let open Data_encoding in
  conv
    (fun {
           full_balance;
           current_frozen_deposits;
           frozen_deposits;
           staking_balance;
           frozen_deposits_limit;
           delegated_contracts;
           delegated_balance;
           deactivated;
           grace_period;
           voting_info;
           active_consensus_key;
           pending_consensus_keys;
         } ->
      ( ( full_balance,
          current_frozen_deposits,
          frozen_deposits,
          staking_balance,
          frozen_deposits_limit,
          delegated_contracts,
          delegated_balance,
          deactivated,
          grace_period ),
        (voting_info, (active_consensus_key, pending_consensus_keys)) ))
    (fun ( ( full_balance,
             current_frozen_deposits,
             frozen_deposits,
             staking_balance,
             frozen_deposits_limit,
             delegated_contracts,
             delegated_balance,
             deactivated,
             grace_period ),
           (voting_info, (active_consensus_key, pending_consensus_keys)) ) ->
      {
        full_balance;
        current_frozen_deposits;
        frozen_deposits;
        staking_balance;
        frozen_deposits_limit;
        delegated_contracts;
        delegated_balance;
        deactivated;
        grace_period;
        voting_info;
        active_consensus_key;
        pending_consensus_keys;
      })
    (merge_objs
       (obj9
          (req "full_balance" Tez.encoding)
          (req "current_frozen_deposits" Tez.encoding)
          (req "frozen_deposits" Tez.encoding)
          (req "staking_balance" Tez.encoding)
          (opt "frozen_deposits_limit" Tez.encoding)
          (req "delegated_contracts" (list Contract.encoding))
          (req "delegated_balance" Tez.encoding)
          (req "deactivated" bool)
          (req "grace_period" Cycle.encoding))
       (merge_objs
          Vote.delegate_info_encoding
          (obj2
             (req "active_consensus_key" Signature.Public_key_hash.encoding)
             (dft
                "pending_consensus_keys"
                (list
                   (obj2
                      (req "cycle" Cycle.encoding)
                      (req "pkh" Signature.Public_key_hash.encoding)))
                []))))

let participation_info_encoding =
  let open Data_encoding in
  conv
    (fun {
           Delegate.expected_cycle_activity;
           minimal_cycle_activity;
           missed_slots;
           missed_levels;
           remaining_allowed_missed_slots;
           expected_endorsing_rewards;
         } ->
      ( expected_cycle_activity,
        minimal_cycle_activity,
        missed_slots,
        missed_levels,
        remaining_allowed_missed_slots,
        expected_endorsing_rewards ))
    (fun ( expected_cycle_activity,
           minimal_cycle_activity,
           missed_slots,
           missed_levels,
           remaining_allowed_missed_slots,
           expected_endorsing_rewards ) ->
      {
        expected_cycle_activity;
        minimal_cycle_activity;
        missed_slots;
        missed_levels;
        remaining_allowed_missed_slots;
        expected_endorsing_rewards;
      })
    (obj6
       (req "expected_cycle_activity" int31)
       (req "minimal_cycle_activity" int31)
       (req "missed_slots" int31)
       (req "missed_levels" int31)
       (req "remaining_allowed_missed_slots" int31)
       (req "expected_endorsing_rewards" Tez.encoding))

module S = struct
  let raw_path = RPC_path.(open_root / "context" / "delegates")

  open Data_encoding

  type list_query = {
    active : bool;
    inactive : bool;
    with_minimal_stake : bool;
    without_minimal_stake : bool;
  }

  let list_query : list_query RPC_query.t =
    let open RPC_query in
    query (fun active inactive with_minimal_stake without_minimal_stake ->
        {active; inactive; with_minimal_stake; without_minimal_stake})
    |+ flag "active" (fun t -> t.active)
    |+ flag "inactive" (fun t -> t.inactive)
    |+ flag "with_minimal_stake" (fun t -> t.with_minimal_stake)
    |+ flag "without_minimal_stake" (fun t -> t.without_minimal_stake)
    |> seal

  let list_delegate =
    RPC_service.get_service
      ~description:
        "Lists all registered delegates by default. The arguments `active`, \
         `inactive`, `with_minimal_stake`, and `without_minimal_stake` allow \
         to enumerate only the delegates that are active, inactive, have at \
         least a minimal stake to participate in consensus and in governance, \
         or do not have such a minimal stake, respectively. Note, setting \
         these arguments to false has no effect."
      ~query:list_query
      ~output:(list Signature.Public_key_hash.encoding)
      raw_path

  let path = RPC_path.(raw_path /: Signature.Public_key_hash.rpc_arg)

  let info =
    RPC_service.get_service
      ~description:"Everything about a delegate."
      ~query:RPC_query.empty
      ~output:info_encoding
      path

  let full_balance =
    RPC_service.get_service
      ~description:
        "Returns the full balance (in mutez) of a given delegate, including \
         the frozen deposits and the frozen bonds. It does not include its \
         delegated balance."
      ~query:RPC_query.empty
      ~output:Tez.encoding
      RPC_path.(path / "full_balance")

  let current_frozen_deposits =
    RPC_service.get_service
      ~description:
        "Returns the current amount of the frozen deposits (in mutez)."
      ~query:RPC_query.empty
      ~output:Tez.encoding
      RPC_path.(path / "current_frozen_deposits")

  let frozen_deposits =
    RPC_service.get_service
      ~description:
        "Returns the initial amount (that is, at the beginning of a cycle) of \
         the frozen deposits (in mutez). This amount is the same as the \
         current amount of the frozen deposits, unless the delegate has been \
         punished."
      ~query:RPC_query.empty
      ~output:Tez.encoding
      RPC_path.(path / "frozen_deposits")

  let staking_balance =
    RPC_service.get_service
      ~description:
        "Returns the total amount of tokens (in mutez) delegated to a given \
         delegate. This includes the balances of all the contracts that \
         delegate to it, but also the balance of the delegate itself, its \
         frozen deposits, and its frozen bonds."
      ~query:RPC_query.empty
      ~output:Tez.encoding
      RPC_path.(path / "staking_balance")

  let frozen_deposits_limit =
    RPC_service.get_service
      ~description:
        "Returns the frozen deposits limit for the given delegate or none if \
         no limit is set."
      ~query:RPC_query.empty
      ~output:(Data_encoding.option Tez.encoding)
      RPC_path.(path / "frozen_deposits_limit")

  let delegated_contracts =
    RPC_service.get_service
      ~description:
        "Returns the list of contracts that delegate to a given delegate."
      ~query:RPC_query.empty
      ~output:(list Contract.encoding)
      RPC_path.(path / "delegated_contracts")

  let delegated_balance =
    RPC_service.get_service
      ~description:
        "Returns the sum (in mutez) of all balances of all the contracts that \
         delegate to a given delegate. This excludes the delegate's own \
         balance, its frozen deposits and its frozen bonds."
      ~query:RPC_query.empty
      ~output:Tez.encoding
      RPC_path.(path / "delegated_balance")

  let deactivated =
    RPC_service.get_service
      ~description:
        "Tells whether the delegate is currently tagged as deactivated or not."
      ~query:RPC_query.empty
      ~output:bool
      RPC_path.(path / "deactivated")

  let grace_period =
    RPC_service.get_service
      ~description:
        "Returns the cycle by the end of which the delegate might be \
         deactivated if she fails to execute any delegate action. A \
         deactivated delegate might be reactivated (without loosing any stake) \
         by simply re-registering as a delegate. For deactivated delegates, \
         this value contains the cycle at which they were deactivated."
      ~query:RPC_query.empty
      ~output:Cycle.encoding
      RPC_path.(path / "grace_period")

  let voting_power =
    RPC_service.get_service
      ~description:"The voting power in the vote listings for a given delegate."
      ~query:RPC_query.empty
      ~output:Data_encoding.int64
      RPC_path.(path / "voting_power")

  let voting_info =
    RPC_service.get_service
      ~description:
        "Returns the delegate info (e.g. voting power) found in the listings \
         of the current voting period."
      ~query:RPC_query.empty
      ~output:Vote.delegate_info_encoding
      RPC_path.(path / "voting_info")

  let consensus_key =
    RPC_service.get_service
      ~description:
        "The active consensus key for a given delegate and the pending \
         consensus keys."
      ~query:RPC_query.empty
      ~output:
        Data_encoding.(
          obj2
            (req "active" Signature.Public_key_hash.encoding)
            (dft
               "pendings"
               (list
                  (obj2
                     (req "cycle" Cycle.encoding)
                     (req "pkh" Signature.Public_key_hash.encoding)))
               []))
      RPC_path.(path / "consensus_key")

  let participation =
    RPC_service.get_service
      ~description:
        "Returns cycle and level participation information. In particular this \
         indicates, in the field 'expected_cycle_activity', the number of \
         slots the delegate is expected to have in the cycle based on its \
         active stake. The field 'minimal_cycle_activity' indicates the \
         minimal endorsing slots in the cycle required to get endorsing \
         rewards. It is computed based on 'expected_cycle_activity. The fields \
         'missed_slots' and 'missed_levels' indicate the number of missed \
         endorsing slots and missed levels (for endorsing) in the cycle so \
         far. 'missed_slots' indicates the number of missed endorsing slots in \
         the cycle so far. The field 'remaining_allowed_missed_slots' \
         indicates the remaining amount of endorsing slots that can be missed \
         in the cycle before forfeiting the rewards. Finally, \
         'expected_endorsing_rewards' indicates the endorsing rewards that \
         will be distributed at the end of the cycle if activity at that point \
         will be greater than the minimal required; if the activity is already \
         known to be below the required minimum, then the rewards are zero."
      ~query:RPC_query.empty
      ~output:participation_info_encoding
      RPC_path.(path / "participation")
end

let check_delegate_registered ctxt pkh =
  Delegate.registered ctxt pkh >>= function
  | true -> return_unit
  | false -> fail (Not_registered pkh)

let register () =
  let open Services_registration in
  register0 ~chunked:true S.list_delegate (fun ctxt q () ->
      Delegate.list ctxt >>= fun delegates ->
      (match q with
      | {active = true; inactive = false; _} ->
          List.filter_es
            (fun pkh -> Delegate.deactivated ctxt pkh >|=? not)
            delegates
      | {active = false; inactive = true; _} ->
          List.filter_es (fun pkh -> Delegate.deactivated ctxt pkh) delegates
      | {active = false; inactive = false; _}
      (* This case is counter-intuitive, but it represents the default behavior, when no arguments are given *)
      | {active = true; inactive = true; _} ->
          return delegates)
      >>=? fun delegates ->
      let minimal_stake = Constants.minimal_stake ctxt in
      match q with
      | {with_minimal_stake = true; without_minimal_stake = false; _} ->
          List.filter_es
            (fun pkh ->
              Delegate.staking_balance ctxt pkh >|=? fun staking_balance ->
              Tez.(staking_balance >= minimal_stake))
            delegates
      | {with_minimal_stake = false; without_minimal_stake = true; _} ->
          List.filter_es
            (fun pkh ->
              Delegate.staking_balance ctxt pkh >|=? fun staking_balance ->
              Tez.(staking_balance < minimal_stake))
            delegates
      | {with_minimal_stake = true; without_minimal_stake = true; _}
      | {with_minimal_stake = false; without_minimal_stake = false; _} ->
          return delegates) ;
  register1 ~chunked:false S.info (fun ctxt pkh () () ->
      check_delegate_registered ctxt pkh >>=? fun () ->
      Delegate.full_balance ctxt pkh >>=? fun full_balance ->
      Delegate.frozen_deposits ctxt pkh >>=? fun frozen_deposits ->
      Delegate.staking_balance ctxt pkh >>=? fun staking_balance ->
      Delegate.frozen_deposits_limit ctxt pkh >>=? fun frozen_deposits_limit ->
      Delegate.delegated_contracts ctxt pkh >>= fun delegated_contracts ->
      Delegate.delegated_balance ctxt pkh >>=? fun delegated_balance ->
      Delegate.deactivated ctxt pkh >>=? fun deactivated ->
      Delegate.last_cycle_before_deactivation ctxt pkh >>=? fun grace_period ->
      Vote.get_delegate_info ctxt pkh >>=? fun voting_info ->
      Delegate.Consensus_key.active_pubkey ctxt pkh >>=? fun consensus_key ->
      Delegate.Consensus_key.pending_updates ctxt pkh >|=? fun pendings ->
      {
        full_balance;
        current_frozen_deposits = frozen_deposits.current_amount;
        frozen_deposits = frozen_deposits.initial_amount;
        staking_balance;
        frozen_deposits_limit;
        delegated_contracts;
        delegated_balance;
        deactivated;
        grace_period;
        voting_info;
        active_consensus_key = consensus_key.consensus_pkh;
        pending_consensus_keys = pendings;
      }) ;
  register1 ~chunked:false S.full_balance (fun ctxt pkh () () ->
      trace (Balance_rpc_non_delegate pkh) (check_delegate_registered ctxt pkh)
      >>=? fun () -> Delegate.full_balance ctxt pkh) ;
  register1 ~chunked:false S.current_frozen_deposits (fun ctxt pkh () () ->
      check_delegate_registered ctxt pkh >>=? fun () ->
      Delegate.frozen_deposits ctxt pkh >>=? fun deposits ->
      return deposits.current_amount) ;
  register1 ~chunked:false S.frozen_deposits (fun ctxt pkh () () ->
      check_delegate_registered ctxt pkh >>=? fun () ->
      Delegate.frozen_deposits ctxt pkh >>=? fun deposits ->
      return deposits.initial_amount) ;
  register1 ~chunked:false S.staking_balance (fun ctxt pkh () () ->
      check_delegate_registered ctxt pkh >>=? fun () ->
      Delegate.staking_balance ctxt pkh) ;
  register1 ~chunked:false S.frozen_deposits_limit (fun ctxt pkh () () ->
      check_delegate_registered ctxt pkh >>=? fun () ->
      Delegate.frozen_deposits_limit ctxt pkh) ;
  register1 ~chunked:true S.delegated_contracts (fun ctxt pkh () () ->
      check_delegate_registered ctxt pkh >>=? fun () ->
      Delegate.delegated_contracts ctxt pkh >|= ok) ;
  register1 ~chunked:false S.delegated_balance (fun ctxt pkh () () ->
      check_delegate_registered ctxt pkh >>=? fun () ->
      Delegate.delegated_balance ctxt pkh) ;
  register1 ~chunked:false S.deactivated (fun ctxt pkh () () ->
      check_delegate_registered ctxt pkh >>=? fun () ->
      Delegate.deactivated ctxt pkh) ;
  register1 ~chunked:false S.grace_period (fun ctxt pkh () () ->
      check_delegate_registered ctxt pkh >>=? fun () ->
      Delegate.last_cycle_before_deactivation ctxt pkh) ;
  register1 ~chunked:false S.voting_power (fun ctxt pkh () () ->
      check_delegate_registered ctxt pkh >>=? fun () ->
      Vote.get_voting_power_free ctxt pkh) ;
  register1 ~chunked:false S.voting_info (fun ctxt pkh () () ->
      check_delegate_registered ctxt pkh >>=? fun () ->
      Vote.get_delegate_info ctxt pkh) ;
  register1 ~chunked:false S.consensus_key (fun ctxt pkh () () ->
      Delegate.Consensus_key.active_pubkey ctxt pkh >>=? fun pk ->
      Delegate.Consensus_key.pending_updates ctxt pkh >>=? fun pendings ->
      return (pk.consensus_pkh, pendings)) ;
  register1 ~chunked:false S.participation (fun ctxt pkh () () ->
      check_delegate_registered ctxt pkh >>=? fun () ->
      Delegate.participation_info ctxt pkh)

let list ctxt block ?(active = true) ?(inactive = false)
    ?(with_minimal_stake = true) ?(without_minimal_stake = false) () =
  RPC_context.make_call0
    S.list_delegate
    ctxt
    block
    {active; inactive; with_minimal_stake; without_minimal_stake}
    ()

let info ctxt block pkh = RPC_context.make_call1 S.info ctxt block pkh () ()

let full_balance ctxt block pkh =
  RPC_context.make_call1 S.full_balance ctxt block pkh () ()

let current_frozen_deposits ctxt block pkh =
  RPC_context.make_call1 S.current_frozen_deposits ctxt block pkh () ()

let frozen_deposits ctxt block pkh =
  RPC_context.make_call1 S.frozen_deposits ctxt block pkh () ()

let staking_balance ctxt block pkh =
  RPC_context.make_call1 S.staking_balance ctxt block pkh () ()

let frozen_deposits_limit ctxt block pkh =
  RPC_context.make_call1 S.frozen_deposits_limit ctxt block pkh () ()

let delegated_contracts ctxt block pkh =
  RPC_context.make_call1 S.delegated_contracts ctxt block pkh () ()

let delegated_balance ctxt block pkh =
  RPC_context.make_call1 S.delegated_balance ctxt block pkh () ()

let deactivated ctxt block pkh =
  RPC_context.make_call1 S.deactivated ctxt block pkh () ()

let grace_period ctxt block pkh =
  RPC_context.make_call1 S.grace_period ctxt block pkh () ()

let voting_power ctxt block pkh =
  RPC_context.make_call1 S.voting_power ctxt block pkh () ()

let voting_info ctxt block pkh =
  RPC_context.make_call1 S.voting_info ctxt block pkh () ()

let consensus_key ctxt block pkh =
  RPC_context.make_call1 S.consensus_key ctxt block pkh () ()

let participation ctxt block pkh =
  RPC_context.make_call1 S.participation ctxt block pkh () ()
