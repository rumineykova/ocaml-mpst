open Mpst.Base
open Mpst.Session
open Mpst.Session.Local
open Mpst.Session.MPST

(* Global protocol *)
let g =
    (c --> a) (msg int) @@
    (a -%%-> b)
      ~left:((a,b),
             (b --> c) right @@
             (b --> a) (msg str) @@
             (c --> a) (msg int) @@
             finish)
      ~right:((a,b),
             (b --> a) (msg int) @@
             (b --> c) left @@
             (c --> a) (msg str) @@
             finish)

(* serialisers (will be generated by scribble) *)
type b_serialiser =
  {b_send_bool : bool -> unit;
   b_receive_int : unit -> int Lwt.t;
   b_receive_string : unit -> string Lwt.t
  }

type c_serialiser =
  {c_receive_int : unit -> int Lwt.t;
   c_receive_string : unit -> string Lwt.t
  }

let run_serialiser_a s (b:b_serialiser) (c:c_serialiser) : unit Lwt.t =
  match s with
  | Recv(C,{contents=(_,c1)},
         SelectLeftRight(B,{contents=(b1,_)},
                         Recv(B,{contents=(_,b2)},Recv(C,{contents=(_,c2)},Close)),
                         Recv(B,{contents=(_,b3)},Recv(C,{contents=(_,c3)},Close)))) ->
     let open Lwt in
     c.c_receive_int () >>= fun v ->
     Lwt.wakeup_later c1 v;
     b1 >>= fun v ->
     b.b_send_bool v;
     if v then begin
         b.b_receive_string () >>= fun v ->
         Lwt.wakeup_later b2 v;
         c.c_receive_int () >>= fun v ->
         Lwt.wakeup_later c2 v;
         Lwt.return ()
       end else begin
         b.b_receive_int () >>= fun v ->
         Lwt.wakeup_later b3 v;
         c.c_receive_string () >>= fun v ->
         Lwt.wakeup_later c3 v;
         Lwt.return ()
       end

let pa = get_sess a g

(* participant A *)
let (t1 : unit Lwt.t) =
  let s = pa in
  let open Lwt in
  receive C s >>= fun (x, s) -> begin
      if x = 0 then begin
          let s = select_left_ B s in
          receive B s >>= fun (str,s) ->
          Printf.printf "A: B says: %s\n" str;
          receive C s >>= fun (n,s) ->
          close s;
          return ()
        end else begin
          let s = select_right_ B s in
          receive B s >>= fun (x,s) ->
          receive C s >>= fun (str,s) ->
          Printf.printf "A: B says: %d, C says: %s\n" x str;
          close s;
          return ()
        end;
    end >>= fun () ->
  print_endline "A finished.";
  return ()

(* run A's serialiser *)
let (_ : unit Lwt.t) =
  let console_int role =
    let open Lwt in
    print_endline (role ^ ": enter a number:");
    Lwt_io.read_line Lwt_io.stdin >>= fun line ->
    return (int_of_string line)
  in
  run_serialiser_a
    pa
    {b_send_bool=(fun _ -> ());
     b_receive_int=(fun _ -> console_int "B");
     b_receive_string=(fun _ -> Lwt.return "Hello!")}
    {c_receive_int=(fun _ -> console_int "C");
     c_receive_string=(fun _ -> Lwt.return "Hooray!")}

let _ =
  Lwt_main.run t1
