(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Nomadic Labs <contact@nomadic-labs.com>                *)
(* Copyright (c) 2022 TriliTech <contact@trili.tech>                         *)
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

open Sc_rollup_errors
module Store = Storage.Sc_rollup

let update_num_and_size_of_messages ~num_messages ~total_messages_size message =
  ( num_messages + 1,
    total_messages_size
    + String.length
        (message : Sc_rollup_inbox_message_repr.serialized :> string) )

let inbox ctxt rollup =
  let open Lwt_tzresult_syntax in
  let* ctxt, res = Store.Inbox.find ctxt rollup in
  match res with
  | None -> fail (Sc_rollup_does_not_exist rollup)
  | Some inbox -> return (inbox, ctxt)

let assert_inbox_nb_messages_in_commitment_period ctxt inbox extra_messages =
  let nb_messages_in_commitment_period =
    Int64.add
      (Sc_rollup_inbox_repr.number_of_messages_during_commitment_period inbox)
      (Int64.of_int extra_messages)
  in
  let limit =
    Constants_storage.sc_rollup_max_number_of_messages_per_commitment_period
      ctxt
    |> Int64.of_int
  in
  fail_when
    Compare.Int64.(nb_messages_in_commitment_period > limit)
    Sc_rollup_max_number_of_messages_reached_for_commitment_period

let add_messages ctxt rollup messages =
  let {Level_repr.level; _} = Raw_context.current_level ctxt in
  let open Lwt_tzresult_syntax in
  let open Raw_context in
  let commitment_period =
    Constants_storage.sc_rollup_commitment_period_in_blocks ctxt |> Int32.of_int
  in
  let* inbox, ctxt = inbox ctxt rollup in
  let* num_messages, total_messages_size, ctxt =
    List.fold_left_es
      (fun (num_messages, total_messages_size, ctxt) message ->
        let*? ctxt =
          Raw_context.consume_gas
            ctxt
            Sc_rollup_costs.Constants.cost_update_num_and_size_of_messages
        in
        let num_messages, total_messages_size =
          update_num_and_size_of_messages
            ~num_messages
            ~total_messages_size
            message
        in
        return (num_messages, total_messages_size, ctxt))
      (0, 0, ctxt)
      messages
  in
  let inbox =
    Sc_rollup_inbox_repr.refresh_commitment_period
      ~commitment_period
      ~level
      inbox
  in
  let* () =
    assert_inbox_nb_messages_in_commitment_period ctxt inbox num_messages
  in
  let inbox_level = Sc_rollup_inbox_repr.inbox_level inbox in
  let* ctxt, genesis_info = Storage.Sc_rollup.Genesis_info.get ctxt rollup in
  let origination_level = genesis_info.level in
  let levels =
    Int32.sub
      (Raw_level_repr.to_int32 inbox_level)
      (Raw_level_repr.to_int32 origination_level)
  in
  let*? current_messages, ctxt =
    Sc_rollup_in_memory_inbox.current_messages ctxt rollup
  in
  let cost_add_serialized_messages =
    Sc_rollup_costs.cost_add_serialized_messages
      ~num_messages
      ~total_messages_size
      levels
  in
  let*? ctxt = Raw_context.consume_gas ctxt cost_add_serialized_messages in
  (*
      Notice that the protocol is forgetful: it throws away the inbox
      history. On the contrary, the history is stored by the rollup
      node to produce inclusion proofs when needed.
  *)
  let* current_messages, inbox =
    Sc_rollup_inbox_repr.add_messages_no_history
      (Raw_context.recover ctxt)
      inbox
      level
      messages
      current_messages
  in
  let*? ctxt =
    Sc_rollup_in_memory_inbox.set_current_messages ctxt rollup current_messages
  in
  let* ctxt, size = Store.Inbox.update ctxt rollup inbox in
  return (inbox, Z.of_int size, ctxt)

let serialize_external_messages ctxt external_messages =
  let open Sc_rollup_inbox_message_repr in
  List.fold_left_map_e
    (fun ctxt message ->
      let open Tzresult_syntax in
      (* Pay gas for serializing an external message. *)
      let* ctxt =
        let bytes_len = String.length message in
        Raw_context.consume_gas
          ctxt
          (Sc_rollup_costs.cost_serialize_external_inbox_message ~bytes_len)
      in
      let* serialized_message = serialize @@ External message in
      return (ctxt, serialized_message))
    ctxt
    external_messages

let serialize_internal_message ctxt ~payload ~sender ~source =
  let open Result_syntax in
  let internal_message =
    {Sc_rollup_inbox_message_repr.payload; sender; source}
  in
  (* Pay gas for serializing an internal message. *)
  let* ctxt =
    Raw_context.consume_gas
      ctxt
      (Sc_rollup_costs.cost_serialize_internal_inbox_message internal_message)
  in
  let* message =
    Sc_rollup_inbox_message_repr.(serialize @@ Internal internal_message)
  in
  return (message, ctxt)

let add_external_messages ctxt rollup external_messages =
  let open Lwt_result_syntax in
  let*? ctxt, messages = serialize_external_messages ctxt external_messages in
  add_messages ctxt rollup messages

let add_internal_message ctxt rollup ~payload ~sender ~source =
  let open Lwt_result_syntax in
  let*? message, ctxt =
    serialize_internal_message ctxt ~payload ~sender ~source
  in
  add_messages ctxt rollup [message]

module Internal_for_tests = struct
  let update_num_and_size_of_messages = update_num_and_size_of_messages
end
