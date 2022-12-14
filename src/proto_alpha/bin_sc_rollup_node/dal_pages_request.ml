(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Nomadic Labs, <contact@nomadic-labs.com>               *)
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

(** If a slot, published at some level L, is expected to be confirmed at level
    L+D then, once the confirmation level is over, the rollup node is supposed to:
    - Download and save the content of the slot's pages in the store, if the slot
      is confirmed;
    - Add entries [None] for the slot's pages in the store, if the slot
      is not confirmed. *)

type error +=
  | Dal_slot_not_found_in_store of Dal.Slot.Header.id
  | Dal_invalid_page_for_slot of Dal.Page.t

let () =
  register_error_kind
    `Permanent
    ~id:"dal_pages_request.dal_slot_not_found_in_store"
    ~title:"Dal slot not found in store"
    ~description:"The Dal slot whose ID is given is not found in the store"
    ~pp:(fun ppf ->
      Format.fprintf ppf "Dal slot not found in store %a" Dal.Slot.Header.pp_id)
    Data_encoding.(obj1 (req "slot_id" Dal.Slot.Header.id_encoding))
    (function Dal_slot_not_found_in_store slot_id -> Some slot_id | _ -> None)
    (fun slot_id -> Dal_slot_not_found_in_store slot_id) ;
  register_error_kind
    `Permanent
    ~id:"dal_pages_request.dal_invalid_page_for_slot"
    ~title:"Invalid Dal page requested for slot"
    ~description:"The requested Dal page for a given slot is invalid"
    ~pp:(fun ppf ->
      Format.fprintf ppf "Invalid Dal page requested %a" Dal.Page.pp)
    Data_encoding.(obj1 (req "page_id" Dal.Page.encoding))
    (function Dal_invalid_page_for_slot page_id -> Some page_id | _ -> None)
    (fun page_id -> Dal_invalid_page_for_slot page_id)

let store_entry_from_published_level ~dal_endorsement_lag ~published_level store
    =
  State.hash_of_level store
  @@ Int32.(
       add (of_int dal_endorsement_lag) (Raw_level.to_int32 published_level))

let check_confirmation_status_and_download
    ({Node_context.store; dal_cctxt; _} as node_ctxt) ~confirmed_in_block_hash
    ~published_in_block_hash index =
  let open Lwt_result_syntax in
  let* confirmed_in_block_level =
    State.level_of_hash node_ctxt.store confirmed_in_block_hash
  in
  let confirmed_in_head =
    Layer1.{hash = confirmed_in_block_hash; level = confirmed_in_block_level}
  in
  let* is_confirmed =
    Dal_slots_tracker.is_slot_confirmed node_ctxt confirmed_in_head index
  in
  if is_confirmed then
    let*! {commitment; _} =
      Store.Dal_slots_headers.get
        store
        ~primary_key:published_in_block_hash
        ~secondary_key:index
    in
    let* pages = Dal_node_client.get_slot_pages dal_cctxt commitment in
    let*! () =
      Dal_slots_tracker.save_confirmed_slot
        node_ctxt
        confirmed_in_block_hash
        index
        pages
    in
    return_some pages
  else
    let*! () =
      Dal_slots_tracker.save_unconfirmed_slot
        node_ctxt
        confirmed_in_block_hash
        index
    in
    return_none

let slot_pages ~dal_endorsement_lag ({Node_context.store; _} as node_ctxt)
    Dal.Slot.Header.{published_level; index} =
  let open Lwt_result_syntax in
  let*! confirmed_in_block_hash =
    store_entry_from_published_level ~dal_endorsement_lag ~published_level store
  in
  let*! processed =
    Store.Dal_processed_slots.find
      store
      ~primary_key:confirmed_in_block_hash
      ~secondary_key:index
  in
  match processed with
  | None ->
      let*! published_in_block_hash =
        State.hash_of_level store (Raw_level.to_int32 published_level)
      in
      check_confirmation_status_and_download
        node_ctxt
        ~published_in_block_hash
        ~confirmed_in_block_hash
        index
  | Some `Unconfirmed -> return None
  | Some `Confirmed ->
      let*! pages =
        Store.Dal_slot_pages.list_secondary_keys_with_values
          store
          ~primary_key:confirmed_in_block_hash
      in
      List.filter
        (fun ((slot_idx, _page_idx), _v) -> Dal.Slot_index.equal index slot_idx)
        pages
      |> List.map snd |> Option.some |> return

let page_content ~dal_endorsement_lag ({Node_context.store; _} as node_ctxt)
    page_id =
  let open Lwt_result_syntax in
  let Dal.Page.{slot_id; page_index} = page_id in
  let Dal.Slot.Header.{published_level; index} = slot_id in
  let*! confirmed_in_block_hash =
    store_entry_from_published_level ~dal_endorsement_lag ~published_level store
  in
  let*! processed =
    Store.Dal_processed_slots.find
      store
      ~primary_key:confirmed_in_block_hash
      ~secondary_key:index
  in
  match processed with
  | None -> (
      (* In this case we know that the slot header has not been prefetched
         by the rollup node. We check whether it was confirmed by looking at the
         block receipt metadata, before requesting the data to the dal node.
         While the current logic in `Dal_slots_tracker.donwload_and_save_slots`
         guarantees that if `processed = None`, then the slot has been confirmed,
         having this additional check in place ensures that we do not rely on
         the logic of that function when determining the confirmation status of
         a slot. *)
      let*! published_in_block_hash =
        State.hash_of_level store (Raw_level.to_int32 published_level)
      in
      let* pages =
        check_confirmation_status_and_download
          node_ctxt
          ~published_in_block_hash
          ~confirmed_in_block_hash
          index
      in
      match pages with
      | None -> (* Slot is not confirmed *) return_none
      | Some (* Slot is confirmed *) pages -> (
          match List.nth_opt pages page_index with
          | Some page -> return @@ Some page
          | None -> tzfail @@ Dal_invalid_page_for_slot page_id))
  | Some `Unconfirmed -> return None
  | Some `Confirmed -> (
      let*! page_opt =
        Store.Dal_slot_pages.find
          store
          ~primary_key:confirmed_in_block_hash
          ~secondary_key:(index, page_index)
      in
      match page_opt with
      | Some v -> return @@ Some v
      | None ->
          let*! pages =
            Store.Dal_slot_pages.list_secondary_keys_with_values
              store
              ~primary_key:confirmed_in_block_hash
          in
          if page_index < 0 || List.compare_length_with pages page_index <= 0
          then tzfail @@ Dal_invalid_page_for_slot page_id
          else tzfail @@ Dal_slot_not_found_in_store slot_id)
