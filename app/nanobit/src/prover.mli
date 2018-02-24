open Core
open Async
open Nanobit_base

type t

val default_port : int

val create
  : ?debug:unit
  -> port:int
  -> t Deferred.t

val connect : Host_and_port.t -> t Deferred.t

val initialized : t -> unit Deferred.Or_error.t

val extend_blockchain
  : t
  -> Blockchain.t
  -> Block.t
  -> Blockchain.t Deferred.Or_error.t

val genesis_proof
  : t -> Proof.t Deferred.Or_error.t

val verify
  : t -> Blockchain.t -> bool Deferred.Or_error.t

val command : Command.t