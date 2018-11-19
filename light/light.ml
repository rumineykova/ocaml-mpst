(* dune build light/light.exe && ./_build/default/light/light.exe *)

module Channel : sig
  type 'a t
  val create : unit -> 'a t
  val send : 'a t -> 'a -> unit
  val recv : 'a t -> 'a
  val choose : ('a t * 'b) list -> 'a * 'b
end = struct
  type 'a t = 'a Event.channel
  let create () = Event.new_channel ()
  let send t v = Event.sync (Event.send t v)
  let recv t = Event.sync (Event.receive t)
  let wrap (t,a) =
    Event.wrap (Event.receive t) (fun v -> v, a)
  let choose xs =
    Event.sync (Event.choose (List.map wrap xs))
end
    
module UnsafeChannel : sig
  type t
  val create : unit -> t
  val send : t -> 'a -> unit
  val recv : t -> 'a
  val choose : (t * 'b) list -> 'a * 'b
end = struct
  type t = unit Event.channel
  let create () = Event.new_channel ()
  let send t v = Event.sync (Event.send t (Obj.magic v))
  let recv t = Obj.magic (Event.sync (Event.receive t))
  let wrap (t,a) =
    Event.wrap (Event.receive t) (fun v -> Obj.magic v, a)
  let choose xs =
    Event.sync (Event.choose (List.map wrap xs))
end

module Local : sig
  type ('a, 'b) left_or_right
  type ('a, 'b) left_and_right
  type ('a, 'b) either = Left of 'a | Right of 'b
  type ('s, 'v, 'r) send
  type ('s, 'v, 'r) recv
  type ('ss, 'r) select
  type ('ss, 'r) offer
  type close
  type 'c sess
  val send : 'r -> 'v -> ('s,'v,'r) send sess -> 's sess
  val receive : 'r -> ('s,'v,'r) recv sess -> 'v * 's sess
  val select_left : 'r -> (('s1, 's2) left_or_right,'r) select sess -> 's1 sess
  val select_right : 'r -> (('s1, 's2) left_or_right,'r) select sess -> 's2 sess
  val offer : 'r -> (('s1, 's2) left_and_right,'r) offer sess -> ('s1 sess, 's2 sess) either
  val close : 'a sess -> unit

  (* session creation *)
  module Internal : sig
    val s2c : from:('r1 * 's1 sess Lazy.t) ->
              to_:('r2 * 's2 sess Lazy.t) ->
              ('s1, 'v, 'r2) send sess * ('s2, 'v, 'r1) recv sess
    val s2c_branch :
      from:('r1 * ('sl1 sess Lazy.t * 'sr1 sess Lazy.t)) ->
      to_:('r2 * ('sl2 sess Lazy.t * 'sr2 sess Lazy.t)) ->
      (('sl1, 'sr1) left_or_right, 'r2) select sess * (('sl2, 'sr2) left_and_right, 'r1) offer sess
    val end_ : close sess

    (* merge operator for global description *)
    val merge : 'a sess -> 'a sess -> 'a sess
  end

end = struct

  type ('a,'b) either = Left of 'a | Right of 'b

  type ('s,'v,'r) send = DummySend of 's * 'v * 'r
  type ('s,'v,'r) recv = DummyRecv of 's * 'v * 'r

  type ('ss,'r) select = DummySelect of 'ss * 'r
  type ('ss,'r) offer = DummyOffer of 'ss * 'r

  type close

  type _ raw_sess =
  | Send : 'r * 'v Channel.t * 's raw_sess Lazy.t -> ('s, 'v, 'r) send raw_sess
  | Recv : 'r * ('v Channel.t * 's raw_sess Lazy.t) list -> ('s, 'v, 'r) recv raw_sess
  | Select : 'r * 'ss -> ('ss, 'r) select raw_sess
  | Offer : 'r * 'ss list -> ('ss, 'r) offer raw_sess
  | Close : close raw_sess

  type 'c sess = Sess of 'c raw_sess
  let unsess (Sess s) = s

  let send _ v (Sess s) =
    match s with
    | Send (_,ch,cont) ->
       Channel.send ch v;
       Sess (Lazy.force cont)
          
  let receive (_:'r) (Sess s) =
    match s with
    | Recv (_,xs) ->
       let v,s = Channel.choose xs in
       v, Sess (Lazy.force s)

  type ('s1, 's2) left_or_right = {left_:unit Channel.t * 's1 sess; right_:unit Channel.t * 's2 sess}
  type ('s1, 's2) left_and_right = Left_ of unit Channel.t * 's1 sess | Right_ of unit Channel.t * 's2 sess
       
  let select_left r (Sess (Select (_,s))) =
    let ch,s = s.left_ in
    Channel.send ch ();
    s

  let select_right r (Sess (Select (_,s))) =
    let ch,s = s.right_ in
    Channel.send ch ();
    s

  let offer (_:'r) (Sess s) =
    match s with
    | Offer (_,xs) ->
       let xs = List.map (function Left_ (ch,s) -> (ch,Left s) | Right_ (ch,s) -> (ch,Right s)) xs in
       snd (Channel.choose xs)
       
  let close (Sess _) = ()

  let unsess' s = lazy (unsess (Lazy.force s))

  module Internal = struct
    
    let s2c ~from:(r1,s1) ~to_:(r2,s2) =
      let ch = Channel.create () in
      Sess (Send (r2, ch, unsess' s1)), Sess (Recv (r1, [(ch, unsess' s2)]))

    let s2c_branch ~from:(r1,(sl1,sr1)) ~to_:(r2,(sl2,sr2)) =
      let cl = Channel.create () in
      let cr = Channel.create () in
      Sess (Select (r2,{left_=(cl, Lazy.force sl1); right_=(cr, Lazy.force sr1)})),
      Sess (Offer (r1,[Left_ (cl, Lazy.force sl2); Right_ (cr, Lazy.force sr2)]))

    let end_ = Sess Close

    let merge : type t. t sess -> t sess -> t sess = fun (Sess x) (Sess y) ->
      match x, y with
      | Send (_,_,_), Send (_,_,_) ->
         failwith "role not enabled"
      | Select _, Select _ ->
         failwith "role not enabled"
      | Recv (r,xs), Recv (_,ys) ->
         Sess (Recv (r, xs @ ys))
      | Offer (r, xs), Offer (_, ys) ->
         Sess (Offer (r, xs @ ys))
      | Close, Close ->
         Sess Close
  end
end

module Global : sig
  type ('v1, 'v2, 's1, 's2) lens = {
    get : 's1 -> 'v1;
    put : 's1 -> 'v2 -> 's2;
  }
  type ('r, 'v1, 'v2, 's1, 's2) role = {
    role : 'r;
    lens : ('v1, 'v2, 's1, 's2) lens;
    merge : 's2 -> 's2 -> 's2;
    }
                                     
  open Local
  val ( --> ) :
    ('ra, 'sa sess, ('sa, 'v, 'rb) send sess, 'c0, 'c1) role ->
    ('rb, 'sb sess, ('sb, 'v, 'ra) recv sess, 'c1, 'c2) role ->
    'c0 -> 'c2

  val ( -%%-> ) :
    ('ra, close sess, (('sal, 'sar) left_or_right, 'rb) select sess, 'c2, 'c3) role ->
    ('rb, close sess, (('sbl, 'sbr) left_and_right, 'ra) offer sess, 'c3, 'c4) role ->
    (('ra, 'sal sess, close sess, 'cl0, 'cl1) role *
     ('rb, 'sbl sess, close sess, 'cl1, 'c2) role) *
    'cl0 ->
    (('ra, 'sar sess, close sess, 'cr0, 'cr1) role *
     ('rb, 'sbr sess, close sess, 'cr1, 'c2) role) *
    'cr0 -> 'c4
end= struct
  type ('v1, 'v2, 's1, 's2) lens = {
    get : 's1 -> 'v1;
    put : 's1 -> 'v2 -> 's2;
  }
  type ('r, 'v1, 'v2, 's1, 's2) role = {
    role : 'r;
    lens : ('v1, 'v2, 's1, 's2) lens;
    merge : 's2 -> 's2 -> 's2;
  }
  open Local.Internal

  let (-->) a b c0 =
    let sa = lazy (a.lens.get c0) in
    let rec sb = lazy (b.lens.get (Lazy.force c1)) 
    and sab' = lazy (s2c ~from:(a.role, sa) ~to_:(b.role, sb))
    and c1 = lazy (a.lens.put c0 (fst (Lazy.force sab'))) in
    let c2 = b.lens.put (Lazy.force c1) (snd (Lazy.force sab')) in
    c2

  let (-%%->) a b ((al,bl),cl) ((ar,br),cr) =
    let sal, sar = lazy (al.lens.get cl), lazy (ar.lens.get cr) in
    let cl, cr = al.lens.put cl end_, ar.lens.put cr end_ in
    let sbl, sbr = lazy (bl.lens.get cl), lazy (br.lens.get cr) in
    let cl, cr = bl.lens.put cl end_, br.lens.put cr end_ in
    let c = bl.merge cl cr in
    let sa, sb = s2c_branch ~from:(a.role, (sal,sar)) ~to_:(b.role, (sbl,sbr)) in
    let c = a.lens.put c sa in
    let c = b.lens.put c sb in
    c
end

module ThreeParty = struct
  open Local.Internal

  let finish3 =
    end_, end_, end_

  type a = A
  type b = B
  type c = C

  let merge3 (x, y, z) (x', y', z') = merge x x', merge y y', merge z z'

  open Global

  let a = {role=A; lens={get=(fun (x,_,_) -> x); put=(fun (_,y,z) x->(x,y,z))}; merge=merge3}
  let b = {role=B; lens={get=(fun (_,y,_) -> y); put=(fun (x,_,z) y->(x,y,z))}; merge=merge3}
  let c = {role=C; lens={get=(fun (_,_,z) -> z); put=(fun (x,y,_) z->(x,y,z))}; merge=merge3}
end

open Global
open ThreeParty
include Local

let global_example () =
  (* let open Global in *)
  (a --> b) @@
  (b --> c) @@
  (a -%%-> b)
    ((a,b), b --> c @@
            finish3)
    ((a,b), b --> a @@
            b --> c @@
            finish3)

let t1 sa =
  let s = sa in
  let s = send B 100 s in
  if Random.bool () then
    let s = select_left B s in
    close s
  else
    let s = select_right B s in
    let v,s = receive B s in
    Printf.printf "A: received: %s\n" v;
    close s
  
let t2 sb =
  let s = sb in
  let v,s = receive A s in
  Printf.printf "B: received: %d\n" v;
  let s = send C "Hello" s in
  match offer A s with
  | Left s ->
     let s = send C "to C (1)" s in
     close s
  | Right s ->
     let s = send A "to A" s in
     let s = send C "to C (2)" s in
     close s
    
let t3 sc =
  let s = sc in
  let v,s = receive B s in
  Printf.printf "C: received: %s\n" v;
  let w,s = receive B s in
  Printf.printf "C: received: %s\n" w;
  close s
    
let main () =
  Random.self_init ();
  let g = global_example () in
  let sa, sb, sc = a.lens.get g, b.lens.get g, c.lens.get g in
  let t1id = Thread.create (fun () -> t1 sa) () in
  let t2id = Thread.create (fun () -> t2 sb) () in
  t3 sc;
  Thread.join t1id;
  Thread.join t2id;
  ()

let () = main ()