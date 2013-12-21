jass-minifier
=============

A war3map.j Jass minifier for Warcraft 3.

---------------------------------------

#### Features

* Removes unneeded whitespace.
* Renames functions, global variables, function arguments and local variables.
* Removes useless zeroes from numbers, converts hexadecimal numbers to decimal numbers, and changes decimal numbers to exponent representation if it's shorter.  

```
0.10;
1.0;
0x1;
1000;
```
Becomes:  

```
.1;
1.;
1;
1e3;
```

* Inlines constants (also external ones, as seen in [jass_constants](https://github.com/flowtsohg/jass-minifier/jass_constants.j)).
* Removes dead functions.
* Creates constants for heavily used boolean values and numbers.
* Inlines all the one-liner functions in Warcraft 3, as seen in [jass_functions.j](https://github.com/flowtsohg/jass-minifier/jass_functions.j).

---------------------------------------

#### Usage

  `jass_min "input.j" "output.j"`
  
Note that this is meant to run on the final war3map.j file, not any Jass script.
The entry points are the functions `main` and `config`, so if they do not exist, the whole source is considered not used and will be deleted.