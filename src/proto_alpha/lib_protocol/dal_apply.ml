(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Nomadic Labs <contact@nomadic-labs.com>                *)
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

(* Every function of this file should check the feature flag. *)

open Alpha_context
open Dal_errors

let assert_dal_feature_enabled ctxt =
  let open Constants in
  let Parametric.{dal = {feature_enable; _}; _} = parametric ctxt in
  error_unless Compare.Bool.(feature_enable = true) Dal_feature_disabled

let only_if_dal_feature_enabled ctxt ~default f =
  let open Constants in
  let Parametric.{dal = {feature_enable; _}; _} = parametric ctxt in
  if feature_enable then f ctxt else default ctxt

let slot_of_int_e n =
  let open Tzresult_syntax in
  match Dal.Slot_index.of_int n with
  | None -> fail Dal_errors.Dal_slot_index_above_hard_limit
  | Some slot_index -> return slot_index

let validate_data_availability ctxt op =
  assert_dal_feature_enabled ctxt >>? fun () ->
  let open Tzresult_syntax in
  (* FIXME/DAL: https://gitlab.com/tezos/tezos/-/issues/4163
     check the signature of the endorser as well *)
  let Dal.Endorsement.{endorser = _; slot_availability; level = given} = op in
  let* max_index =
    slot_of_int_e @@ ((Constants.parametric ctxt).dal.number_of_slots - 1)
  in
  let maximum_size = Dal.Endorsement.expected_size_in_bits ~max_index in
  let size = Dal.Endorsement.occupied_size_in_bits slot_availability in
  let* () =
    error_unless
      Compare.Int.(size <= maximum_size)
      (Dal_endorsement_size_limit_exceeded {maximum_size; got = size})
  in
  let current = Level.(current ctxt).level in
  let delta_levels = Raw_level.diff current given in
  let* () =
    error_when
      Compare.Int32.(delta_levels > 0l)
      (Dal_operation_for_old_level {current; given})
  in
  error_when
    Compare.Int32.(delta_levels < 0l)
    (Dal_operation_for_future_level {current; given})

let apply_data_availability ctxt op =
  assert_dal_feature_enabled ctxt >>? fun () ->
  let Dal.Endorsement.{endorser; slot_availability; level = _} = op in
  match Dal.Endorsement.shards_of_endorser ctxt ~endorser with
  | None ->
      let level = Level.current ctxt in
      error (Dal_data_availibility_endorser_not_in_committee {endorser; level})
  | Some shards ->
      Ok (Dal.Endorsement.record_available_shards ctxt slot_availability shards)

let validate_publish_slot_header ctxt
    Dal.Slot.Header.{id = {index; published_level}; _} =
  assert_dal_feature_enabled ctxt >>? fun () ->
  let open Tzresult_syntax in
  let open Constants in
  let Parametric.{dal = {number_of_slots; _}; _} = parametric ctxt in
  let* number_of_slots = slot_of_int_e (number_of_slots - 1) in
  let* () =
    error_unless
      Compare.Int.(
        Dal.Slot_index.compare index number_of_slots <= 0
        && Dal.Slot_index.compare index Dal.Slot_index.zero >= 0)
      (Dal_publish_slot_header_invalid_index
         {given = index; maximum = number_of_slots})
  in
  let current_level = (Level.current ctxt).level in
  let* () =
    error_when
      Raw_level.(current_level < published_level)
      (Dal_publish_slot_header_future_level
         {provided = published_level; expected = current_level})
  in
  error_when
    Raw_level.(current_level > published_level)
    (Dal_publish_slot_header_past_level
       {provided = published_level; expected = current_level})

let apply_publish_slot_header ctxt slot_header =
  assert_dal_feature_enabled ctxt >>? fun () ->
  Dal.Slot.register_slot_header ctxt slot_header >>? fun (ctxt, updated) ->
  if updated then ok ctxt
  else error (Dal_publish_slot_header_duplicate {slot_header})

let finalisation ctxt =
  only_if_dal_feature_enabled
    ctxt
    ~default:(fun ctxt -> return (ctxt, None))
    (fun ctxt ->
      Dal.Slot.finalize_current_slot_headers ctxt >>= fun ctxt ->
      (* The fact that slots confirmation is done at finalization is very
         important for the assumptions made by the Dal refutation game. In fact:
         - {!Dal.Slot.finalize_current_slot_headers} updates the Dal skip list
         at block finalization, by inserting newly confirmed slots;
         - {!Sc_rollup.Game.initial}, called when applying a manager operation
         that starts a refutation game, makes a snapshot of the Dal skip list
         to use it as a reference if the refutation proof involves a Dal input.

         If confirmed Dal slots are inserted into the skip list during operations
         application, adapting how refutation games are made might be needed
         to e.g.,
         - use the same snapshotted skip list as a reference by L1 and rollup-node;
         - disallow proofs involving pages of slots that have been confirmed at the
           level where the game started.
      *)
      Dal.Slot.finalize_pending_slot_headers ctxt
      >|=? fun (ctxt, slot_availability) -> (ctxt, Some slot_availability))

let initialisation ctxt ~level =
  let open Lwt_tzresult_syntax in
  only_if_dal_feature_enabled
    ctxt
    ~default:(fun ctxt -> return ctxt)
    (fun ctxt ->
      let pkh_from_tenderbake_slot slot =
        Stake_distribution.slot_owner ctxt level slot
        >|=? fun (ctxt, consensus_pk1) -> (ctxt, consensus_pk1.delegate)
      in
      (* This committee is cached because it is the one we will use
         for the validation of the DAL endorsements. *)
      let* committee =
        Alpha_context.Dal.Endorsement.compute_committee
          ctxt
          pkh_from_tenderbake_slot
      in
      return (Alpha_context.Dal.Endorsement.init_committee ctxt committee))
