A practical programming language with a single instruction and a single datatype.

All data are S-expressions, which are either a slice of bytes, or a pair of S-expressions: `("foo" . ("bar" . "etc"))`. A single S-expression might be interpreted as a string, a number, an instruction, a list of S-expressions, a function, etc.

Functions are a list of instructions. Every function takes and returns exactly one value.

The only instruction has four parameters: a pattern, a template, the name of a function to call on the filled template, and a list of next instructions to execute if the match was succesful. Here is an incomplete "add" function:
```
( "1" . "2" ) -> "3";
( "2" . "1" ) -> add: ("1" . "2");
( "0" . x ) -> x;
( "2" . x ) -> add: ( "1" . x ) {
    result -> add: ( "1" . result );
}
```

There are only 4 builtin functions:
- `@eqAtoms?`: returns `"true"` if the input is a pair of two identical byte slices, `"false"` otherwise.
- `@join`: takes as input a list of byte slices; returns a single byte slice with their concatenation.
- `@split`: the opposite of `@join`
- `@dyncall`: takes as input a pair of `(path_to_dynamic_library . function_name)` and a value, calls that function on that value and returns the result.

External functions are inspired by Lua, and must take a pointer to a `Swidy` instance, and a single `u32` index to a S-expression, returning another `u32` index for the result.

The `swidy` executable is a debugger; TODO: instructions

There are 3 versions of the language, the three practical ways of defining recursive functions:
- dynamically scoped variables
- mutable environments
- global environment only for functions
