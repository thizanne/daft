(* a CLI only talks to the MDS and to the local DS on the same node
   - all complex things should be handled by them and the CLI remain simple *)

open Batteries
open Printf
open Types.Protocol

module Fn = Filename
module FU = FileUtil
module Logger = Log
module Log = Log.Make (struct let section = "CLI" end) (* prefix all logs *)
module S = String
module Node = Types.Node
module File = Types.File
module FileSet = Types.FileSet
module Sock = ZMQ.Socket

let uninitialized = -1

let ds_host = ref (Utils.hostname ())
let ds_port_in = ref Utils.default_ds_port_in
let mds_host = ref "localhost"
let mds_port_in = ref Utils.default_mds_port_in
let cli_port_in = ref Utils.default_cli_port_in
let do_compress = ref false

let abort msg =
  Log.fatal "%s" msg;
  exit 1

let do_nothing () =
  ()

let process_answer incoming continuation =
  Log.debug "waiting msg";
  let encoded = Sock.recv incoming in
  let message = decode !do_compress encoded in
  Log.debug "got msg";
  match message with
  | MDS_to_CLI (Ls_cmd_ack f) ->
    Log.debug "got Ls_cmd_ack";
    let listing = FileSet.to_string f in
    Log.info "\n%s" listing
  | MDS_to_CLI (Fetch_cmd_nack fn) ->
    Log.debug "got Fetch_cmd_nack";
    Log.error "no such file: %s" fn
  | DS_to_CLI (Fetch_file_cmd_ack fn) ->
    begin
      Log.debug "got Fetch_file_cmd_ack";
      Log.info "%s: OK" fn;
      continuation ()
    end
  | DS_to_CLI (Fetch_file_cmd_nack (fn, err)) ->
    Log.debug "got Fetch_file_cmd_nack";
    Log.error "%s: %s" fn (string_of_error err)
  | DS_to_MDS _ -> Log.warn "DS_to_MDS"
  | MDS_to_DS _ -> Log.warn "MDS_to_DS"
  | DS_to_DS _ -> Log.warn "DS_to_DS"
  | CLI_to_MDS _ -> Log.warn "CLI_to_MDS"
  | CLI_to_DS _ -> Log.warn "CLI_to_DS"

module Command = struct
  type t = Put
         | Get
         | Fetch
         | Rfetch
         | Extract
         | Quit
         | Ls
  (* understand a command as soon as it is unambiguous; quick and dirty *)
  let of_string: string -> t = function
    | "p" | "pu" | "put" -> Put
    | "g" | "ge" | "get" -> Get
    | "f" | "fe" | "fet" | "fetc" | "fetch" -> Fetch
    | "r" | "rf" | "rfe" | "rfet" | "rfetc" | "rfetch" -> Rfetch
    | "e" | "ex" | "ext" | "extr" | "extra" | "extrac" | "extract" -> Extract
    | "q" | "qu" | "qui" | "quit" -> Quit
    | "l" | "ls" -> Ls
    | "" -> abort "empty command"
    | cmd -> abort ("unknown command: " ^ cmd)
end

let extract_cmd src_fn dst_fn for_DS incoming =
  let extract = encode !do_compress (CLI_to_DS (Extract_file_cmd_req (src_fn, dst_fn))) in
  Sock.send for_DS extract;
  process_answer incoming do_nothing

(* FBR: processing commands is a recursive function; just use one *)

let main () =
  (* setup logger *)
  Logger.set_log_level Logger.DEBUG;
  Logger.set_output Legacy.stdout;
  Logger.color_on ();
  (* options parsing *)
  Arg.parse
    [ "-cli", Arg.Set_int cli_port_in, "<port> where the CLI is listening";
      "-mds", Arg.String (Utils.set_host_port mds_host mds_port_in),
      "<host:port> MDS";
      "-ds", Arg.String (Utils.set_host_port ds_host ds_port_in),
      "<host:port> local DS";
      "-z", Arg.Set do_compress, " enable on the fly compression" ]
    (fun arg -> raise (Arg.Bad ("Bad argument: " ^ arg)))
    (sprintf "usage: %s <options>" Sys.argv.(0));
  (* check options *)
  if !mds_host = "" || !mds_port_in = uninitialized then abort "-mds is mandatory";
  if !ds_host  = "" || !ds_port_in  = uninitialized then abort "-ds is mandatory";
  let ctx = ZMQ.Context.create () in
  let for_MDS = Utils.(zmq_socket Push ctx !mds_host !mds_port_in) in
  Log.info "Client of MDS %s:%d" !mds_host !mds_port_in;
  let for_DS = Utils.(zmq_socket Push ctx !ds_host !ds_port_in) in
  let incoming = Utils.(zmq_socket Pull ctx "*" !cli_port_in) in
  Log.info "Client of DS %s:%d" !ds_host !ds_port_in;
  (* the CLI execute just one command then exit *)
  (* we could have a batch mode, executing several commands from a file *)
  let not_finished = ref true in
  try
    while !not_finished do
      let command_str = read_line () in
      Log.info "command: %s" command_str;
      let parsed_command = BatString.nsplit ~by:" " command_str in
      begin match parsed_command with
        | [] -> Log.error "empty command"
        | cmd :: args ->
          begin match cmd with
            | "" -> Log.error "cmd = \"\""
            | "put"
            | "get"
            | "fetch" ->
              begin match args with
                | [] -> Log.error "no filename"
                | src_fn :: other_args ->
                  if cmd <> "get" && other_args <> []
                  then Log.warn "more than one filename";
                  let f_loc = match cmd with
                    | "put" -> Local
                    | "get" | "fetch" -> Remote
                    | _ -> assert(false)
                  in
                  let put = encode !do_compress (CLI_to_DS (Fetch_file_cmd_req (src_fn, f_loc))) in
                  Sock.send for_DS put;
                  (* get = extract . fetch *)
                  let continuation =
                    if cmd <> "get" then do_nothing
                    else
                      (fun () -> match other_args with
                         | [dst_fn] -> extract_cmd src_fn dst_fn for_DS incoming
                         | _ -> Log.error "no dst_fn"
                      )
                  in
                  process_answer incoming continuation
              end
            | "rfetch" ->
              begin match args with
                | [] -> Log.error "no filename"
                | [src_fn; host_port] ->
                  let put = encode !do_compress (CLI_to_DS (Fetch_file_cmd_req (src_fn, Remote))) in
                  let host, port = ref "", ref 0 in
                  Utils.set_host_port host port host_port;
                  (* temp socket to remote DS *)
                  let for_ds_i = Utils.(zmq_socket Push ctx !host !port) in
                  Sock.send for_ds_i put;
                  process_answer incoming do_nothing;
                  ZMQ.Socket.close for_ds_i
                | _ -> Log.error "rfetch: usage: rfetch fn host:port"
              end
            | "extract" ->
              begin match args with
                | [] -> Log.error "no filename"
                | [src_fn; dst_fn] -> extract_cmd src_fn dst_fn for_DS incoming
                | _ -> Log.error "too many filenames"
              end
            | "q" | "quit" | "exit" ->
              let quit_cmd = encode !do_compress (CLI_to_MDS Quit_cmd) in
              Sock.send for_MDS quit_cmd;
              not_finished := false;
            | "l" | "ls" ->
              let ls_cmd = encode !do_compress (CLI_to_MDS Ls_cmd_req) in
              Sock.send for_MDS ls_cmd;
              process_answer incoming do_nothing
            | _ -> Log.error "unknown command: %s" cmd
          end
      end
    done;
    raise Types.Loop_end;
  with exn -> begin
      ZMQ.Socket.close for_MDS;
      ZMQ.Socket.close for_DS;
      ZMQ.Socket.close incoming;
      ZMQ.Context.terminate ctx;
      begin match exn with
        | Types.Loop_end -> ()
        | _ -> raise exn
      end
    end
;;

main ()
