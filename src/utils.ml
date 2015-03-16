
open Printf

let default_mds_host = "*" (* all interfaces (I guess) on the host where the MDS is launched *)
let default_ds_port = 8081
let default_mds_port = 8082
let default_chunk_size = 1_000_000 (* bytes *)

(* ANSI terminal colors for UNIX: *)
let fg_black = "\027[30m"
let fg_red = "\027[31m"
let fg_green = "\027[32m"
let fg_yellow = "\027[33m"
let fg_blue = "\027[34m"
let fg_magenta = "\027[35m"
let fg_cyan = "\027[36m"
let fg_white = "\027[37m"
let fg_default = "\027[39m"
let fg_reset = "\027[0m"

let sleep_ms ms =
  let (_, _, _) = Unix.select [] [] [] (float_of_int ms /. 1000.) in
  ()

(* like `cmd` in shell
   FBR: use the one in batteries upon next release *)
let run_and_read cmd =
  let string_of_file fn =
    let buff_size = 1024 in
    let buff = Buffer.create buff_size in
    let ic = open_in fn in
    let line_buff = String.create buff_size in
    begin
      let was_read = ref (input ic line_buff 0 buff_size) in
      while !was_read <> 0 do
        Buffer.add_substring buff line_buff 0 !was_read;
        was_read := input ic line_buff 0 buff_size;
      done;
      close_in ic;
    end;
    Buffer.contents buff
  in
  let tmp_fn = Filename.temp_file "" "" in
  let cmd_to_run = cmd ^ " > " ^ tmp_fn in
  let status = Unix.system cmd_to_run in
  let output = string_of_file tmp_fn in
  Unix.unlink tmp_fn;
  (status, output)

let with_in_file fn f =
  let input = open_in fn in
  let res = f input in
  close_in input;
  res

let with_out_file fn f =
  let output = open_out fn in
  let res = f output in
  close_out output;
  res

(* ZMQ.Socket.rep server setup *)
let zmq_server_setup (host: string) (port: int) =
  try
    let context = ZMQ.Context.create () in
    let socket = ZMQ.Socket.create context ZMQ.Socket.rep in
    let host_and_port = sprintf "tcp://%s:%d" host port in
    let () = ZMQ.Socket.bind socket host_and_port in
    (context, socket)
  with Unix.Unix_error(err, fun_name, fun_param) ->
    (Log.fatal "(%s, %s, %s)" (Unix.error_message err) fun_name fun_param;
     exit 1)

(* ZMQ.Socket.req socket setup; for any client of a rep server *)
let zmq_client_setup (host: string) (port: int) =
  let context = ZMQ.Context.create () in
  let socket = ZMQ.Socket.create context ZMQ.Socket.req in
  let host_and_port = sprintf "tcp://%s:%d" host port in
  let () = ZMQ.Socket.connect socket host_and_port in
  (context, socket)

let zmq_dummy_client_setup () =
  let context = ZMQ.Context.create () in
  let socket = ZMQ.Socket.create context ZMQ.Socket.req in
  (context, socket)

let zmq_cleanup socket context =
  ZMQ.Socket.close socket;
  ZMQ.Context.terminate context

open Batteries (* everything before uses Legacy IOs (fast) *)

let hostname (): string =
  let stat, res = run_and_read "hostname -f" in
  assert(stat = Unix.WEXITED 0);
  String.strip res (* rm trailing \n *)
