## Project Stage: Prototype - *Exploring structure, algorithms, and implementation. Everything is subject to change.*

## Motivation

The standard Zig parser is no slouch,  
but it’s a full-document parser — reprocessing the entire document from scratch for every edit.

This becomes inefficient for frequent small edits, which this project aims to address through targeted optimizations.

## Goals

NOTE: **Uplift numbers** are based on small edits. Performance may vary for large-scale changes.

- [x] G1: Reuse tokens

    Achieves ~50% uplift (relatively flat latency regardless of edit location)

- [x] G2: Reuse root declarations (part 1)

    Reuse root declarations before the edit point, with performance gains increasing toward document end.
    Achieves G1 + 0–45% uplift

- [ ] G3: Reuse root declarations (part 2)

    Reuse as many root declarations as possible.
    Increased complexity (calculations/viability checks, 2 extra allocations, replace nodes range, shift indices) may lower G2’s uplift but provides a more consistent ~30–45% uplift over G1 across all edit locations

- [ ] G4: Parse only affected nodes

    High complexity. Aims to ensure flat latency across all edit locations for a G1 + 40% total uplift. 

- [x] Specialized AstCheck component

    - Early Exit Support: Checks a thread-safe flag, `change_pending: *std.atomic.Value(bool)`,     
      early in `generate()` and in the `container_decl.ast.members` loop in `structDeclInner()`

    Given that AstCheck shouldn't be called when ast.errors.len != 0, the cases that benefit are:  
    
    - rapidly inserting new lines
    - modifying existing identifiers, ie edits that don't introduce parse errors
    - distant third: ast-check errors past the 50% mark of a large document


## License

This project is licensed under the [MIT License](LICENSE).

It includes large portions of code from **Zig**, which is also released under the [MIT License](LICENSE-ZIG).
