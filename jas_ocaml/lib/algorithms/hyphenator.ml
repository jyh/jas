(** Knuth-Liang hyphenation algorithm.

    Pure-OCaml implementation of the Knuth-Liang word hyphenation
    algorithm as used in TeX. Given a word and a TeX-style pattern
    list (e.g. [2'2], [1ad], [2bc1d]), returns the set of valid
    break points (1-based char indices, where break_at.(i) means
    a break is allowed between chars i-1 and i).

    The pattern format follows TeX hyphenation patterns: each
    pattern is a string of letters interleaved with digits. A [.]
    at the start means word start; a [.] at the end means word
    end. Digits between letters are priorities; the highest
    priority at each inter-character position wins. Odd priorities
    mark break points; even priorities suppress them.

    Phase 9: ships with a small en-US pattern subset for testing.
    Full TeX dictionary is a follow-up packaging task. The
    algorithm itself works with any pattern list a caller loads. *)

(** Split a TeX hyphenation pattern into its letter sequence and
    the per-position digit list. [2'2] -> letters="\047", digits=[2;2]
    (the apostrophe between two digits 2). The digit array has
    length [String.length letters + 1]; positions with no digit in
    the pattern get 0. *)
let split_pattern (pat : string) : string * int array =
  let letters = Buffer.create (String.length pat) in
  let digits = ref [] in
  let pending = ref 0 in
  String.iter (fun c ->
    let code = Char.code c in
    if code >= 0x30 && code <= 0x39 then
      pending := code - 0x30
    else begin
      digits := !pending :: !digits;
      pending := 0;
      Buffer.add_char letters c
    end
  ) pat;
  digits := !pending :: !digits;
  (Buffer.contents letters, Array.of_list (List.rev !digits))

(** Lowercase an ASCII string. Non-ASCII bytes pass through
    unchanged, matching the Rust [str::to_lowercase] used for the
    en-US pattern set. *)
let _ascii_lower s =
  let b = Bytes.of_string s in
  for i = 0 to Bytes.length b - 1 do
    let c = Bytes.get b i in
    let code = Char.code c in
    if code >= 0x41 && code <= 0x5a then
      Bytes.set b i (Char.chr (code + 32))
  done;
  Bytes.to_string b

(** Compute valid break positions in [word] per the given patterns.
    Returns a [bool array] of length [String.length word + 1],
    where [breaks.(i) = true] means a break is permitted between
    chars i-1 and i. Indices 0 and [String.length word] are always
    false (no break before first or after last char). Patterns are
    case-folded; the input word is lowercased for matching.

    [min_before] and [min_after] enforce the dialog After First N
    letters and Before Last N letters constraints; break points
    within the first [min_before] or last [min_after] characters
    are suppressed. *)
let hyphenate (word : string) (patterns : string list)
    ~(min_before : int) ~(min_after : int) : bool array =
  let n = String.length word in
  if n = 0 then [||] else begin
    let levels = Array.make (n + 1) 0 in
    let lower = _ascii_lower word in
    let padded = "." ^ lower ^ "." in
    let plen = String.length padded in
    List.iter (fun pat ->
      let (letters, digits) = split_pattern pat in
      let pn = String.length letters in
      if pn > 0 && pn <= plen then begin
        for start = 0 to plen - pn do
          let matches = ref true in
          let j = ref 0 in
          while !matches && !j < pn do
            if padded.[start + !j] <> letters.[!j] then matches := false;
            incr j
          done;
          if !matches then begin
            for i = 0 to Array.length digits - 1 do
              let lvl = digits.(i) in
              if lvl <> 0 then begin
                let padded_pos = start + i in
                if padded_pos > 0 && padded_pos <= n then begin
                  let unpadded_pos = padded_pos - 1 in
                  if unpadded_pos <= n && levels.(unpadded_pos) < lvl then
                    levels.(unpadded_pos) <- lvl
                end
              end
            done
          end
        done
      end
    ) patterns;
    let breaks = Array.make (n + 1) false in
    let upper = max 0 (n - min_after) in
    for i = 0 to n do
      if i >= min_before && i <= upper && levels.(i) mod 2 = 1 then
        breaks.(i) <- true
    done;
    breaks
  end

(** A small en-US pattern set sufficient for unit tests and a rough
    demonstration. Sourced from a tiny subset of the TeX hyphen.tex
    patterns. A full dictionary (around 4500 patterns) landing as a
    packaged resource is tracked separately; production callers
    should load the full set instead of this. *)
let en_us_patterns_sample : string list = [
  "1ti"; "2tion"; "1men"; "2ment"; "1ness"; "2ness";
  "3able"; "1able";
  ".un1"; ".re1"; ".dis1"; ".pre1"; ".pro1";
  "2bl"; "2br"; "2cl"; "2cr"; "2dr"; "2fl"; "2fr"; "2gl";
  "2gr"; "2pl"; "2pr"; "2sc"; "2sl"; "2sm"; "2sn"; "2sp";
  "2st"; "2sw"; "2tr"; "2tw"; "2wr";
  "1ba"; "1be"; "1bi"; "1bo"; "1bu";
  "1ca"; "1ce"; "1ci"; "1co"; "1cu";
  "1da"; "1de"; "1di"; "1do"; "1du";
  "1fa"; "1fe"; "1fi"; "1fo"; "1fu";
  "1ga"; "1ge"; "1gi"; "1go"; "1gu";
  "1ha"; "1he"; "1hi"; "1ho"; "1hu";
  "1la"; "1le"; "1li"; "1lo"; "1lu";
  "1ma"; "1me"; "1mi"; "1mo"; "1mu";
  "1na"; "1ne"; "1ni"; "1no"; "1nu";
  "1pa"; "1pe"; "1pi"; "1po"; "1pu";
  "1ra"; "1re"; "1ri"; "1ro"; "1ru";
  "1sa"; "1se"; "1si"; "1so"; "1su";
  "1ta"; "1te"; "1ti"; "1to"; "1tu";
  "1va"; "1ve"; "1vi"; "1vo"; "1vu";
]
