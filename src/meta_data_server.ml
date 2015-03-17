open Batteries
open Printf

let mds_in_blue = Utils.fg_blue ^ "MDS" ^ Utils.fg_reset

module A = Array
module From_MDS = Types.Protocol.From_MDS
module From_DS = Types.Protocol.From_DS
module Ht = Hashtbl
module L = List
module Logger = Log (* !!! keep this one before Log alias !!! *)
(* prefix all logs *)
module Log = Log.Make (struct let section = mds_in_blue end)
module Node = Types.Node
module Proto = Types.Protocol
module Sock = ZMQ.Socket

let parse_machine_line (rank: int) (l: string): Node.t =
  let hostname, port = String.split l ":" in
  Node.create rank hostname (int_of_string port)

let parse_machine_file (fn: string): Node.t list =
  let res = ref [] in
  Utils.with_in_file fn
    (fun input ->
       try
         let i = ref 0 in
         while true do
           res := (parse_machine_line !i (Legacy.input_line input)) :: !res;
           incr i;
         done
       with End_of_file -> ()
    );
  L.rev !res

let data_nodes_array (fn: string) =
  let machines = parse_machine_file fn in
  let len = L.length machines in
  let dummy_ctx, dummy_sock = Utils.zmq_dummy_client_setup () in
  let res = A.create len (Node.dummy (), dummy_ctx, dummy_sock) in
  L.iter (fun node -> A.set res Node.(node.rank) (node, dummy_ctx, dummy_sock)
         ) machines;
  res

let start_data_nodes () =
  (* FBR: scp exe to each node *)
  (* FBR: ssh node to start it *)
  failwith "not implemented yet"

let main () =
  (* setup logger *)
  Logger.set_log_level Logger.DEBUG;
  Logger.set_output Legacy.stdout;
  Logger.color_on ();
  (* setup MDS *)
  let port = ref Utils.default_mds_port in
  let host = Utils.hostname () in
  let machine_file = ref "" in
  Arg.parse
    [ "-p", Arg.Set_int port, "port where to listen";
      "-m", Arg.Set_string machine_file,
      "machine_file list of [user@]host:port (one per line)" ]
    (fun arg -> raise (Arg.Bad ("Bad argument: " ^ arg)))
    (sprintf "usage: %s <options>" Sys.argv.(0));
  (* check options *)
  if !machine_file = "" then (
    Log.fatal "-m is mandatory";
    exit 1
  );
  Log.info "MDS: %s:%d" host !port;
  let int2node = data_nodes_array !machine_file in
  Log.info "MDS: read %d host(s)" (A.length int2node);
  (* start all DSs *) (* FBR: later maybe, we can do this by hand for the moment *)
  (* start server *)
  Log.info "binding server to %s:%d" "*" !port;
  let server_context, server_socket = Utils.zmq_server_setup "*" !port in
  try (* loop on messages until quit command *)
    let not_finished = ref true in
    while !not_finished do
      let encoded_request = Sock.recv server_socket in
      let request = From_DS.decode encoded_request in
      Log.info "got message";
      let open Proto in
      (match request with
       | From_DS.To_MDS (Join ds) ->
         (Log.info "DS %s joined" (Node.to_string ds);
          (* check it is the one we expect at that rank *)
          let expected_ds, _, _ = int2node.(Node.(ds.rank)) in
          assert(ds = expected_ds); (* FBR: should just log error then ignore it *)
          let ctx, sock = Utils.zmq_client_setup Node.(ds.host) Node.(ds.port) in
          A.set int2node Node.(ds.rank) (ds, ctx, sock);
          let join_answer = From_MDS.(encode (To_DS Proto.Join_Ack)) in
          Sock.send server_socket join_answer)
       | _ -> (* FBR: match all possible messages explicitely *)
         Log.warn "unmanaged"
      );
    done;
  with exn ->
    (Log.error "exception";
     Utils.zmq_cleanup server_socket server_context;
     raise exn)
;;

main ()
