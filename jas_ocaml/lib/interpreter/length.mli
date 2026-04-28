(** Unit-aware length parser / formatter for the [length_input] widget.

    Companion module to {!Yaml_panel_view.render_length_input}. Mirrors:
    - [workspace_interpreter/length.py] (Flask, Python apps)
    - [jas_dioxus/src/interpreter/length.rs]
    - [JasSwift/Sources/Interpreter/Length.swift]
    - [jas_flask/static/js/app.js] [parseLength] / [formatLength]

    Keep all five implementations in lockstep on the conversion table
    and rounding rules. The parity tests under
    [test/interpreter/length_test.ml] pin the same edge cases the
    Python and Rust suites do.

    Canonical storage unit: [pt]. Every value committed to the state
    store, every length attribute written to SVG, is a pt-valued
    [float].

    Supported units: [pt], [px], [in], [mm], [cm], [pc]. Unit suffixes
    parse case-insensitively; bare numbers are interpreted in the
    widget's declared default unit. *)

(** Names of units accepted by {!parse} and produced by {!format}. *)
val supported_units : string list

(** Return the pt-equivalent of one of the named units, or [None] when
    the name is not in {!supported_units} (case-insensitive
    comparison). *)
val pt_per_unit : string -> float option

(** [parse s ~default_unit] parses a user-typed length string into a
    value in points.

    Bare numbers are interpreted in [default_unit]. A unit suffix
    (case-insensitive) overrides the default. Whitespace is tolerated
    around / between the number and the unit. Returns [None] for
    empty / whitespace-only input, syntactically malformed input, or
    inputs carrying an unsupported unit. Per [UNIT_INPUTS.md] §Edge
    cases — callers decide whether [None] means "commit null on a
    nullable field" or "revert to prior value". *)
val parse : string -> default_unit:string -> float option

(** [format pt ~unit ~precision] renders a pt value as a display
    string in the named unit.

    [None] formats as an empty string (used by nullable dash / gap
    fields when no value is set). Trailing zeros and a stranded
    trailing decimal point are trimmed. An unknown / unsupported
    [unit] falls back to [pt] rather than producing a malformed
    output. *)
val format : float option -> unit:string -> precision:int -> string
