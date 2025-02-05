open Utils

let ( >>= ) = ResultMonad.( >>= )

type sql_binary_operator =
  | SqlPlus    (* + *)
  | SqlMinus   (* - *)
  | SqlTimes   (* * *)
  | SqlDivides (* / *)
  | SqlLor     (* || *)

type sql_unary_operator =
  | SqlNegate (* - *)

type sql_operator =
  | SqlRelEqual
  | SqlRelNotEqual
  | SqlRelGeneral of string

type sql_table_name = string

type sql_column_name = string

type sql_instance_name = string

type sql_column = sql_instance_name option * sql_column_name

type sql_vterm =
  | SqlConst    of Expr.const
  | SqlColumn   of sql_column
  | SqlUnaryOp  of sql_unary_operator * sql_vterm
  | SqlBinaryOp of sql_binary_operator * sql_vterm * sql_vterm

type sql_constraint =
  | SqlConstraint of sql_vterm * sql_operator * sql_vterm

type sql_where_clause =
  | SqlWhere of sql_constraint list

type sql_update =
  | SqlUpdateSet of sql_table_name * (sql_column * sql_vterm) list * sql_where_clause option

let string_of_sql_binary_operator = function
  | SqlPlus    -> "+"
  | SqlMinus   -> "-"
  | SqlTimes   -> "*"
  | SqlDivides -> "/"
  | SqlLor     -> "||"

let string_of_sql_unary_operator = function
  | SqlNegate -> "-"

let string_of_sql_operator = function
  | SqlRelEqual      -> "="
  | SqlRelNotEqual   -> "<>"
  | SqlRelGeneral op -> op

let string_of_sql_column_ignore_instance (_, column) = column

type error =
  | InvalidColumnName of string

let string_of_error = function
  | InvalidColumnName name -> Printf.sprintf "Invalid Column Name: %s" name

(** Column Name (as String) to Expr.var *)
module ColumnVarMap = Map.Make(String)

let rec ast_vterm_of_sql_vterm colvarmap = function
  | SqlConst const ->
      ResultMonad.return (Expr.Const const)
  | SqlColumn column ->
      let column_name = string_of_sql_column_ignore_instance column in
      ColumnVarMap.find_opt column_name colvarmap
        |> Option.map (fun var -> Expr.Var var)
        |> Option.to_result ~none:(InvalidColumnName column_name)
  | SqlUnaryOp (op, sql_vterm) ->
      ast_vterm_of_sql_vterm colvarmap sql_vterm >>= fun vterm ->
      let op = string_of_sql_unary_operator op in
      ResultMonad.return (Expr.UnaryOp (op, vterm))
  | SqlBinaryOp (op, left, right) ->
      ast_vterm_of_sql_vterm colvarmap left >>= fun left ->
      ast_vterm_of_sql_vterm colvarmap right >>= fun right ->
      let op = string_of_sql_binary_operator op in
      ResultMonad.return (Expr.BinaryOp (op, left, right))

let ast_terms_of_sql_where_clause colvarmap = function
  | SqlWhere sql_constraints ->
    let ast_term_of_sql_constraint = function
      | SqlConstraint (left, op, right) ->
          let op = string_of_sql_operator op in
          ast_vterm_of_sql_vterm colvarmap left >>= fun left ->
          ast_vterm_of_sql_vterm colvarmap right >>= fun right ->
          ResultMonad.return (Expr.Equat (Expr.Equation (op, left, right))) in
    ResultMonad.mapM
      ast_term_of_sql_constraint
      sql_constraints

let build_effect_rules colvarmap column_and_vterms tmp_pred =
  (*
   * For optimisation, generate terms in the delta-datalog language rules
   * that remove records where all columns to be updated in the SET clause
   * of the SQL are already after that update.
   *)
  column_and_vterms
    |> ResultMonad.mapM (fun (sql_col, sql_vterm) ->
      ast_vterm_of_sql_vterm colvarmap sql_vterm >>= fun vterm ->
      let column_name = string_of_sql_column_ignore_instance sql_col in
      ColumnVarMap.find_opt column_name colvarmap
        |> Option.to_result ~none:(InvalidColumnName column_name)
        >>= fun var ->
      ResultMonad.return (Expr.Equat (Expr.Equation ("<>", Expr.Var var, vterm))))
    |> ResultMonad.map (fun effect_terms ->
      effect_terms |> List.map (fun term -> tmp_pred, [term])
    )

let build_deletion_rule colvarmap where_clause table_name varlist tmp_pred =
  (* Constraints corresponding to the WHERE clause. May be empty. *)
  where_clause
    |> Option.map (ast_terms_of_sql_where_clause colvarmap)
    |> Option.value ~default:(Ok([]))
    >>= fun body ->

  (* Create a rule corresponding to the operation to delete the record to be updated. *)
  let delete_pred = Expr.Deltadelete (table_name, varlist) in
  let from = Expr.Pred (table_name, varlist) in
  ResultMonad.return (delete_pred, (Expr.Rel from :: body @ [Expr.Rel tmp_pred]))

let build_creation_rule colvarmap colvarmap' column_and_vterms table_name columns varlist =
  (* Create an expression equivalent to a SET clause in SQL. *)
  column_and_vterms
    |> ResultMonad.mapM (fun (column, vterm) ->
      ast_vterm_of_sql_vterm colvarmap' vterm >>= fun vterm ->
      let column_name = string_of_sql_column_ignore_instance column in
      ColumnVarMap.find_opt column_name colvarmap
        |> Option.map (fun var -> Expr.Equat (Expr.Equation ("=", Expr.Var var, vterm)))
        |> Option.to_result ~none:(InvalidColumnName column_name)
    ) >>= fun body ->

  (** Create a rule corresponding to the operation to insert the record to be updated. *)
  columns
    |> ResultMonad.mapM (fun column ->
      let column_name = string_of_sql_column_ignore_instance (None, column) in
      ColumnVarMap.find_opt column_name colvarmap'
        |> Option.to_result ~none:(InvalidColumnName column_name)
    ) >>= fun delete_var_list ->
  let delete_pred = Expr.Deltadelete (table_name, delete_var_list) in
  let body = body @ [Expr.Rel delete_pred] in
  let insert_pred = Expr.Deltainsert (table_name, varlist) in
  ResultMonad.return (insert_pred, body)

(**
  * Create a temporary table name,
  * but if a table with a table name ending in `_tmp` already exists,
  * it will not work well.
  *)
let make_tmp_table_name table_name = Printf.sprintf "%s_tmp" table_name

module ColumnSet = Set.Make(String)

let update_to_datalog (update : sql_update) (columns : sql_column_name list) : (Expr.rule list, error) result =
  let SqlUpdateSet (table_name, column_and_vterms, where_clause) = update in

  (* Create (column name as String, Expr.var) list. *)
  let make_column_var_list make_var =
    List.mapi (fun idx column_name ->
      let var = make_var idx column_name in
      (None, column_name), var
    )
  in
  let make_colvarmap column_var_list = column_var_list
    |> List.map (fun (col, var) -> string_of_sql_column_ignore_instance col, var)
    |> List.to_seq
    |> ColumnVarMap.of_seq in

  (*
   * The column name and the name of the variable on the delta-datalog code corresponding to that column.
   * The variable names are generated by sequential numbering from `V0`.
   *)
  let column_var_list = columns
    |> make_column_var_list (fun idx _ -> Expr.NamedVar (Printf.sprintf "GenV%d" (idx + 1))) in
  let colvarmap = make_colvarmap column_var_list in

  (*
   * `varlist` is a list of variable names for each column in the table.
   * `in_set` is the set of column names that appear in the SET clause in that SQL update statement.
   *)
  let varlist, in_set =
    List.fold_right (fun (column, var) (varlist, in_set) ->
      match List.assoc_opt column column_and_vterms with
      | None ->
          (var :: varlist), in_set
      | Some _ ->
          let column_name = string_of_sql_column_ignore_instance column in
          (var :: varlist), (ColumnSet.add column_name in_set)
      ) column_var_list ([], ColumnSet.empty)
  in

  (*
    * List of variable names corresponding to columns in the table,
    * but with new names for the columns to be updated (with the `_2` suffix).
    * The names used for columns not to be updated remain the same as those in `column_var_list`.
    *)
  let column_var_list' = columns
    |> make_column_var_list (fun idx column_name ->
      let column_name = string_of_sql_column_ignore_instance (None, column_name) in
      if ColumnSet.exists (fun c -> c = column_name) in_set then
        Expr.NamedVar (Printf.sprintf "GenV%d_2" (idx + 1))
      else
        Expr.NamedVar (Printf.sprintf "GenV%d" (idx + 1))
    ) in
  let colvarmap' = make_colvarmap column_var_list' in

  (* Pred for optimisation rules.  *)
  let tmp_pred = Expr.Pred (make_tmp_table_name table_name, varlist) in

  build_effect_rules colvarmap column_and_vterms tmp_pred
  >>= fun effect_rules ->
  build_deletion_rule colvarmap where_clause table_name varlist tmp_pred
  >>= fun delete ->
  build_creation_rule colvarmap colvarmap' column_and_vterms table_name columns varlist
  >>= fun insert ->

  ResultMonad.return (effect_rules @ [delete; insert])
