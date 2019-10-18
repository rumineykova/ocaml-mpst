open Base
open Common

module Make
         (EP:S.ENDPOINTS)
         (StaticLin:S.LIN)
         (M:S.MONAD)
         (EV:S.EVENT with type 'a monad = 'a M.t)
         (C:S.SERIAL with type 'a monad = 'a M.t)
  = struct


  include Channel.Make(EP)(StaticLin)(M)(EV)(C)

  type 'g global = (epkind, 'g) t

  let rm_size {metainfo;_} idx =
    option ~dflt:1 ~f:(fun x -> x.rm_size) (Table.get_opt metainfo idx)

  let rm_kind {metainfo;default} idx cnt =
    match Table.get_opt metainfo idx with
    | Some p -> p.rm_kind
    | None ->
       let kind = default cnt in
       let p = {rm_index=idx; rm_size=cnt; rm_kind=kind} in
       Table.put metainfo idx p;
       kind

  let make_metainfo ?size env role =
    let rm_index = Seq.int_of_lens role.role_index in
    let rm_size = of_option size ~dflt:(rm_size env rm_index) in
    let rm_kind = rm_kind env rm_index rm_size in
    {rm_index; rm_kind; rm_size}


  let a2b env ?num_senders ?num_receivers ~gen ~make_out = fun rA rB label g0 ->
    let from_info = make_metainfo ?size:num_senders env rA in
    let to_info = make_metainfo ?size:num_receivers env rB in
    let epB = Seq.lens_get rB.role_index g0 in
    let och,ich = gen label epB from_info to_info in
    let epB = EP.wrap_label rA.role_label ich in
    let g1  = Seq.lens_put rB.role_index g0 epB
    in
    let epA = Seq.lens_get rA.role_index g1 in
    let out = make_out label och epA in
    let epA = EP.wrap_label rB.role_label out in
    let g2  = Seq.lens_put rA.role_index g1 epA
    in g2

  let ( --> ) : 'roleAobj 'labelvar 'epA 'roleBobj 'g1 'g2 'labelobj 'epB 'g0 'v.
                (< .. > as 'roleAobj, 'labelvar Inp.inp EP.lin, 'epA, 'roleBobj, 'g1, 'g2) role ->
                (< .. > as 'roleBobj, 'labelobj,     'epB, 'roleAobj, 'g0, 'g1) role ->
                (< .. > as 'labelobj, [> ] as 'labelvar, ('v one * 'epA) Out.out EP.lin, 'v * 'epB StaticLin.lin) label ->
                'g0 global -> 'g2 global
    = fun rA rB label (Global g0) ->
    Global (fun env ->
        a2b ~gen:generate_one ~make_out:Out.make_out
          env rA rB label (g0 env)
      )

  let scatter : 'roleAobj 'labelvar 'epA 'roleBobj 'g1 'g2 'labelobj 'epB 'g0 'v.
                (< .. > as 'roleAobj, 'labelvar Inp.inp EP.lin, 'epA, 'roleBobj, 'g1, 'g2) role ->
                (< .. > as 'roleBobj, 'labelobj,     'epB, 'roleAobj, 'g0, 'g1) role ->
                (< .. > as 'labelobj, [> ] as 'labelvar, ('v list * 'epA) Out.out EP.lin, 'v * 'epB StaticLin.lin) label ->
                'g0 global -> 'g2 global
    = fun rA rB label (Global g0) ->
    Global (fun env ->
        a2b ~num_senders:1 ~gen:generate_scatter ~make_out:Out.make_outmany
          env rA rB label (g0 env)
      )

  let gather : 'roleAobj 'labelvar 'epA 'roleBobj 'g1 'g2 'labelobj 'epB 'g0 'v.
               (< .. > as 'roleAobj, 'labelvar Inp.inp EP.lin, 'epA, 'roleBobj, 'g1, 'g2) role ->
               (< .. > as 'roleBobj, 'labelobj,     'epB, 'roleAobj, 'g0, 'g1) role ->
               (< .. > as 'labelobj, [> ] as 'labelvar, ('v one * 'epA) Out.out EP.lin, 'v list * 'epB StaticLin.lin) label ->
               'g0 global -> 'g2 global
    = fun rA rB label (Global g0) ->
    Global (fun env ->
        a2b ~num_receivers:1 ~gen:generate_gather ~make_out:Out.make_out
          env rA rB label (g0 env)
      )

  let local _ = EpLocal


  let ipc cnt =
    EpDpipe (List.init cnt (fun _ -> Table.create ()))

  let untyped cnt =
    EpUntyped (List.init cnt (fun _ -> Table.create ()))

  let gen g =
    gen_with_param
      {metainfo=Table.create (); default=local} g

  let gen_ipc g =
    gen_with_param
      {metainfo=Table.create (); default=ipc} g

  let gen_mult ps g =
    let ps = List.map (fun cnt -> {rm_size=cnt;rm_kind=EpLocal}) ps in
    gen_with_param
      {metainfo=Table.create_from ps; default=local}
      g

  let gen_mult_ipc ps g =
    let ps = List.map (fun cnt -> {rm_size=cnt;rm_kind=ipc cnt}) ps in
    gen_with_param
      {metainfo=Table.create_from ps; default=ipc}
      g

  type kind = [`Local | `IPCProcess | `Untyped]
  let rm_kind_of_kind = function
    | `Local -> fun i -> {rm_size=i; rm_kind=EpLocal}
    | `IPCProcess -> fun i -> {rm_size=i; rm_kind=ipc i}
    | `Untyped -> fun i -> {rm_size=i; rm_kind=untyped i}

  let mkparams ps =
    {metainfo =
       Table.create_from
         (List.map (fun k -> rm_kind_of_kind k 1) ps);
     default=local}

  let mkparams_mult ps =
    {metainfo =
       Table.create_from
         (List.map (fun (k,p) -> rm_kind_of_kind k p) ps);
     default=local}

  let gen_with_kinds ps g =
    gen_with_param
      (mkparams ps)
      g

  let gen_with_kinds_mult ps g =
    gen_with_param
      (mkparams_mult ps)
      g

type 'a ty = Ty__ of (unit -> 'a StaticLin.lin)

let get_ty_ : ('x0, 'x1, 'ep StaticLin.lin, 'x2, 't, 'x3) role -> 't Seq.t -> 'ep ty =
  fun r g ->
  Ty__ (fun () -> get_ch r g)

let get_ty : ('x0, 'x1, 'ep StaticLin.lin, 'x2, 't, 'x3) role -> 't global -> 'ep ty =
  fun r g ->
  get_ty_ r (gen g)

  type _ shared =
    Shared :
      {global: [`cons of 'ep * 'tl] global;
       kinds: kind list option;
       accept_lock: Mutex.t; (* FIXME: parameterise over other lock types? *)
       connect_sync: epkind env EV.channel list;
       start_sync: unit EV.channel;
       mutable seq_in_process: (epkind env * [`cons of 'ep * 'tl] Seq.t) option;
      } -> [`cons of 'ep * 'tl] shared


  let rec sync_all_ except_me connect_sync start_sync env =
    M.iteriM (fun i c ->
        if i=except_me then begin
          M.return_unit
          end else begin
          M.bind (EV.sync (EV.send c env)) (fun () ->
              EV.sync (EV.receive start_sync))
          end
      )
      connect_sync


  let init_seq_ (Shared m) =
    match m.seq_in_process with
    | Some (env,g) ->
       env,g
    | None ->
       let env =
         match m.kinds with
         | Some kinds -> mkparams kinds
         | None -> {metainfo=Table.create (); default=local}
       in
       let g = gen_with_param env m.global in
       m.seq_in_process <- Some (env,g);
       env,g

  let create_shared ?kinds global =
    let accept_lock = Mutex.create () in
    let env =
      match kinds with
      | Some kinds -> mkparams kinds
      | None -> {metainfo=Table.create (); default=local}
    in
    let seq = gen_with_param env global in
    let len = Seq.effective_length seq in
    let connect_sync = List.init len (fun _ -> EV.new_channel ()) in
    Shared
      {global;
       kinds;
       accept_lock;
       connect_sync;
       start_sync=EV.new_channel ();
       seq_in_process=Some (env,seq)}

  let accept_ (Shared m) r =
    Mutex.lock m.accept_lock;
    let env, g = init_seq_ (Shared m) in
    (* sync with all threads *)
    let me = Seq.int_of_lens r.role_index in
    M.bind (sync_all_ me m.connect_sync m.start_sync env) (fun () ->
    (* get my ep *)
    let ep = get_ch r g in
    m.seq_in_process <- None;
    Mutex.unlock m.accept_lock;
    let prop = Table.get env.metainfo (Seq.int_of_lens r.role_index) in
    M.return (ep, prop))

  let connect_ (Shared m) r =
    let role = Seq.int_of_lens r.role_index in
    let c = EV.flip_channel (List.nth m.connect_sync role) in
    M.bind (EV.sync (EV.receive c)) (fun env ->
        let prop = Table.get env.metainfo role in
        let g = match m.seq_in_process with Some (_,g) -> g | None -> assert false in
        let ep = get_ch r g in
        M.bind (EV.sync (EV.send (EV.flip_channel m.start_sync) ())) (fun () ->
        M.return (ep, prop)))

  let accept sh r =
    M.map fst (accept_ sh r)

  let connect sh r =
    M.map fst (connect_ sh r)

  let accept_and_start sh r f =
    M.bind (accept_ sh r) (fun (ep,prop) ->
        match prop.rm_kind with
        | EpLocal | EpUntyped _ ->
           ignore (Thread.create (fun () -> (f ep : unit)) ());
           M.return_unit
        | EpDpipe _ ->
           ignore (C.fork_child (fun () -> f ep));
           M.return_unit)

  let connect_and_start sh r f =
    M.bind (connect_ sh r) (fun (ep,prop) ->
        match prop.rm_kind with
        | EpLocal | EpUntyped _ ->
           ignore (Thread.create (fun () -> (f ep : unit)) ());
           M.return_unit
        | EpDpipe _ ->
           ignore (C.fork_child (fun () -> f ep));
           M.return_unit)

  let (>:) :
        ('obj,'var,('v StaticLin.lin one * 'epA) Out.out EP.lin, 'v StaticLin.lin * 'epB StaticLin.lin) label ->
        (unit -> 'v) ->
        ('obj,'var,('v StaticLin.lin one * 'epA) Out.out EP.lin, 'v StaticLin.lin * 'epB StaticLin.lin) label =
    fun l _ -> l

  let (>>:) :
        ('obj,'var,('v EP.lin list * 'epA) Out.out EP.lin, 'v EP.lin * 'epB StaticLin.lin) label ->
        (unit -> 'v) ->
        ('obj,'var,('v EP.lin list * 'epA) Out.out EP.lin, 'v EP.lin * 'epB StaticLin.lin) label =
    fun l _ -> l

  let prot a g () = get_ch a (gen g)
end[@@inline]
