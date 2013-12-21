=begin
BUG:
  When inlining functions, "call" needs to be taken into consideration.
  See if the function call is preceded by "call".
  If the function replacement starts with "set", remove the "call", otherwise keep it.
  
TODO:
  - Global shadowing, arguments/local variables renaming must take constant/global names into consideration.
    - To make this work, functions need to be split into a local-block, and code-block.
      Further more, the local-block need to be parsed for the actual locals.
      This is because when renaming all the global names, they should only overwrite in the value part of each local, not the name of the local.
      E.g.:
        Original:
          local integer shadow = 5
          local integer normal = shadow * 5
        
        After global name renaming:
          local integer shadow = 6
          local integer normal = AB * 5
        
        After local name renaming:
          local integer AB = 6
          local integer a = AB * 5
  
  - Create constants for heavily used numbers (e.g. 8191) and booleans (true, false)
    - As long as they are three digits or more of course.
    This needs to be done before creating the final source.
    DID ALREADY FOR BOOLEANS, ADD NUMBERS NEXT
    ADD SORTS BASED ON BYTES SAVED LIKE I DID FOR GLOBAL NAMES!!
  
  - Inline simple equations throughout the source.
    E.g.:
      'aaaa'*5 => whatever it is
      5-1 => 4
    
  - Inline constant strings if it will shorten the code.
    E.g.:
      constant string XX = "hi"
      
      The declaration takes 19 bytes after removing whitespace
      The string size is 4 bytes, including "'s
      Let's assume it is used 5 times.
      The total size is 19+4+(2*5) = 32
      This means that inlining is worth it as long as it's less than 32 bytes, or 32/5 = 6 uses.
    
  - Inline locals that are only used once to the location they are used in.
    E.g.:
      Before:
        function blarg takes nothing returns integer
          local integer a = 5
          return a + 10
        endfunction
      
      After:
        function blarg takes nothing returns integer
          return 5 + 10
        endfunction
      
      After equation solving:
        function blarg takes nothing returns integer
          return 15
        endfunction
        
      After inlining one-liner user functions:
        Nothing!
        
  - Inline one-liner functions from the source, the same way I do with the external ones
  
  - Remove functions with no body
    E.g.:
      function blarg takes nothing returns nothing
      endfunction
      
    Need to handle the calls to them.
    If it's a call Func(), just remove the line.
    What if it's a callback or such? I guess still remove the line, since it's bound to have no effect?
      
=end

def parse_blocks(source)
  globals_block = []
  function_blocks = []
  natives = []
  string_map = {}
  stack = []
  block = []
  chunk = []
  
  source.split(/([ \t]+|\n|\/\/|\/\*|\*\/|"|'|\\.)/).each { |token|
    if token != ""
      mode = stack[0]
      
      if mode == 0
        if token == "\n"
          stack.shift()
          block += [token]
        end
      elsif mode == 1
        if token == "*/"
          stack.shift()
        end
      elsif mode == 2
        if token == "\""
          stack.shift()
          string_map[string_map.length] = block.join("") + token
          chunk += ["\0#{string_map.length - 1}\0"]
          block = []
        else
          block += [token]
        end
      elsif mode == 3
        if token == "'"
          stack.shift()
          string_map[string_map.length] = block.join("") + token
          chunk += ["\0#{string_map.length - 1}\0"]
          block = []
        else
          block += [token]
        end
      elsif mode == 4 and token == "endglobals"
        globals_block = [chunk + [block.join("") + token]]
        chunk = []
        block = []
      elsif mode == 5 and token == "endfunction"
        function_blocks += [(chunk + [block.join("") + token]).join("")]
        chunk = []
        block = []
      elsif mode == 6 and token == "\n"
        natives += [block.join("")]
        chunk = []
        block = []
        stack.shift()
      else
        if token == "//"
          stack.unshift(0)
        elsif token == "/*"
          stack.unshift(1)
        elsif token == "\""
          chunk += [block.join("")]
          stack.unshift(2)
          block = [token]
        elsif token == "'"
          chunk += [block.join("")]
          stack.unshift(3)
          block = [token]
        elsif token == "globals"
          stack.unshift(4)
          block = [token]
        # The function keyword can exist inside functions for function pointers
        elsif token == "function" and mode != 5
          stack.unshift(5)
          block = [token]
        elsif token == "native"
          stack.unshift(6)
          block = [token]
        else
          block += [token]
        end
      end
    end
  }
  
  return globals_block.join(""), function_blocks, natives, string_map
end

def remove_block_whitespaces(block)
  block.strip!()
  block.gsub!(/\n+/, "\n")
  block.gsub!(/[ \t]+/, " ")
  block.gsub!(/^ | $/, "")
  block.gsub!(/[ \t]*(=|\*|,|\+|\/|>|<|\[|\]|\(|\)|\-|!)[ \t]*/, "\\1")
end

def remove_whitespaces(globals_block, function_blocks, natives)
  remove_block_whitespaces(globals_block)
  
  function_blocks.each { |function_block|
    remove_block_whitespaces(function_block)
  }
  
  natives.each { |native|
    native.gsub!(/[ \t]+/, " ")
  }
end

def parse_function_blocks(function_blocks, datatypes)
  function_blocks.collect! { |function|
    function.split(/function\s+(\w+)\s+takes\s+(.*?)\s+returns\s+(\w+)(.*?)endfunction/m)[1..4]
  }
end

def create_external_map(source)
  map = {}
  
  if source
    source.split("\n").each { |line|
      tokens = line.split(" ", 2)
      
      map[tokens[0]] = tokens[1]
    }
  end
  
  map
end

def parse_function_call_arguments(line)
  level = -1
  arguments = []
  buffer = []
  
  line.each_char { |c|
    if c == "("
      level += 1
      
      if level > 0
        buffer += [c]
      end
    elsif c == ")"
      level -= 1
      
      if level > -1
        buffer += [c]
      end
      
      if level == -1 and buffer.length > 0
        arguments.push(buffer.join(""))
        buffer = []
      end
    elsif c == "," and level == 0
      arguments.push(buffer.join(""))
      buffer = []
    else
      buffer += [c]
    end
  }
  
  return arguments, buffer.join("")
end

def inline_external_functions(function_map, external_function_map, external_function_names, string_map)
  function_map.each { |k, function|
    function[0][3].gsub!(external_function_names) {
      arguments, extra = parse_function_call_arguments($2)
      
      line = external_function_map[$1].gsub(/\\(\d+)/) {
        arguments[$1.to_i()]
      }
      
      line + extra
    }
  }
end

def inline_external_constant(constant, string_map)
  if constant[0] == "'"
    string_map[string_map.length] = constant
    "\0#{string_map.length - 1}\0"
  else
    constant
  end
end

def inline_external_constants(globals_block, function_map, external_constant_map, external_constant_names, string_map)
  globals_block.gsub!(external_constant_names) { |name|
    inline_external_constant(external_constant_map[name], string_map)
  }
  
  function_map.each { |k, function|
    function[0][3].gsub!(external_constant_names) { |name|
      inline_external_constant(external_constant_map[name], string_map)
    }
  }
end

def parse_globals_block(globals_block, datatypes)
  constants = {}
  globals = {}
  
  globals_block.scan(/(constant)? ?(\b(?:#{datatypes})\b) ?(array)? (\w+)(?:\s*=(.*))?/) { |match|
    if match[0]
      constants[match[3]] = [match, 0]
    else
      globals[match[3]] = [match, 0]
    end
  }
  
  return constants, globals
end

def create_function_map(function_blocks)
  function_map = {}
  
  function_blocks.each { |function|
    name = function[0]
    
    if name == "main" or name == "config"
      function_map[name] = [function, 1]
    else
      function_map[name] = [function, 0]
    end
  }
  
  return function_map
end

def calls_in_function(function_body, function_map, function_names, string_map)
  calls = function_body.scan(function_names)
  
  function_body.scan(/ExecuteFunc\(\0(\d+)\0\)/) { |string_id|
    calls += [[string_map[string_id[0].to_i(10)][/\w+/]]]
  }
  
  calls.each { |call|
    
    function = function_map[call[0]]
    original = function[1]
    
    function[1] += 1
    
    if original == 0
      calls_in_function(function[0][3], function_map, function_names, string_map)
    end
  }
end

def create_function_usage_map(function_map, function_names, string_map)
  calls_in_function(function_map["main"][0][3], function_map, function_names, string_map)
  calls_in_function(function_map["config"][0][3], function_map, function_names, string_map)
end

def create_globals_usage_map(map, function_map, names, string_map)
  # Get the number of uses
  if map.length > 0
    function_map.each { |k, function|
      body = function[0][3]
      matches = body.scan(names)
      
      body.scan(/TriggerRegisterVariableEvent\(.*?\0(\d+)\0/) { |string_id|
        name = string_map[string_id[0].to_i(10)].partition(/\w+/)[1]
        
        if name[names]
          matches += [[name]]
        end
      }
      
      matches.each { |match|
        map[match[0]][1] += 1
      }
    }
  end
end

def id_to_integer(id)
  integer = 0
  
  (1...id.length - 1).each { |i|
    integer = integer * 256 + id[i].ord()
  }
  
  integer
end

def integer_to_id(integer)
  map = ".................................!.#$%&'()*+,-./0123456789:;<=>.@ABCDEFGHIJKLMNOPQRSTUVWXYZ[.]^_`abcdefghijklmnopqrstuvwxyz{|}~................................................................................................................................."
  id = ""
  
  (0...4).each { |i|
    char = integer % 256
    integer = (integer / 256).floor()
    
    id += map[char]
  }
  
  "'#{id.reverse()}'"
end

def replace_string_map(block, string_map)
  block.gsub(/\0(\d+)\0/).each {
    string_map[$1.to_i(10)]
  }
end

def replace_ids(block)
  block.gsub(/'\w+'/).each { |id| id_to_integer(id) }
end

def prepare_constant(constant_map, constant, string_map)
  begin
    # Replace integer base 256 literals with numbers, and add trailing numbers to reals to validate them for eval
    value = eval(replace_ids(replace_string_map(constant[0][4], string_map)).gsub(/\b(\d+\.)(?!\d)/, "\\10")).to_s()
    
    constant[0][4] = value
    constant[2] = true
    
    constant_map.each { |k, v|
      v[0][4].gsub!(constant[0][3], value)
    }
  rescue
  end
end

def inline_constants(function_map, constant_map, constant_names, string_map)
  if constant_map.length > 0
    constant_map.each { |k, constant|
      datatype = constant[0][1]
      
      if datatype == "integer" or datatype == "real" or datatype == "boolean"
        prepare_constant(constant_map, constant, string_map)
      end
    }
    
    function_map.each { |k, function|
      function[0][3].gsub!(constant_names) { |name|
        constant = constant_map[name]
        
        if constant[2]
          constant[0][4]
        else
          name
        end
      }
    }
    
    # Remove constants that were inlined from the list
    constant_map.keep_if { |k, constant|
      constant[2] != true
    }
  end
end

def create_all_usage_map(constant_map, global_map, function_map)
  usage_map = []
  
  constant_map.each { |k, v|
    usage_map.push([k, v[1]])
  }
  
  global_map.each { |k, v|
    usage_map.push([k, v[1]])
  }
  
  function_map.each { |k, v|
    if v[0][0] != "main" and v[0][0] != "config"
      usage_map.push([k, v[1]])
    end
  }
  
  usage_map.sort { |a, b|
    b[1] <=> a[1]
  }
end

def create_all_name_map(usage_map, names)
  name_map = {}
  
  usage_map.each { |v|
    name_map[v[0]] = names.shift()
  }
  
  name_map
end

def rename_all(constant_map, global_map, function_map, all_name_map, all_names, string_map)
  # Rename all constants
  constant_map.each { |k, constant|
    constant[0][3] = all_name_map[constant[0][3]]
  }
  
  # Rename all globals
  global_map.each { |k, global|
    global[0][3] = all_name_map[global[0][3]]
  }
  
  function_map.each { |k, function|
    # Rename the function name
    if function[0][0] != "main" and function[0][0] != "config"
      function[0][0] = all_name_map[function[0][0]]
    end
  
    # Rename all the names in the function body
    function[0][3].gsub!(all_names) { |name|
      all_name_map[name]
    }
  
    # Rename function/global names in ExecuteFunc/TriggerRegisterVariableEvent strings
    function[0][3].scan(/(?:ExecuteFunc|TriggerRegisterVariableEvent).*?\0(\d+)\0/) { |string_id|
      string_map[string_id[0].to_i(10)].sub!(/(\w+)/) { |name|
        all_name_map[name] or name
      }
    }
  }
end

def rename_function_locals(function, all_name_map, datatypes)
  locals = {}
  names = [*("a".."z"), *("aa".."zz"), *("a0".."z9")]
  
  # Create a usage map
  # Arguments are always used so initialize with 1
  function[1].scan(/(?:#{datatypes}) (\w+)/) { |name|
    locals[name[0]] = [1]
  }
  
  # Locals might not be used, so initialize with -1 so that their own declaration will fix to 0
  function[3].scan(/(local (?:#{datatypes}) (\w+).*)/) { |line, name|
    locals[name] = [-1, line]
  }
  
  if locals.length > 0
    local_names = /\b(#{locals.collect { |k, v| k }.sort().join("|")})\b/
    
    function[3].scan(local_names) { |name|
      locals[name[0]][0] += 1
    }
    
    # Remove unused locals from the function body and the locals list
    locals.keep_if { |k, local|
      if local[0] == 0
        function[3].sub!(local[1], "")
        false
      else
        true
      end
    }
    
    locals_map = []
    
    locals.each { |k, local|
      locals_map.push([k, local])
    }
    
    locals_map.sort! { |a, b|
      b[1][0] <=> a[1][0]
    }
    
    locals_map.each { |local|
      locals[local[0]][2] = names.shift()
    }
    
    # Rename the arguments
    function[1].gsub!(local_names) { |name|
      locals[name][2]
    }
    
    # Rename the arguments and locals in the function body
    function[3].gsub!(local_names) { |name|
      locals[name][2]
    }
  end
end

def rename_locals(function_map, all_name_map, datatypes)
  function_map.each { |k, function|
    rename_function_locals(function[0], all_name_map, datatypes)
  }
end

def rename_natives(natives)
  natives.each { |native|
    names = [*("a".."z")]
    
    native.gsub!(/takes (.*?) returns/) {
      arguments = $1.split(",")
      
      arguments.collect! { |argument|
        argument.split(" ")
      }
      
      arguments.collect! { |argument|
        "#{argument[0]} #{argument[1].replace(names.shift())}"
      }
      
      "takes #{arguments.join(",")} returns"
    }
  }
end

def create_constants(constant_map, global_map, function_map, names)
  usage_map = {"true" => 0, "false" => 0}
  replacement_map = {}
  
  global_map.each { |k, global|
    if global[0][4]
      global[0][4].scan(/\b(?:true|false)\b/).each { |match|
         usage_map[match] += 1
      }
    end
  }
  
  function_map.each { |k, function|
     function[0][3].scan(/\b(?:true|false)\b/).each { |match|
       usage_map[match] += 1
    }
  }
  
  usage_map.each { |k, v|
    usage_size = k.length * usage_map[k]
    replaced_usage_size = usage_map[k] * names[0].length + "constant boolean =#{k}".length + names[0].length
    
    if replaced_usage_size < usage_size
      name = names.shift()
      replacement_map[k] = name
      constant_map[name] = [["constant", "boolean", nil, name, k]]
    end
  }
  
  name_map = /\b(#{replacement_map.collect { |k, v| k }.sort().join("|")})\b/
  
  global_map.each { |k, global|
    if global[0][4]
      global[0][4].gsub!(name_map).each {
        replacement_map[$1]
      }
    end
  }
  
  
  function_map.each { |k, function|
     function[0][3].gsub!(name_map).each {
        replacement_map[$1]
    }
  }
end

def make_global_source(global)
  source = ""
  
  if global[0]
    source += "#{global[0]} "
  end
  
  source += "#{global[1]} "
  
  if global[2]
    source += "#{global[2]} "
  end
  
  source += "#{global[3]}"
  
  if global[4] and global[4] != ""
    source += "=#{global[4]}"
  end
  
  source
end
  
def rewrite_numbers(source, string_map)
  # Turn hexadecimal numbers to decimal ones
  source.gsub!(/0x[0-9a-fA-F]+/) { |v|
    v.to_i(16)
  }
  
  # This still grabs 1000. as 1000
  #~ source.gsub!(/\b(\d*\.?\d+)\b/) { |n|
    #~ p $1
    #~ # Remove trailing zeroes for reals
    #~ if n["."]
      #~ n.to_f().to_s()
    #~ # Rewrite big decimal numbers in exponent form if it's smaller
    #~ else
      #~ n.gsub(/([1-9]\d*?)(0+)/) {
        #~ n = $1
        #~ e = $2

        #~ if e.size > 2
          #~ "#{n}e#{(e.size - 1)}"
        #~ else
          #~ n + e
        #~ end 
      #~ }
    #~ end
  #~ }
  
  #source.gsub!(/[0]+(\.\d+)/, "\\1")
  #source.gsub!(/(\d+\.)[0]+/, "\\1")
  #source.gsub!(/\b\.0\b/, "0.")
  
  # Turn big numbers to their id representation
  source.gsub!(/\b(\d+)\b/) { |v|
    n = v.to_i
    
    if n > 999999
      integer_to_id(n)
    else
      v
    end
  }
end

def make_function_source(function)
  "function #{function[0]} takes #{function[1]} returns #{function[2]}\n#{function[3]}\nendfunction"
end

def make_source(constant_map, global_map, natives, function_map, string_map)
  source = "globals\n"
  
  constant_map.each { |k, v|
    source += "#{make_global_source(v[0])}\n"
  }
  
  global_map.each { |k, v|
    source += "#{make_global_source(v[0])}\n"
  }
  
  source += "endglobals\n"
  source += "#{natives.join("\n")}\n"
  
  function_map.each { |k, v|
    source += "#{make_function_source(v[0])}\n"
  }
  
  # Rewrite numbers to shorter forms
  rewrite_numbers(source, string_map)
  
  source.gsub!(/\n+/, "\n")
  
  # Replace all the string ids with their actual content
  replace_string_map(source, string_map)
end

def minify_source(source, external_constants, external_functions) 
  datatypes = "integer|real|string|code|boolean|nothing|handle|agent|event(?:id)?|player(?:state|score|gameresult|event|unitevent|slotstate|color)?|widget(?:event)?|unit(?:pool|state|event|type)?|destructable|item(?:pool|type)?|ability|buff|force|group|trigger(?:condition|action)?|timer(?:dialog)?|location|region|rect|boolexpr|sound|(?:condition|filter)?func|race(?:preference)?|[if]?game(?:state|event|speed|difficulty|type|cache)|aidifficulty|limitop|dialog(?:event)?|map(?:flag|visibility|setting|density|control)?|volumegroup|camera(?:field|setup)?|placement|startlocprio|raritycontrol|blendmode|texmapflags|(?:weather)?effect(?:type)?|terraindeformation|fog(?:state|modifier)?|button|quest(?:item)?|defeatcondition|(?:leader|multi)?board(?:item)?|trackable|version|texttag|(?:attack|damage|weapon|sound|pathing|alliance)?type|lightning|image|ubersplat|hashtable"
  names = [*("A".."Z"), *("AA".."ZZ"), *("aA".."zZ"), *("Aa".."Zz"), *("A0".."Z9"), *("A_".."Z_"), *("_A".."_Z"), *("AAA".."ZZZ"), *("Aaa".."Zzz"), *("AAa".."ZZz"), *("AA0".."ZZ9"), *("A00".."Z99"), *("A0A".."Z9Z")]

  # Parse the source into appropriate chunks
  globals_block, function_blocks, natives, string_map = parse_blocks(source)
  
  # Remove useless whitespaces
  remove_whitespaces(globals_block, function_blocks, natives)
  
  # Split function blocks into their different parts
  parse_function_blocks(function_blocks, datatypes)
  
  # Create the function name=>function map and record the times each one is used
  function_map = create_function_map(function_blocks)
  function_names = /\b(#{function_map.collect { |k, v| k }.sort().join("|")})\b/
  
  create_function_usage_map(function_map, function_names, string_map)
  
  count = function_map.length
  # Remove dead functions
  function_map.keep_if { |k, v|
    v[1] > 0
  }
  puts "Removed #{count - function_map.length} functions"
  
  # Create the external functions name=>value map
  external_function_map = create_external_map(external_functions)
  external_function_names = /\b(#{external_function_map.collect { |k, v| k }.sort().join("|")})\b(.*)/
  
  # Inline external functions
  inline_external_functions(function_map, external_function_map, external_function_names, string_map)
  
  # Create the external constants name=>value map
  external_constant_map = create_external_map(external_constants)
  external_constant_names = /\b(#{external_constant_map.collect { |k, v| k }.sort().join("|")})\b/
  
  # Inline the external constants
  inline_external_constants(globals_block, function_map, external_constant_map, external_constant_names, string_map)
  
  # Parse the globals block
  constant_map, global_map = parse_globals_block(globals_block, datatypes)
  
  # Create the constants name=>constant map and record the times each one is used
  constant_names = /\b(#{constant_map.collect { |k, v| k }.sort().join("|")})\b/
  create_globals_usage_map(constant_map, function_map, constant_names, string_map)
  
  count = constant_map.length
  # Remove dead constants
  constant_map.keep_if { |k, v|
    v[1] > 0
  }
  puts "Removed #{count - constant_map.length} constants"
  
  # Create the globals name=>global map and and record the times each one is used
  global_names = /\b(#{global_map.collect { |k, v| k }.sort().join("|")})\b/
  create_globals_usage_map(global_map, function_map, global_names, string_map)
  
  count = global_map.length
  # Remove dead globals
  global_map.keep_if { |k, v|
    v[1] > 0
  }
  puts "Removed #{count - global_map.length} globals"
  
  # Inline constants if possible
  constant_names = /\b(#{constant_map.collect { |k, v| k }.sort().join("|")})\b/
  inline_constants(function_map, constant_map, constant_names, string_map)
  
  # Rename all the remaining constants, globals, and functions
  all_usage_map = create_all_usage_map(constant_map, global_map, function_map)
  all_name_map = create_all_name_map(all_usage_map, names)
  all_names = /\b(#{all_name_map.collect { |k, v| k }.sort().join("|")})\b/
  rename_all(constant_map, global_map, function_map, all_name_map, all_names, string_map)
  
  # Rename function arguments and locals
  rename_locals(function_map, all_name_map, datatypes)
  
  # Rename native arguments
  rename_natives(natives)

  # Create constants for common numbers and booleans
  create_constants(constant_map, global_map, function_map, names)
  
  make_source(constant_map, global_map, natives, function_map, string_map)
end

def minify_file(path, external_constants, external_functions)
  if File.exist?(external_constants)
    external_constants = IO.read(external_constants)
  else
    external_constants = nil
  end
  
  if File.exist?(external_functions)
    external_functions = IO.read(external_functions)
  else
    external_functions = nil
  end
  
  minify_source(IO.read(path), external_constants, external_functions)
end

 source = minify_file(ARGV[0], "jass_constants.j", "jass_functions.j")

File.open(ARGV[1], "w") { |output|
  output.write(source)
}