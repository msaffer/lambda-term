
(*
 * lt_read_line.ml
 * ---------------
 * Copyright : (c) 2011, Jeremie Dimino <jeremie@dimino.org>
 * Licence   : BSD3
 *
 * This file is a part of Lambda-Term.
 *)

open CamomileLibraryDyn.Camomile
open Lwt_react
open Lwt
open Lt_geom
open Lt_style
open Lt_text
open Lt_key

exception Interrupt
type prompt = Lt_text.t

(* +-----------------------------------------------------------------+
   | Completion                                                      |
   +-----------------------------------------------------------------+ *)

let common_prefix a b =
  let rec loop ofs =
    if ofs = String.length a || ofs = String.length b then
      String.sub a 0 ofs
    else
      let ch1, ofs1 = Zed_utf8.unsafe_extract_next a ofs
      and ch2, ofs2 = Zed_utf8.unsafe_extract_next b ofs in
      if ch1 = ch2 && ofs1 = ofs2 then
        loop ofs1
      else
        String.sub a 0 ofs
  in
  loop 0

let lookup word words =
  match List.filter (fun word' -> Zed_utf8.starts_with word' word) words with
    | [] ->
        ("", [])
    | (word :: rest) as words ->
        (List.fold_left common_prefix word rest, words)

(* +-----------------------------------------------------------------+
   | History                                                         |
   +-----------------------------------------------------------------+ *)

type history = string list

let add_entry line history =
  if Zed_utf8.strip line = "" then
    history
  else
    if (match history with [] -> false | x :: _ -> x = line) then
      history
    else
      line :: history

let newline = UChar.of_char '\n'
let backslash = UChar.of_char '\\'
let letter_n = UChar.of_char 'n'

let escape line =
  let buf = Buffer.create (String.length line) in
  Zed_utf8.iter
    (fun ch ->
       if ch = newline then
         Buffer.add_string buf "\\\n"
       else if ch =  backslash then
         Buffer.add_string buf "\\\\"
       else
         Buffer.add_string buf (Zed_utf8.singleton ch))
    line;
  Buffer.contents buf

let unescape line =
  let buf = Buffer.create (String.length line) in
  let rec loop ofs =
    if ofs = String.length line then
      Buffer.contents buf
    else begin
      let ch, ofs = Zed_utf8.unsafe_extract_next line ofs in
      if ch = backslash then begin
        if ofs = String.length line then begin
          Buffer.add_char buf '\\';
          Buffer.contents buf
        end else begin
          let ch, ofs = Zed_utf8.unsafe_extract_next line ofs in
          if ch = backslash then
            Buffer.add_char buf '\\'
          else if ch = letter_n then
            Buffer.add_char buf '\n'
          else begin
            Buffer.add_char buf '\\';
            Buffer.add_string buf (Zed_utf8.singleton ch)
          end;
          loop ofs
        end
      end else begin
        Buffer.add_string buf (Zed_utf8.singleton ch);
        loop ofs
      end
    end
  in
  loop 0

let rec load_lines ic acc =
  Lwt_io.read_line_opt ic >>= function
    | Some l ->
        ignore (Zed_utf8.validate l);
        load_lines ic (unescape l :: acc)
    | None ->
        return acc

let load_history name =
  if Sys.file_exists name then
    Lwt_io.with_file ~mode:Lwt_io.input name (fun ic -> load_lines ic [])
  else
    return []

let rec merge h1 h2 =
  match h1, h2 with
    | l1 :: h1, l2 :: h2 when l1 = l2 ->
        l1 :: merge h1 h2
    | _ ->
        h1 @ h2

let save_history name history =
  lwt on_disk_history = load_history name in
  Lwt_io.lines_to_file name (Lwt_stream.map escape (Lwt_stream.of_list (merge (List.rev on_disk_history) (List.rev history))))

(* +-----------------------------------------------------------------+
   | Actions                                                         |
   +-----------------------------------------------------------------+ *)

type action =
  | Edit of Zed_edit.action
  | Interrupt_or_delete_next_char
  | Complete
  | Complete_bar_next
  | Complete_bar_prev
  | Complete_bar_first
  | Complete_bar_last
  | Complete_bar
  | History_prev
  | History_next
  | Accept
  | Clear_screen
  | Prev_search
  | Cancel_search

let bindings = Hashtbl.create 128

let () =
  let ( --> ) key action = Hashtbl.add bindings key action in
  { control = false; meta = false; shift = false; code = Up } --> History_prev;
  { control = false; meta = false; shift = false; code = Down } --> History_next;
  { control = false; meta = false; shift = false; code = Tab } --> Complete;
  { control = false; meta = false; shift = false; code = Enter } --> Accept;
  { control = true; meta = false; shift = false; code = Char(UChar.of_char 'm') } --> Accept;
  { control = true; meta = false; shift = false; code = Char(UChar.of_char 'l') } --> Clear_screen;
  { control = true; meta = false; shift = false; code = Char(UChar.of_char 'r') } --> Prev_search;
  { control = true; meta = false; shift = false; code = Char(UChar.of_char 'd') } --> Interrupt_or_delete_next_char;
  { control = false; meta = true; shift = false; code = Left } --> Complete_bar_prev;
  { control = false; meta = true; shift = false; code = Right } --> Complete_bar_next;
  { control = false; meta = true; shift = false; code = Home } --> Complete_bar_first;
  { control = false; meta = true; shift = false; code = End } --> Complete_bar_last;
  { control = false; meta = true; shift = false; code = Tab } --> Complete_bar;
  { control = false; meta = true; shift = false; code = Enter } --> Edit Zed_edit.Newline;
  { control = false; meta = false; shift = false; code = Escape } --> Cancel_search

let bind key =
  try
    Some(Hashtbl.find bindings key)
  with Not_found ->
    try
      Some(Edit(Hashtbl.find Lt_edit.bindings key))
    with Not_found ->
      None

(* +-----------------------------------------------------------------+
   | The read-line engine                                            |
   +-----------------------------------------------------------------+ *)

let search_string str sub =
  let rec equal_at a b =
    (b = String.length sub) || (String.unsafe_get str a = String.unsafe_get sub b) && equal_at (a + 1) (b + 1)
  in
  let rec loop ofs idx =
    if ofs + String.length sub > String.length str then
      None
    else
      if equal_at ofs 0 then
        Some idx
      else
        loop (Zed_utf8.unsafe_next str ofs) (idx + 1)
  in
  loop 0 0

class virtual ['a] engine ?(history=[]) () =
  let edit : unit Zed_edit.t = Zed_edit.create () in
  let context = Zed_edit.context edit (Zed_edit.new_cursor edit) in
  let completion_words, set_completion_words = S.create ([] : (Zed_utf8.t * Zed_utf8.t) list) in
  let completion_index, set_completion_index = S.create 0 in
  let search_mode, set_search_mode = S.create false in
  let history, set_history = S.create (history, []) in
  let message, set_message = S.create None in
object(self)
  method virtual eval : 'a
  method edit = edit
  method context = context
  method show_box = true
  method search_mode = search_mode
  method history = history
  method message = message

  (* The thread that compute completion. *)
  val mutable completion_thread = return ()

  (* The event that compute completion when needed. *)
  val mutable completion_event = E.never

  (* Whether a completion has been queued. *)
  val mutable completion_queued = false

  (* The index of the start of the word being completed. *)
  val mutable completion_start = 0

  initializer
    completion_event <- (
      E.map
        (fun () ->
           (* Cancel previous thread because it is now useless. *)
           cancel completion_thread;
           set_completion_index 0;
           set_completion_words [];
           if completion_queued then
             return ()
           else begin
             completion_queued <- true;
             lwt () = pause () in
             completion_queued <- false;
             completion_thread <- (
               lwt start, comp = self#completion in
               completion_start <- start;
               set_completion_words comp;
               return ()
             );
             return ()
           end)
        (E.when_
           (S.map not search_mode)
           (E.select [
              E.stamp (Zed_edit.changes edit) ();
              E.stamp (S.changes (Zed_cursor.position (Zed_edit.cursor context))) ();
            ]))
    );
    completion_thread <- (
      lwt start, comp = self#completion in
      completion_start <- start;
      set_completion_words comp;
      return ()
    )

  method input_prev =
    Zed_rope.before (Zed_edit.text edit) (Zed_edit.position context)

  method input_next =
    Zed_rope.after (Zed_edit.text edit) (Zed_edit.position context)

  method completion_words = completion_words
  method completion_index = completion_index
  method completion = return (0, [])

  method complete =
    let prefix_length = Zed_edit.position context - completion_start in
    match S.value completion_words with
      | [] ->
          ()
      | [(completion, suffix)] ->
          Zed_edit.insert context (Zed_rope.of_string (Zed_utf8.after completion prefix_length));
          Zed_edit.insert context (Zed_rope.of_string suffix)
      | (completion, suffix) :: rest ->
          let word = List.fold_left (fun acc (word, _) -> common_prefix acc word) completion rest in
          Zed_edit.insert context (Zed_rope.of_string (Zed_utf8.after word prefix_length))

  (* The event which search for the string in the history. *)
  val mutable search_event = E.never

  (* The result of the search. If the search was successful it
     contains the matched history entry, the position of the substring
     in this entry and the rest of the history. *)
  val mutable search_result = None

  initializer
    search_event <- E.map (fun _ -> search_result <- None; self#search) (E.when_ search_mode (Zed_edit.changes edit))

  method private search =
    let input = Zed_rope.to_string (Zed_edit.text edit) in
    let rec loop = function
      | [] ->
          search_result <- None;
          set_message (Some(Lt_text.of_string "Reverse search: not found"))
      | entry :: rest ->
          match search_string entry input with
            | Some pos -> begin
                match search_result with
                  | Some(entry', _, _) when entry = entry' ->
                      loop rest
                  | _ ->
                      search_result <- Some(entry, pos, rest);
                      let txt = Lt_text.of_string entry in
                      for i = pos to pos + Zed_rope.length (Zed_edit.text edit) - 1 do
                        let ch, style = txt.(i) in
                        txt.(i) <- (ch, { style with underline = Some true })
                      done;
                      set_message (Some(Array.append (Lt_text.of_string "Reverse search: ") txt))
              end
            | None ->
                loop rest
    in
    match search_result with
      | Some(entry, pos, rest) -> loop rest
      | None -> loop (fst (S.value history))

  method insert ch =
    Zed_edit.insert context (Zed_rope.singleton ch)

  method send_action action =
    match action with
      | (Complete | Complete_bar) when S.value search_mode -> begin
          set_search_mode false;
          set_message None;
          match search_result with
            | Some(entry, pos, rest) ->
                search_result <- None;
                Zed_edit.goto context 0;
                Zed_edit.remove context (Zed_rope.length (Zed_edit.text edit));
                Zed_edit.insert context (Zed_rope.of_string entry)
            | None ->
                ()
        end

      | Edit action ->
          Zed_edit.get_action action context

      | Interrupt_or_delete_next_char ->
          if Zed_rope.is_empty (Zed_edit.text edit) then
            raise Interrupt
          else
            Zed_edit.delete_next_char context

      | Complete when not (S.value search_mode) ->
          self#complete

      | Complete_bar_next when not (S.value search_mode) ->
          let index = S.value completion_index in
          if index < List.length (S.value completion_words) - 1 then
            set_completion_index (index + 1)

      | Complete_bar_prev when not (S.value search_mode) ->
          let index = S.value completion_index in
          if index > 0 then
            set_completion_index (index - 1)

      | Complete_bar_first when not (S.value search_mode) ->
          set_completion_index 0

      | Complete_bar_last when not (S.value search_mode) ->
          let len = List.length (S.value completion_words) in
          if len > 0 then
            set_completion_index (len - 1)

      | Complete_bar when not (S.value search_mode) ->
          let words = S.value completion_words in
          if words <> [] then begin
            let prefix_length = Zed_edit.position context - completion_start in
            let completion, suffix = List.nth words (S.value completion_index) in
            Zed_edit.insert context (Zed_rope.of_string (Zed_utf8.after completion prefix_length));
            Zed_edit.insert context (Zed_rope.of_string suffix)
          end

      | History_prev when not (S.value search_mode) ->begin
          let prev, next = S.value history in
          match prev with
            | [] ->
                ()
            | line :: rest ->
                let text = Zed_edit.text edit in
                set_history (rest, Zed_rope.to_string text :: next);
                Zed_edit.goto context 0;
                Zed_edit.remove context (Zed_rope.length text);
                Zed_edit.insert context (Zed_rope.of_string line)
        end

      | History_next when not (S.value search_mode) -> begin
          let prev, next = S.value history in
          match next with
            | [] ->
                ()
            | line :: rest ->
                let text = Zed_edit.text edit in
                set_history (Zed_rope.to_string text :: prev, rest);
                Zed_edit.goto context 0;
                Zed_edit.remove context (Zed_rope.length text);
                Zed_edit.insert context (Zed_rope.of_string line)
        end

      | Prev_search ->
          if S.value search_mode then
            self#search
          else begin
            let text = Zed_edit.text edit in
            Zed_edit.goto context 0;
            Zed_edit.remove context (Zed_rope.length text);
            let prev, next = S.value history in
            set_history (Zed_rope.to_string text :: (List.rev_append next prev), []);
            search_result <- None;
            set_search_mode true;
            self#search
          end

      | Cancel_search ->
          if S.value search_mode then begin
            set_search_mode false;
            set_message None
          end

      | _ ->
          ()

  method stylise =
    let txt = Lt_text.of_rope (Zed_edit.text edit) in
    let pos = Zed_edit.position context in
    if Zed_edit.get_selection edit then begin
      let mark = Zed_cursor.get_position (Zed_edit.mark edit) in
      let a = min pos mark and b = max pos mark in
      for i = a to b - 1 do
        let ch, style = txt.(i) in
        txt.(i) <- (ch, { style with underline = Some true })
      done;
    end;
    (txt, pos)
end

class virtual ['a] abstract = object
  method virtual eval : 'a
  method virtual send_action : action -> unit
  method virtual insert : UChar.t -> unit
  method virtual edit : unit Zed_edit.t
  method virtual context : unit Zed_edit.context
  method virtual stylise : Lt_text.t * int
  method virtual history : (Zed_utf8.t list * Zed_utf8.t list) signal
  method virtual message : Lt_text.t option signal
  method virtual input_prev : Zed_rope.t
  method virtual input_next : Zed_rope.t
  method virtual completion_words : (Zed_utf8.t * Zed_utf8.t) list signal
  method virtual completion_index : int signal
  method virtual completion : (int * (Zed_utf8.t * Zed_utf8.t) list) Lwt.t
  method virtual complete : unit
  method virtual show_box : bool
  method virtual search_mode : bool signal
end

(* +-----------------------------------------------------------------+
   | Predefined classes                                              |
   +-----------------------------------------------------------------+ *)

class read_line ?history () = object(self)
  inherit [Zed_utf8.t] engine ?history ()
  method eval = Zed_rope.to_string (Zed_edit.text self#edit)
end

class read_password () = object(self)
  inherit [Zed_utf8.t] engine () as super

  method stylise =
    let text, pos = super#stylise in
    for i = 0 to Array.length text - 1 do
      let ch, style = text.(i) in
      text.(i) <- (UChar.of_char '*', style)
    done;
    (text, pos)

  method eval = Zed_rope.to_string (Zed_edit.text self#edit)

  method show_box = false

  method send_action = function
    | Prev_search -> ()
    | action -> super#send_action action
end

type 'a read_keyword_result =
  | Rk_value of 'a
  | Rk_error of Zed_utf8.t

class ['a] read_keyword ?history () = object(self)
  inherit ['a read_keyword_result] engine ?history ()

  method keywords = []

  method eval =
    let input = Zed_rope.to_string (Zed_edit.text self#edit) in
    try Rk_value(List.assoc input self#keywords) with Not_found -> Rk_error input

  method completion =
    let word = Zed_rope.to_string self#input_prev in
    let keywords = List.filter (fun (keyword, value) -> Zed_utf8.starts_with keyword word) self#keywords in
    return (0, List.map (fun (keyword, value) -> (keyword, "")) keywords)
end

(* +-----------------------------------------------------------------+
   | Running in a terminal                                           |
   +-----------------------------------------------------------------+ *)

let hline = (UChar.of_int 0x2500, Lt_style.none)
let default_prompt = Lt_text.of_string "# "

let rec drop count l =
  if count <= 0 then
    l
  else match l with
    | [] -> []
    | e :: l -> drop (count - 1) l

(* Computes the position of the cursor after printing the given styled
   string, assuming the terminal is a windows one. *)
let compute_position_windows size pos text =
  Array.fold_left
    (fun pos (ch, style) ->
       if ch = newline then
         { line = pos.line + 1; column = 0 }
       else if pos.column + 1 = size.columns then
         { line = pos.line + 1; column = 0 }
       else
         { pos with column = pos.column + 1 })
    pos text

(* Same thing but for Unix. On Unix the cursor can be at the end of
   the line. *)
let compute_position_unix size pos text =
  Array.fold_left
    (fun pos (ch, style) ->
       if ch = newline then
         { line = pos.line + 1; column = 0 }
       else if pos.column = size.columns then
         { line = pos.line + 1; column = 1 }
       else
         { pos with column = pos.column + 1 })
    pos text

let make_completion_bar_middle index columns words =
  let rec aux ofs idx = function
    | [] ->
        [S(String.make (columns - ofs) ' ')]
    | (word, suffix) :: words ->
        let len = Zed_utf8.length word in
        let ofs' = ofs + len in
        if ofs' <= columns then
          if idx = index then
            B_reverse true :: S word :: E_reverse ::
              if ofs' + 1 > columns then
                []
              else
                S"│" :: aux (ofs' + 1) (idx + 1) words
          else
            S word ::
              if ofs' + 1 > columns then
                []
              else
                S"│" :: aux (ofs' + 1) (idx + 1) words
        else
          [S(Zed_utf8.sub word 0 (columns - ofs))]
  in
  eval (aux 0 0 words)

let make_bar delimiter columns words =
  let buf = Buffer.create (columns * 3) in
  let rec aux ofs = function
    | [] ->
        for i = ofs + 1 to columns do
          Buffer.add_string buf "─"
        done;
        Buffer.contents buf
    | (word, suffix) :: words ->
        let len = Zed_utf8.length word in
        let ofs' = ofs + len in
        if ofs' <= columns then begin
          for i = 1 to len do
            Buffer.add_string buf "─"
          done;
          if ofs' + 1 > columns then
            Buffer.contents buf
          else begin
            Buffer.add_string buf delimiter;
            aux (ofs' + 1) words
          end
        end else begin
          for i = ofs + 1 to columns do
            Buffer.add_string buf "─"
          done;
          Buffer.contents buf
        end
  in
  aux 0 words

let rec get_index_of_last_displayed_word column columns index words =
  match words with
    | [] ->
        index - 1
    | (word, suffix) :: words ->
        let column = column + Zed_utf8.length word in
        if column <= columns - 1 then
          get_index_of_last_displayed_word (column + 1) columns (index + 1) words
        else
          index - 1

let text_height columns text =
  let { line } =
    Array.fold_left
      (fun pos (ch, style) ->
         if ch = newline then
           { line = pos.line + 1; column = 0 }
         else if pos.column + 1 = columns then
           { line = pos.line + 1; column = 0 }
         else
           { pos with column = pos.column + 1 })
      { line = 0; column = 1 } text
  in
  line + 1

class virtual ['a] term term =
  let size, set_size = S.create { columns = 80; lines = 25 } in
  let event, set_prompt = E.create () in
  let prompt = S.switch (S.const default_prompt) event in
object(self)
  inherit ['a] abstract
  method size = size
  method prompt = prompt
  method set_prompt = set_prompt

  val mutable visible = true
    (* Whether the read-line instance is currently visible. *)

  val mutable displayed = false
    (* Whether the read-line instance is currently displayed on the
       screen. *)

  val mutable draw_queued = false
    (* Whether a draw operation has been queued, in which case it is
       not necessary to redraw. *)

  val mutable cursor = { line = 0; column = 0 }
    (* The position of the cursor. *)

  val mutable end_of_display = { line = 0; column = 0 }
    (* The position of the end of displayed material. *)

  val mutable completion_start = S.const 0
    (* Index of the first displayed word in the completion bar. *)

  initializer
    completion_start <- (
      S.fold
        (fun start (words, index, columns) ->
           if index < start then
             (* The cursor is before the left margin. *)
             let count = List.length words in
             let rev_index = count - index - 1 in
             count - get_index_of_last_displayed_word 1 columns rev_index (drop rev_index (List.rev words)) - 1
           else if index > get_index_of_last_displayed_word 1 columns start (drop start words) then
             (* The cursor is after the right margin. *)
             index
           else
             start)
        0
        (S.changes
           (S.l3
              (fun words index size -> (words, index, size.columns))
              self#completion_words
              self#completion_index
              size))
    )

  method completion_start = completion_start

  val draw_mutex = Lwt_mutex.create ()

  method private erase =
    (* Move back to the beginning of printed material. *)
    lwt () = Lt_term.move term (-cursor.line) (-cursor.column) in
    (* Erase everything, line by line. *)
    let rec erase count =
      if count = 0 then
        Lt_term.clear_line term
      else
        lwt () = Lt_term.clear_line term in
        lwt () = Lt_term.move term 1 0 in
        erase (count - 1)
    in
    lwt () = erase end_of_display.line in
    (* Move back again to the beginning. *)
    Lt_term.move term (-end_of_display.line) 0

  method draw_update =
    if draw_queued then
      return ()
    else
      lwt () = Lwt_mutex.lock draw_mutex in
      try_lwt
        (* Wait a bit in order not to draw too often. *)
        draw_queued <- true;
        lwt () = pause () in
        draw_queued <- false;

        if visible then begin
          lwt () =
            if displayed then
              self#erase
            else begin
              displayed <- true;
              return ()
            end
          in
          let { columns } = S.value size in
          let start = S.value self#completion_start in
          let index = S.value self#completion_index in
          let words = drop start (S.value self#completion_words) in
          let styled, position = self#stylise in
          let before = Array.sub styled 0 position in
          let after = Array.sub styled position (Array.length styled - position) in
          let before = Array.append (S.value prompt) before in
          let box =
            if self#show_box && columns > 2 then
              match S.value self#message with
                | Some msg ->
                    let height = text_height (columns - 2) msg in
                    let box = Array.make ((columns + 1) * (height + 2)) (UChar.of_char ' ', Lt_style.none) in

                    (* Draw the top of the box. *)
                    box.(0) <- (UChar.of_char '\n', Lt_style.none);
                    box.(1) <- (UChar.of_int 0x250c, Lt_style.none);
                    for i = 0 to columns - 3 do
                      box.(2 + i) <- hline
                    done;
                    box.(columns) <- (UChar.of_int 0x2510, Lt_style.none);

                    (* Draw the left and right vertical lines. *)
                    for i = 1 to height do
                      let start = (columns + 1) * i in
                      box.(start) <- (UChar.of_char '\n', Lt_style.none);
                      box.(start + 1) <- (UChar.of_int 0x2502, Lt_style.none);
                      box.(start + columns) <- (UChar.of_int 0x2502, Lt_style.none);
                    done;

                    (* Draw the bottom of the box. *)
                    let start = (columns + 1) * (height + 1) in
                    box.(start) <- (UChar.of_char '\n', Lt_style.none);
                    box.(start + 1) <- (UChar.of_int 0x2514, Lt_style.none);
                    for i = 0 to columns - 3 do
                      box.(start + 2 + i) <- hline
                    done;
                    box.(start + columns) <- (UChar.of_int 0x2518, Lt_style.none);

                    (* Draw the message. *)
                    let rec loop line column idx =
                      if idx < Array.length msg then begin
                        let (ch, _) as point = msg.(idx) in
                        if ch = newline then
                          loop (line + 1) 0 (idx + 1)
                        else begin
                          box.((line + 1) * (columns + 1) + column + 2) <- point;
                          if column = columns - 3 then
                            loop (line + 1) 0 (idx + 1)
                          else
                            loop line (column + 1) (idx + 1)
                        end
                      end
                    in
                    loop 0 0 0;

                    box
                | None ->
                    Array.concat [
                      Lt_text.of_string "\n┌";
                      Lt_text.of_string (make_bar "┬" (columns - 2) words);
                      Lt_text.of_string "┐\n│";
                      make_completion_bar_middle (index - start) (columns - 2) words;
                      Lt_text.of_string "│\n└";
                      Lt_text.of_string (make_bar "┴" (columns - 2) words);
                      Lt_text.of_string "┘";
                    ]
            else
              [||]
          in
          let size = S.value size in
          if Lt_term.windows term then begin
            let after = Array.append after box in
            cursor <- compute_position_windows size { column = 0; line = 0 } before;
            end_of_display <- compute_position_windows size cursor after;
            lwt () = Lt_term.fprints term (Array.append before after) in
            lwt () = Lt_term.move term (cursor.line - end_of_display.line) (cursor.column - end_of_display.column) in
            Lt_term.flush term
          end else begin
            cursor <- compute_position_unix size { column = 0; line = 0 } before;
            end_of_display <- compute_position_unix size cursor (Array.append after box);
            let after =
              if cursor.column = size.columns && after = [||] then begin
                (* If the cursor is at the end of line and there is
                   nothing after, insert a newline character. *)
                let after = Array.concat [after; Lt_text.of_string "\n"; box] in
                cursor <- compute_position_unix size { column = 0; line = 0 } before;
                end_of_display <- compute_position_unix size cursor after;
                after
              end else
                Array.append after box
            in
            (* If the cursor is at the end of line, move it to the
               beginning of the next line. *)
            if cursor.column = size.columns then
              cursor <- { column = 0; line = cursor.line + 1 };
            (* Fix the position of the end of display. *)
            if end_of_display.column = size.columns then
              end_of_display <- { end_of_display with column = size.columns - 1 };
            lwt () = Lt_term.fprints term (Array.append before after) in
            lwt () = Lt_term.move term (cursor.line - end_of_display.line) (cursor.column - end_of_display.column) in
            Lt_term.flush term
          end
        end else
          return ()
      finally
        Lwt_mutex.unlock draw_mutex;
        return ()

  method draw_success =
    lwt () = Lwt_mutex.lock draw_mutex in
    try_lwt
      lwt () = if visible then self#erase else return () in
      Lt_term.fprintls term (Array.append (S.value prompt) (fst self#stylise))
    finally
      Lwt_mutex.unlock draw_mutex;
      return ()

  method draw_failure =
    self#draw_success

  method hide =
    if visible then begin
      visible <- false;
      Lwt_mutex.with_lock draw_mutex (fun () -> self#erase)
    end else
      return ()

  method show =
    if not visible then begin
      visible <- true;
      displayed <- false;
      self#draw_update
    end else
      return ()

  method run =
    (* Get the initial size of the terminal. *)
    lwt initial_size = Lt_term.get_size term in
    set_size initial_size;

    let running = ref true in

    (* Redraw everything when needed. *)
    let event =
      E.map_p
        (fun () -> if !running then self#draw_update else return ())
        (E.select [
           E.stamp (S.changes size) ();
           E.stamp (Zed_edit.changes self#edit) ();
           E.stamp (S.changes (Zed_cursor.position (Zed_edit.cursor self#context))) ();
           E.stamp (S.changes prompt) ();
           E.stamp (S.changes self#completion_words) ();
           E.stamp (S.changes self#completion_index) ();
           E.stamp (S.changes self#completion_start) ();
           E.stamp (S.changes self#message) ();
         ])
    in

    (* The main loop. *)
    let rec loop () =
      Lt_term.read_event term >>= function
        | Lt_event.Resize size ->
            set_size size;
            loop ()
        | Lt_event.Key key -> begin
            match bind key with
              | Some Accept ->
                  return self#eval
              | Some Clear_screen ->
                  lwt () = Lt_term.clear_screen term in
                  lwt () = Lt_term.goto term { line = 0; column = 0 } in
                  displayed <- false;
                  lwt () = self#draw_update in
                  loop ()
              | Some action ->
                  self#send_action action;
                  loop ()
              | None ->
                  match key with
                    | { control = false; meta = false; shift = false; code = Char ch } ->
                        self#insert ch;
                        loop ()
                    | _ ->
                        loop ()
          end
        | _ ->
            loop ()
    in

    lwt mode =
      match Lt_term.is_a_tty term with
        | true ->
            lwt mode = Lt_term.enter_raw_mode term in
            return (Some mode)
        | false ->
            return None
    in

    lwt result =
      try_lwt
        (* Go to the beginning of line otherwise all offset
           calculation will be false. *)
        lwt () = Lt_term.fprint term "\r" in
        lwt () = self#draw_update in
        loop ()
      with exn ->
        running := false;
        E.stop event;
        lwt () = self#draw_failure in
        raise_lwt exn
      finally
        match mode with
          | Some mode ->
              Lt_term.leave_raw_mode term mode
          | None ->
              return ()
    in
    running := false;
    E.stop event;
    lwt () = self#draw_success in
    return result
end
