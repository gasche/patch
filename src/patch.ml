module String = struct
  let is_prefix ~prefix str =
    let pl = String.length prefix in
    if String.length str < pl then
      false
    else
      String.sub str 0 (String.length prefix) = prefix

  let cut sep str =
    try
      let idx = String.index str sep
      and l = String.length str
      in
      let sidx = succ idx in
      Some (String.sub str 0 idx, String.sub str sidx (l - sidx))
    with
      Not_found -> None

  let cuts sep str =
    let rec doit acc s =
      if String.length s = 0 then
        List.rev acc
      else
        match cut sep s with
        | None -> List.rev (s :: acc)
        | Some (a, b) -> doit (a :: acc) b
    in
    doit [] str

  let slice ?(start = 0) ?stop str =
    let stop = match stop with
      | None -> String.length str
      | Some x -> x
    in
    let len = stop - start in
    String.sub str start len

  let trim = String.trim

  let get = String.get

  let concat = String.concat
end

type hunk = {
  mine_start : int ;
  mine_len : int ;
  mine : string list ;
  their_start : int ;
  their_len : int ;
  their : string list ;
}

let unified_diff hunk =
  (* TODO *)
  String.concat "\n" (List.map (fun line -> "-" ^ line) hunk.mine @
                      List.map (fun line -> "+" ^ line) hunk.their)

let pp_hunk ppf hunk =
  Format.fprintf ppf "@@@@ -%d,%d +%d,%d @@@@\n%s"
    hunk.mine_start hunk.mine_len hunk.their_start hunk.their_len
    (unified_diff hunk)

let take data num =
  let rec take0 num data acc =
    match num, data with
    | 0, _ -> List.rev acc
    | n, x::xs -> take0 (pred n) xs (x :: acc)
    | _ -> invalid_arg "take0 broken"
  in
  take0 num data []

let drop data num =
  let rec drop data num =
    match num, data with
    | 0, _ -> data
    | n, _::xs -> drop xs (pred n)
    | _ -> invalid_arg "drop broken"
  in
  try drop data num with
  | Invalid_argument _ -> invalid_arg ("drop " ^ string_of_int num ^ " on " ^ string_of_int (List.length data))

let apply_hunk old (index, to_build) hunk =
  try
    let prefix = take (drop old index) (hunk.mine_start - index) in
    (hunk.mine_start + hunk.mine_len, to_build @ prefix @ hunk.their)
  with
  | Invalid_argument _ -> invalid_arg ("apply_hunk " ^ string_of_int index ^ " old len " ^ string_of_int (List.length old) ^
                                       " hunk start " ^ string_of_int hunk.mine_start ^ " hunk len " ^ string_of_int hunk.mine_len)

let to_start_len data =
  (* input being "?19,23" *)
  match String.cut ',' (String.slice ~start:1 data) with
  | None when data = "+1" -> (0, 1)
  | None when data = "-1" -> (0, 1)
  | None -> invalid_arg ("start_len broken in " ^ data)
  | Some (start, len) ->
     let start = int_of_string start in
     let st = if start = 0 then start else pred start in
     (st, int_of_string len)

let count_to_sl_sl data =
  if String.is_prefix ~prefix:"@@" data then
    (* input: "@@ -19,23 +19,12 @@ bla" *)
    (* output: ((19,23), (19, 12)) *)
    match List.filter (function "" -> false | _ -> true) (String.cuts '@' data) with
    | numbers::_ ->
       let nums = String.trim numbers in
       (match String.cut ' ' nums with
        | None -> invalid_arg "couldn't find space in count"
        | Some (mine, theirs) -> Some (to_start_len mine, to_start_len theirs))
    | _ -> invalid_arg "broken line!"
  else
    None

let sort_into_bags mine their str =
  match String.get str 0, String.slice ~start:1 str with
  | ' ', data -> Some ((data :: mine), (data :: their), false)
  | '+', data -> Some (mine, (data :: their), false)
  | '-', data -> Some ((data :: mine), their, false)
  | '\\', _ -> Some (mine, their, true) (* usually: "\No newline at end of file" *)
  | _ -> None

let to_hunk count data =
  match count_to_sl_sl count with
  | None -> (None, false, count :: data)
  | Some ((mine_start, mine_len), (their_start, their_len)) ->
     let rec step mine their no_nl = function
       | [] -> (List.rev mine, List.rev their, no_nl, [])
       | x::xs ->
          match sort_into_bags mine their x with
          | Some (mine, their, no_nl') -> step mine their no_nl' xs
          | None -> (List.rev mine, List.rev their, no_nl, x :: xs)
     in
     let mine, their, no_nl, rest = step [] [] false data in
     (Some { mine_start ; mine_len ; mine ; their_start ; their_len ; their }, no_nl, rest)

let rec to_hunks (no_nl, acc) = function
  | [] -> (List.rev acc, no_nl, [])
  | count::data ->
     match to_hunk count data with
     | None, no_nl, rest -> (List.rev acc, no_nl, rest)
     | Some hunk, no_nl, rest -> to_hunks (no_nl, hunk :: acc) rest

type t = {
  mine_name : string ;
  their_name : string ;
  hunks : hunk list ;
  no_nl : bool ;
}

let pp ppf t =
  Format.fprintf ppf "--- b/%s\n" t.mine_name ;
  Format.fprintf ppf "+++ a/%s\n" t.their_name ;
  List.iter (pp_hunk ppf) t.hunks

let filename name =
  let str = match String.cut ' ' name with None -> name | Some (x, _) -> x in
  if String.is_prefix ~prefix:"a/" str || String.is_prefix ~prefix:"b/" str then
    String.slice ~start:2 str
  else
    str

let to_diff data =
  (* first locate --- and +++ lines *)
  let cut4 = String.slice ~start:4 in
  let rec find_start = function
    | [] -> None
    | x::y::xs when String.is_prefix ~prefix:"---" x -> Some (cut4 x, cut4 y, xs)
    | _::xs -> find_start xs
  in
  match find_start data with
  | Some (mine_name, their_name, rest) ->
    let mine_name, their_name = filename mine_name, filename their_name in
    let hunks, no_nl, rest = to_hunks (false, []) rest in
    Some ({ mine_name ; their_name ; hunks ; no_nl }, rest)
  | None -> None

let to_lines = String.cuts '\n'

let to_diffs data =
  let lines = to_lines data in
  let rec doit acc = function
    | [] -> List.rev acc
    | xs -> match to_diff xs with
      | None -> acc
      | Some (diff, rest) -> doit (diff :: acc) rest
  in
  doit [] lines

let patch filedata diff =
  let old = match filedata with None -> [] | Some x -> to_lines x in
  let idx, lines = List.fold_left (apply_hunk old) (0, []) diff.hunks in
  let lines = lines @ drop old idx in
  let lines = if diff.no_nl then lines else lines @ [""] in
  Ok (String.concat "\n" lines)
