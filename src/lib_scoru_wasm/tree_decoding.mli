(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
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

type key = string list

(** Raised when a requested key is not present. *)
exception Key_not_found of key

(** Raised when data-encoding fails to decode a certain value. *)
exception Decode_error of {key : key; error : Data_encoding.Binary.read_error}

module type S = sig
  type tree

  (** Tree decoder type *)
  type 'a t

  (** [run decoder tree] runs the tree decoder against the tree. *)
  val run : 'a t -> tree -> 'a Lwt.t

  (** [raw key] retrieves the raw value at the given [key].

      @raises Key_not_found when the requested key is not presented
  *)
  val raw : key -> bytes t

  (** [value key data_encoding] retrieves the value at a given [key] by decoding
      its raw value using the provided [data_encoding].

      @raises Key_not_found when the requested key is not presented
      @raises Decode_error when decoding of the value fails
  *)
  val value : key -> 'a Data_encoding.t -> 'a t

  (** [tree key decoder] apply a tree decoder for a provided [key].

      @raises Key_not_found when the requested key is not presented
  *)
  val tree : key -> 'a t -> 'a t

  (** [lazy_mapping to_key decoder] decodes to a function [f] that can be called
      to look up keyed values in the current tree.

      For example, the expression [f k] is virtually equivalent to
      running a decoder like [value (to_key k) decoder] against the tree.

      This function is primarily useful when providing a [~produce_value]
      function to [Lazy_map.create]. *)
  val lazy_mapping : ('i -> key) -> 'a t -> ('i -> 'a Lwt.t) t

  (* Combinators below *)

  val return : 'a -> 'a t

  val of_lwt : 'a Lwt.t -> 'a t

  val ( let+ ) : 'a t -> ('a -> 'b) -> 'b t

  val ( and+ ) : 'a t -> 'b t -> ('a * 'b) t

  val ( let* ) : 'a t -> ('a -> 'b t) -> 'b t

  val ( and* ) : 'a t -> 'b t -> ('a * 'b) t
end

module Make (T : Tree.S) : S with type tree = T.tree