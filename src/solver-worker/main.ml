open Lwt.Syntax

let solve_to_custom req =
  let open Cluster_api.Raw in
  let params =
    Yojson.Safe.to_string
    @@ Solver_service_api.Worker.Solve_request.to_yojson req
  in
  let custom = Builder.Custom.init_root () in
  let builder = Builder.Custom.payload_get custom in
  let request =
    Solver_service_api.Raw.Builder.Solver.Solve.Params.init_pointer builder
  in
  Solver_service_api.Raw.Builder.Solver.Solve.Params.request_set request params;
  let r = Reader.Custom.of_builder custom in
  Reader.Custom.payload_get r

let solve_of_custom c =
  let open Solver_service_api.Raw in
  let payload = Cluster_api.Custom.payload c in
  let request =
    Reader.Solver.Solve.Params.request_get @@ Reader.of_pointer payload
  in
  Solver_service_api.Worker.Solve_request.of_yojson
  @@ Yojson.Safe.from_string request

module Service = Solver_service.Service.Make (Solver_service.Opam_repository)

let spawn_local ?solver_dir () : Solver_service_api.Solver.t =
  let p, c = Unix.(socketpair PF_UNIX SOCK_STREAM 0 ~cloexec:true) in
  Unix.clear_close_on_exec c;
  let solver_dir = match solver_dir with None -> "solver" | Some x -> x in
  let cmd = ("", [| "solver-service" |]) in
  let _child =
    Lwt_process.open_process_none ~cwd:solver_dir ~stdin:(`FD_move c) cmd
  in
  let switch = Lwt_switch.create () in
  let p =
    Lwt_unix.of_unix_file_descr p
    |> Capnp_rpc_unix.Unix_flow.connect ~switch
    |> Capnp_rpc_net.Endpoint.of_flow
         (module Capnp_rpc_unix.Unix_flow)
         ~peer_id:Capnp_rpc_net.Auth.Digest.insecure ~switch
  in
  let conn =
    Capnp_rpc_unix.CapTP.connect ~restore:Capnp_rpc_net.Restorer.none p
  in
  let solver =
    Capnp_rpc_unix.CapTP.bootstrap conn
      (Capnp_rpc_net.Restorer.Id.public "solver")
  in
  solver
  |> Capnp_rpc_lwt.Capability.when_broken (fun ex ->
         Fmt.failwith "Solver process failed: %a" Capnp_rpc.Exception.pp ex);
  solver

let cluster_worker_log log =
  let module L = Solver_service_api.Raw.Service.Log in
  L.local
  @@ object
       inherit L.service

       method write_impl params release_param_caps =
         let open L.Write in
         release_param_caps ();
         let msg = Params.msg_get params in
         Cluster_worker.Log_data.write log msg;
         Capnp_rpc_lwt.Service.(return (Response.create_empty ()))
     end

let build ~solver ~switch:_ ~log ~src:_ ~secrets:_ = function
  | `Docker _ | `Obuilder _ ->
      failwith "Solver-worker doesn't support Docker or Obuilder jobs"
  | `Custom c -> (
      match solve_of_custom c with
      | Error m -> failwith m
      | Ok s ->
          let+ response =
            Solver_service_api.Solver.solve ~log:(cluster_worker_log log) solver
              s
          in
          Ok
            (Yojson.Safe.to_string
            @@ Solver_service_api.Worker.Solve_response.to_yojson response))

let setup_log ?(formatter = Format.err_formatter) default_level =
  Prometheus_unix.Logging.init ~formatter ?default_level ();
  ()

let or_die = function Ok x -> x | Error (`Msg m) -> failwith m

let check_exit_status = function
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED x -> Fmt.failwith "Sub-process failed with exit code %d" x
  | Unix.WSIGNALED x -> Fmt.failwith "Sub-process failed with signal %d" x
  | Unix.WSTOPPED x -> Fmt.failwith "Sub-process stopped with signal %d" x

let main capacity name registration_path state_dir =
  let update () = Lwt.return (fun () -> Lwt.return ()) in
  Lwt_main.run
    (let vat = Capnp_rpc_unix.client_only_vat () in
     let sr = Capnp_rpc_unix.Cap_file.load vat registration_path |> or_die in
     let solver =
       spawn_local ~solver_dir:(Filename.concat state_dir "solver") ()
     in
     Cluster_worker.run ~capacity ~name ~allow_push:[] ~build:(build ~solver)
       ~state_dir ~update sr)

open Cmdliner

let worker_name =
  Arg.required
  @@ Arg.opt Arg.(some string) None
  @@ Arg.info ~doc:"Unique worker name" ~docv:"ID" [ "name" ]

let connect_addr =
  Arg.required
  @@ Arg.opt Arg.(some file) None
  @@ Arg.info ~doc:"Path of register.cap from scheduler" ~docv:"ADDR"
       [ "c"; "connect" ]

let capacity =
  Arg.value @@ Arg.opt Arg.int 10
  @@ Arg.info ~doc:"The number of builds that can run in parallel" ~docv:"N"
       [ "capacity" ]

let state_dir =
  Arg.required
  @@ Arg.opt Arg.(some string) None
  @@ Arg.info ~doc:"Directory for caches, etc (e.g. /var/lib/ocluster-worker)"
       ~docv:"PATH" [ "state-dir" ]

let cmd =
  let doc = "Run a solver worker" in
  let man = [ `P "An OCluster worker that can solve!" ] in
  ( Term.(const main $ capacity $ worker_name $ connect_addr $ state_dir),
    Term.info "solver-worker" ~doc ~man )

let () = Term.(exit @@ eval cmd)
