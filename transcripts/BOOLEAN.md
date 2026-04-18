# Boolean Operations

The Boolean Operations Panel allows performing a set of boolean operations on the geometry in the selection. These boolean operation are performed on the fill, and ignore stroke properties on the elements.

- UNION merges all elements into a single element, taking the union of their fills.
- INTERSECTION takes the intersection of fills
- SUBTRACT_FRONT subtracts the fill of the frontmost element from all other elements in the selection
- EXCLUDE subtracts the intersection of all elements from all elements in the selection
- DIVIDE cuts the elements apart so that none of them overlap
- TRIM removes the parts of elements that are hidden behind other elements
- MERGE performs a TRIM, and afterwards merges all elements that are touching and have exactly the same fill color
- CROP uses the topmost element as a mask and crops all other elements in the selection, removing anything outside the mask
- SUBTRACT_BACK is like SUBTRACT_FRONT but it subtracts the backmost element from all other elements

```yaml
panel:
- .row: "Shape Modes:"
- .row:
  - .col-2: UNION
  - .col-2: SUBTRACT_FRONT
  - .col-2: INTERSECTION
  - .col-2: EXCLUDE
- .row:
  - .col-2: DIVIDE
  - .col-2: TRIM
  - .col-2: MERGE
  - .col-2: CHOP
  - .col-2: SUBTRACT_BACK
```
