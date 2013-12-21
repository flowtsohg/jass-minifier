jass-minifier
=============

A war3map.j Jass minifier for Warcraft 3.

---------------------------------------

#### Features

* Removes unneeded whitespace.
* Renames functions, global variables, function arguments and local variables.
* Removes useless zeroes from numbers, converts hexadecimal numbers to decimal numbers, and changes decimal numbers to exponent representation if it's shorter.  
* Inlines constants (also external ones, as seen in [jass_constants](https://github.com/flowtsohg/jass-minifier/blob/master/jass_constants.j)).
* Removes dead functions and globals.
* Creates constants for heavily used boolean values and numbers.
* Inlines all the one-liner functions in Warcraft 3, as seen in [jass_functions.j](https://github.com/flowtsohg/jass-minifier/blob/master/jass_functions.j).

---------------------------------------

#### Usage

  `jass_min "input.j" "output.j"`
  
Note that this is meant to run on the final war3map.j file, not any Jass script.
The entry points are the functions `main` and `config`, so if they do not exist, the whole source is considered not used and will be deleted.

---------------------------------------

More functions can be added to the inline list, the syntax is very simple: the first word is the function that is getting replaced, followed by a space, and the rest of the line is the replacement.
The original function arguments are mapped to `\0`, `\1`, and so on.
