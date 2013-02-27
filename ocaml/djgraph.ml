(*
 * dj_graph.ml
 *
 * Constructs a dj_graph from a graph, as described in
 *   Vugranam C. Sreedhar, Guang R. Gao, and Yong-Fong Lee. 1996.
 *   Identifying loops using DJ graphs.
 *   ACM Trans. Program. Lang. Syst. 18, 6 (November 1996), 649-658.
 *   DOI=10.1145/236114.236115 http://doi.acm.org/10.1145/236114.236115
 *)

(* The miminal set of graph features necessary for DJGraph.Make. *)
module type G = sig
  type t

  module V : Graph.Sig.VERTEX

  val iter_vertex : (V.t -> unit) -> t -> unit
  val nb_vertex : t -> int
  val iter_edges : (V.t -> V.t -> unit) -> t -> unit

  (* Required to support Dominator.G. *)
  val pred : t -> V.t -> V.t list
  val succ : t -> V.t -> V.t list
  val fold_vertex : (V.t -> 'a -> 'a) -> t -> 'a -> 'a
end

(*
 * DJ Edges can be D edges (dominating edges) or J (joining edges). D edges are
 * edges in the underlying dominator tree. There are two types of J edge:
 *  - BJ (back join). An edge x -> y is a BJ edge if y dom x
 *  - CJ (cross join). An edge x -> y is a CJ edge otherwise.
 *
 *  Warning: DJ Edges are not comparable.
 *)
module DJE =  struct
  type t = D | BJ | CJ

  exception NotComparable

  (* TODO(awreece) Can we avoid needing a comparison function? *)
  let compare l r = raise NotComparable
  let default = D
end

(* 
 * Make is a functor that returns a Djgraph module. Note that a Djgraph is an
 * extension to Graph
 *)
module type MakeType =
  functor (Gr: G) ->
    sig
      include Graph.Sig.I with type E.label = DJE.t

      val dj_graph: Gr.t -> Gr.V.t -> t
      (* The underlying vertex in the graph. *)
      val to_underlying: V.t -> Gr.V.t
      (* The level in the djgraph. *)
      val level: V.t -> int
    end

(* TODO(awreece) Accept a builder parameter? *)
module Make: MakeType = functor(G : G) -> struct
  (* TODO(awreece) Avoid forcing them to use an imperative graph? *)
  module DJG = Graph.Imperative.Digraph.ConcreteLabeled(struct
    (* level * vertex *)
    type t = int * G.V.t

    (* Use operations from underlying vertex implementation. *)
    let compare (_,u) (_,v) = G.V.compare u v
    let hash (_,v) = G.V.hash v
    let equal (_,u) (_,v) = G.V.equal u v
  end)(DJE)
  include DJG
  open DJG

  (*
   * to_underlying : V.t -> G.V.t
   *
   * to_underlying vertex Returns the underlying vertex for the vertex in the
   *               djgraph
   *)
  let to_underlying (_,v) = v

  (*
   * level : V.t -> int
   *
   * level vertex Returns the level of the vertex in the djgraph
   *)
  let level (l,_) = l

  (*
   * dj_graph : G.t -> G.V.t -> DJG.t
   *
   * dj_graph graph start_vertex Computes and returns the DJ graph of given
   *                             graph, starting from the designated node.
   *)
  let dj_graph graph start_vertex =
    let module Dom = Dominator.Make(G) in
    let module H = Hashtbl.Make(G.V) in

    let dom_funs = Dom.compute_all graph start_vertex in
    (*
     * dom_tree : G.V.t -> G.V.t list
     *
     * dom_tree v returns the list of nodes immediately dominated by v
     *)
    let dom_tree = Dom.(dom_funs.dom_tree) in
    (*
     * dom : G.V.t -> G.V.t -> bool
     *
     * dom u v returns truee iff u dominates v
     *)
    let dom = Dom.(dom_funs.dom) in
    (* A map from vertices in G.V.t to vertices in DJG.V.t *)
    let vertices_map = H.create (G.nb_vertex graph) in
    (*
     * add_all_vertices level start_vertex
     *          Adds start_vertex and all descendents to vertices_map, assuming
     *          start_vertex is at the given level from the origin.
     *
     *)
    let rec add_all_vertices level start_vertex =
        H.add vertices_map start_vertex (level, start_vertex);
        List.iter (add_all_vertices (level+1)) (dom_tree start_vertex) in
    let () = add_all_vertices 0 start_vertex in
    (*
     * g_to_dg v returns the vertex in the dj_graph correspoding to the given
     *           vertex in the original graph.
     *
     * Assumes the map has already been initialized with all the vertices.
     *)
    let g_to_djg v = H.find vertices_map v in
    (* The graph we will return *)
    let dj_graph = DJG.create ~size:(G.nb_vertex graph) () in
    (* Add edge of type t from u to v to the dj_graph. *)
    let add_edge t u v = let uv = g_to_djg u in
                         let vv = g_to_djg v in
                         DJG.add_edge_e dj_graph (DJG.E.create uv t vv) in
    (*
     * Add DJE.D edges from v to every vertex in idoms, the list of vertices
     * it immediately dominates.
     *)
    let add_d_edges v idoms = List.iter (add_edge DJE.D v) idoms in
    (* Add the correct DJE.J edge from u to v if there is no D edge already *)
    let maybe_add_j_edge s d = if DJG.mem_edge dj_graph (g_to_djg s) (g_to_djg d)
                               then () else if dom d s
                               then add_edge DJE.BJ s d
                               else add_edge DJE.CJ s d in
    let () = G.iter_vertex (fun v -> add_d_edges v (dom_tree v)) graph in
    let () = G.iter_edges maybe_add_j_edge graph in
    dj_graph
end
