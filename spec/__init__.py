"""The executable SPEC tier: the analytic instruments a checker rules with.

Nothing under `spec/` may import from any port, from the reference
interpreter, or from `scripts/`. That property is what makes this tier a
trusted computing base rather than a fourth implementation with a nicer
name, and it is enforced by `scripts/check_geometry_checkers.py` rather
than left as a convention -- a TCB whose boundary is a comment is not a
TCB.
"""
