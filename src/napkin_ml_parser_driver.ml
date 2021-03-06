module OcamlParser = Parser

module IO: sig
  val readFile: string -> string
  val readStdin: unit -> string
end = struct
  (* random chunk size: 2^15, TODO: why do we guess randomly? *)
  let chunkSize = 32768

  let readFile filename =
    let chan = open_in filename in
    let buffer = Buffer.create chunkSize in
    let chunk = (Bytes.create [@doesNotRaise]) chunkSize in
    let rec loop () =
      let len = try input chan chunk 0 chunkSize with Invalid_argument _ -> 0 in
      if len == 0 then (
        close_in_noerr chan;
        Buffer.contents buffer
      ) else (
        Buffer.add_subbytes buffer chunk 0 len;
        loop ()
      )
    in
    loop ()

  let readStdin () =
    let buffer = Buffer.create chunkSize in
    let chunk = (Bytes.create [@doesNotRaise]) chunkSize in
    let rec loop () =
      let len = try input stdin chunk 0 chunkSize with Invalid_argument _ -> 0 in
      if len == 0 then (
        close_in_noerr stdin;
        Buffer.contents buffer
      ) else (
        Buffer.add_subbytes buffer chunk 0 len;
        loop ()
      )
    in
    loop ()
end

let setup ~filename =
  if String.length filename > 0 then (
    Location.input_name := filename;
    IO.readFile filename |> Lexing.from_string
  ) else
    Lexing.from_channel stdin

let extractOcamlConcreteSyntax filename =
  let lexbuf = if String.length filename > 0 then
    IO.readFile filename |> Lexing.from_string
  else
    Lexing.from_channel stdin
  in
  let stringLocs = ref [] in
  let commentData = ref [] in
  let rec next (prevTokEndPos : Lexing.position) () =
    let token = Lexer.token_with_comments lexbuf in
    match token with
    | OcamlParser.COMMENT (txt, loc) ->
      let comment = Napkin_comment.fromOcamlComment
        ~loc
        ~prevTokEndPos
        ~txt
      in
      commentData := comment::(!commentData);
      next loc.Location.loc_end ()
    | OcamlParser.STRING (_txt, None) ->
      let open Location in
      let loc = {
        loc_start = lexbuf.lex_start_p;
        loc_end = lexbuf.Lexing.lex_curr_p;
        loc_ghost = false;
      } in
      let len = loc.loc_end.pos_cnum - loc.loc_start.pos_cnum in
      let txt = Bytes.to_string (
        (Bytes.sub [@doesNotRaise]) lexbuf.Lexing.lex_buffer loc.loc_start.pos_cnum len
      ) in
      stringLocs := (txt, loc)::(!stringLocs);
      next lexbuf.Lexing.lex_curr_p ()
    | OcamlParser.EOF -> ()
    | _ -> next lexbuf.Lexing.lex_curr_p ()
  in
  next lexbuf.Lexing.lex_start_p ();
  (List.rev !stringLocs, List.rev !commentData)

let parsingEngine = {
  Napkin_driver.parseImplementation = begin fun ~forPrinter:_ ~filename ->
    let lexbuf = setup ~filename in
    let (stringData, comments) = extractOcamlConcreteSyntax !Location.input_name in
    let structure =
      Parse.implementation lexbuf
      |> Napkin_ast_conversion.replaceStringLiteralStructure stringData
      |> Napkin_ast_conversion.structure
    in {
      filename = !Location.input_name;
      source = Bytes.to_string lexbuf.lex_buffer;
      parsetree = structure;
      diagnostics = ();
      invalid = false;
      comments = comments;
    }
  end;
  parseInterface = begin fun  ~forPrinter:_ ~filename ->
    let lexbuf = setup ~filename in
    let (stringData, comments) = extractOcamlConcreteSyntax !Location.input_name in
    let signature =
      Parse.interface lexbuf
      |> Napkin_ast_conversion.replaceStringLiteralSignature stringData
      |> Napkin_ast_conversion.signature
    in {
      filename = !Location.input_name;
      source = Bytes.to_string lexbuf.lex_buffer;
      parsetree = signature;
      diagnostics = ();
      invalid = false;
      comments = comments;
    }
  end;
  stringOfDiagnostics = begin fun ~source:_ ~filename:_ _diagnostics -> "" end;
}

let printEngine = Napkin_driver.{
  printImplementation = begin fun ~width:_ ~filename:_ ~comments:_ structure ->
    Pprintast.structure Format.std_formatter structure
  end;
  printInterface = begin fun ~width:_ ~filename:_ ~comments:_ signature ->
    Pprintast.signature Format.std_formatter signature
  end;
}
