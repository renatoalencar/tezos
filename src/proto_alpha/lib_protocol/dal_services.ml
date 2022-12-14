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

open Alpha_context

let assert_dal_feature_enabled ctxt =
  let open Constants in
  let Parametric.{dal = {feature_enable; _}; _} = parametric ctxt in
  error_unless
    Compare.Bool.(feature_enable = true)
    Dal_errors.Dal_feature_disabled

let shards ctxt ~level =
  let open Lwt_tzresult_syntax in
  let open Dal.Endorsement in
  assert_dal_feature_enabled ctxt >>?= fun () ->
  let level = Level.from_raw ctxt level in
  let pkh_from_tenderbake_slot slot =
    Stake_distribution.slot_owner ctxt level slot
    >|=? fun (ctxt, consensus_key) -> (ctxt, consensus_key.delegate)
  in
  (* We do not cache this committee. This function being used by RPCs
     to know the DAL committee at some particular level. *)
  let* committee =
    Dal.Endorsement.compute_committee ctxt pkh_from_tenderbake_slot
  in
  Signature.Public_key_hash.Map.bindings committee.pkh_to_shards |> return
