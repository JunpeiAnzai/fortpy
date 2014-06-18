import re

#This module has all the classes for holding the structure of a fortran
#code file and its docstrings.
class CodeElement(object):
    """Represents a code element (e.g. parameter, module, subroutine) etc."""
    
    def __init__(self, name, modifiers, parent):
        self.name = name
        self.modifiers = modifiers
        #Docstring is a list of DocElement intstances describing the code
        self.docstring = []
        #groups is a list of DocGroup() that contain the groupings of the DocElements
        #within the code element.
        self.groups = {}
        self.parent = parent
        #The start and end character indices of the code element definition in the file
        self.start = 0
        self.end = 0

        self._tests = None
        self._module = None
        self._full_name = None

        #If the modifiers passed in is None, set it to an empty list
        #sometimes when there is no regex match on the modifiers we get None
        if self.modifiers is None:
            self.modifiers = []
        else:
            self.clean_mods(self.modifiers)
        
    def overwrite_docs(self, doc):
        """Adds the specified DocElement to the docstring list. However, if an
        element with the same xml tag and pointsto value already exists, it
        will be overwritten."""
        for i in range(len(self.docstring)):
            if (self.docstring[i].doctype == doc.doctype and
                self.docstring[i].pointsto == doc.pointsto):
                del self.docstring[i]
                break

        self.docstring.append(doc)

    def __getstate__(self):
        """Cleans up the object so that it can be pickled without any pointer
        issues. Saves the full names of parents etc. so that they can be 
        restored once the unpickling is completed."""
        odict = self.__dict__.copy() # copy the dict since we change it
        del odict['_tests']
        del odict['_module']
        del odict['parent']
        return odict

    def __setstate__(self, dict):
        self._tests = None
        self._module = None
        self.parent = None
        self.__dict__.update(dict)

    def unpickle_docs(self):
        """Sets the pointers for the docstrings that have groups."""
        for doc in self.docstring:
            if (doc._parent_name is not None and 
                doc._parent_name in self.groups):
                doc.group = self.groups[doc._parent_name]                

    def unpickle(self, parent):
        """Sets the parent pointer references for the type executable."""
        self.parent = parent
        self.unpickle_docs()

    @property
    def embedded(self):
        """Value indicates whether this type declaration is embedded in an executable
        rather than the module, which is the natural default."""
        return not isinstance(self.parent, Module)

    @property
    def absstart(self):
        """Returns the absolute start of the element by including docstrings
        outside of the element definition if applicable."""
        if hasattr(self, "docstart") and self.docstart > 0:
            return self.docstart
        else:
            return self.start

    @property
    def module(self):
        """Returns the module that this code element belongs to."""
        if self._module is None:
            root = self
            while self._module is None and root is not None:
                if isinstance(root, Module):
                    self._module = root
                else:
                    root = root.parent

        return self._module

    @property
    def summary(self):
        """Returns the docstring summary for the code element if it exists."""
        result = ""
        for doc in self.docstring:
            if doc.doctype == "summary":
                result = doc.contents
                break

        #Some of the code elements don't have summary tags (e.g. parameters)
        #but then they would only have a single docstring anyway.
        if result == "" and len(self.docstring) > 0:
            result = self.docstring[0].contents

        return result

    @property
    def full_name(self):
        """Returns the full name of this element by visiting every
        non-None parent in its ancestor chain."""
        if self._full_name is None:
            ancestors = [ self.name ]
            current = self.parent
            while current is not None:
                ancestors.append(current.name)
                current = current.parent

            self._full_name = ".".join(ancestors)
        
        return self._full_name

    @property
    def tests(self):
        """Returns a the contents of a group with purpose="testing" if it exists."""
        if self._tests is None:
            self._tests = []
            for gkey in self.groups:
                docgrp = self.groups[gkey]
                if "purpose" in docgrp.attributes and \
                   docgrp.attributes["purpose"].lower() == "testing":
                    for docel in self.docstring:
                        if docel.group == docgrp.name:
                            self._tests.append(docel)

        return self._tests

    @property
    def has_docstring(self):
        """Specifies whether this code element has a docstring."""
        return type(self.docstring) != type(None)        

    def warn(self, collection):
        """Checks this code element for documentation related problems."""
        if not self.has_docstring():
            collection.append("WARNING: no docstring on code element {}".format(self.name))

    def clean_mods(self, modifiers):
        """Cleans the modifiers to remove empty entries."""
        if "" in modifiers and type(modifiers) == type([]):
            modifiers.remove("")

class ValueElement(CodeElement):
    """Represents a code element that can hold a value."""

    def __init__(self, name, modifiers, dtype, kind, default, dimension, parent):
        super(ValueElement, self).__init__(name, modifiers, parent)
        self.dtype = dtype
        self.kind = self._clean_args(kind)
        self.default = default
        self.dimension = self._clean_args(dimension)

    def __str__(self):
        kind = "({})".format(self.kind) if self.kind is not None else ""   
        if len(self.modifiers) > 0:
            mods = ", " + ", ".join(self.modifiers) + " " 
        else:
            mods = " "
        dimension = "({})".format(self.dimension) if self.dimension is not None else ""
        default = " = {}".format(self.default) if self.default is not None else ""
        return "{}{}{}:: {}{}{}".format(self.dtype, kind, mods, self.name, dimension, default)

    def _clean_args(self, arg):
        """Removes any leading and trailing () from arguments."""
        if arg is not None:
            return re.sub("[()]", "", arg)
        else:
            return None

    @property
    def is_custom(self):
        """Returns a value indicating whether this value element is of a derived type."""
        return self.dtype == "class" or self.dtype == "type"

class Dependency(object):
    """Represents a call to a function or subroutine from within another
    thus making one executable dependent on the others."""
    def __init__(self, name, argslist, isSubroutine, parent):
        self._name = name
        self.argslist = self.clean(argslist)
        self.parent = parent
        self.isSubroutine = isSubroutine
        
        self._module = None

    def __str__(self):
        if self.isSubroutine:
            call = "call "
        else:
            call = ""
        return "\t{}{}({})".format(call, self._name, ", ".join(self.argslist))

    def unpickle(self, parent):
        """Sets the parent pointer references for the type executable."""
        self.parent = parent

    @property
    def name(self):
        """Returns the lower case name of the dependency."""
        return self._name.lower()

    @property
    def fullname(self):
        """Returns the original name of the dependency as found in the code."""
        return self._name
        
    @property
    def external_name(self):
        """Returns the modulename.executable string that uniquely identifies
        the executable that this dependency points to."""
        return "{}.{}".format(self.module.name.lower(), self.name)

    @property
    def module(self):
        """Returns the module that this code element belongs to."""
        if self._module is None:
            root = self
            while self._module is None and root is not None:
                if isinstance(root, Module):
                    self._module = root
                else:
                    root = root.parent

        return self._module

    def clean(self, argslist):
        """Cleans the argslist."""
        result = []
        for arg in argslist:
            if type(arg) == type([]):
                if len(result) > 0:
                    result[-1] = result[-1] + "(*{})".format(len(self.clean(arg)))
                elif "/" not in arg[0]:
                    print("WARNING: argument to function call unrecognized. {}".format(arg))
            else:
                cleaner = re.sub("[:,]+", "", arg).strip()
                if len(cleaner) > 0:
                    result.append(cleaner)
        
        return result

class Decoratable(object):
    """Represents a class that can have an *external* docstring attached."""
    def __init__(self):
        #The start and end characters for the docstring that decorates this code element
        self.docstart = 0
        self.docend = 0

    def find_section(self, charindex):
        """Returns a value indicating whether the specified character index
        is owned by the current object."""
        #All objects instances of decorable also inherit from CodeElement,
        #so we should have no problem accessing the start and end attributes.
        result = None
        if hasattr(self, "start") and hasattr(self, "end"):
            #The 8 seems arbitrary, but it is the length of type::b\n for a
            #really short type declaration with one character name.
            if charindex > self.docend and charindex - self.start < 8:
                result = "signature"
            elif charindex >= self.start and charindex <= self.end:
                result = "body"

        if (result is None and charindex >= self.docstart 
            and charindex <= self.docend):
            result = "docstring"
            
        return result
    
class Executable(ValueElement, Decoratable):
    """Represents a function or subroutine that can be executed with parameters."""
    def __init__(self, name, modifiers, dtype, kind, default, dimension, parent):
        super(Executable, self).__init__(name, modifiers, dtype, kind, 
                                         default, dimension, parent)
        Decoratable.__init__(self)
        self.members = {}
        self.dependencies = {}
        #Initialize dicts for the embedded types and executables.
        self.types = {}
        self.executables = {}

        #The order in which the parameters are presented to the function
        self.paramorder = []
        #The string between the end of the signature and the start of the end
        #token for this executable.
        self.contents = None
        #When an instance is add from just a signature and doesn't have an 
        #end_token, this is set to True
        self.incomplete = False
        self._parameters = {}
        self._assignments = []

    def unpickle(self, parent):
        """Sets the parent pointer references for the module *and* all of its
        child classes that also have pointer references."""
        self.parent = parent
        self._unpickle_collection(self.members)
        self._unpickle_collection(self.dependencies)
        self._unpickle_collection(self.types)
        self._unpickle_collection(self.executables)
        self._unpickle_collection(self._parameters)
        self.unpickle_docs()
        
    def _unpickle_collection(self, collection):
        """Unpickles all members of the specified dictionary."""
        for mkey in collection:
            if isinstance(collection[mkey], list):
                for item in collection[mkey]:
                    item.unpickle(self)
            else:
                collection[mkey].unpickle(self)

    def rt_update(self, statement, linenum, mode, xparser):
        """Uses the specified line parser to parse the given line.

        :arg statement: a string of lines that are part of a single statement.
        :arg linenum: the line number of the first line in the list relative to
          the entire module contents.
        arg mode: either 'insert', 'replace' or 'delete'
        :arg xparser: an instance of the executable parser from the real
          time update module's line parser.
        """
        section = self.find_section(self.module.charindex(linenum, 1))

        if section == "body":
            xparser.parse_line(statement, self, mode)
        elif section == "signature":
            if mode == "insert":
                xparser.parse_signature(statement, self)
        #NOTE: docstrings are handled at a higher level by the line parser
        #because of the XML dependence.

    def update_name(self, name):
        """Changes the name of this executable and the reference to it in the
        parent module."""
        if name != self.name:
            self.parent.executables[name] = self
            del self.parent.executables[self.name]
            self.name = name

    @property
    def refstring(self):
        """The string from which this executable was extracted with regex. It is the
        section after the CONTAINS statement in the module."""
        if self.parent is not None:
            return self.parent.contains
        else:
            return ""

    def changed(self, symbol, checked = None):
        """Returns true if the specified symbol has it's value changed
        by this executable or *any* of its dependencies."""
        #Initialize the dictionary if we are the first executable to call this.
        myname = "{}.{}".format(self.module.name, self.name).lower()
        if checked is None:
            checked = []

        if myname not in checked:
            if self._get_assignments_in(self._parameters, symbol) == True:
                return myname
            else:
                #Make sure we don't check any executable twice.
                checked.append(myname)
                #We need to check the dependencies of this executable and
                #see if any of them modify the parameter.
                for dependlist in self.dependencies:
                    for dependency in self.dependencies[dependlist]:
                        iexec = self.module.parent.get_executable(dependency.external_name)
                        if iexec is not None and iexec.changed(symbol, checked) != "":
                            return dependency.external_name
                        else:
                            checked.append(dependency.external_name)
        else:
            return None

    def local_assignments(self):
        """Returns a list of local variable code elements whose values change in
        this executable."""
        return self._get_assignments_in(self.members)

    def external_assignments(self):        
        """Returns a list of parameter code elements whose values change in
        this executable."""
        return self._get_assignments_in(self._parameters)

    def _get_assignments_in(self, filterlist, symbol = ""):
        """Returns a list of code elements whose names are in the specified object.

        :arg filterlist: the list of symbols to check agains the assignments.
        :arg symbol: when specified, return true if that symbol has its value
          changed via an assignment."""
        if symbol != "":
            lsymbol = symbol
            for assign in self._assignments:
                target = assign.split("%")[0].lower()
                if target == lsymbol:
                    return True
        else:
            result = []
            for assign in self._assignments:
                target = assign.split("%")[0].lower()
                if target in filterlist:
                    result.append(assign)
            return result

    @property
    def assignments(self):
        """Returns a list of the names of all the objects whose values change
        in this executable."""
        return self._assignments

    @property
    def ordered_parameters(self):
        """Returns a list of the ordered parameters."""
        return [ self._parameters[k] for k in self.paramorder]

    @property
    def parameters(self):
        """Returns the dictionary of parameters in this exectuable."""
        return self._parameters

    def get_parameter(self, index):
        """Returns the ValueElement corresponding to the parameter
        at the specified index."""
        result = None
        if index > 0 and index < len(self.paramorder):
            key = self.paramorder[index]
            if key in self._parameters:
                result = self._parameters[key]

        return result

    def add_parameter(self, parameter):
        """Adds the specified parameter value to the list."""
        if parameter.name.lower() not in self.paramorder:
            self.paramorder.append(parameter.name.lower())
        self._parameters[parameter.name.lower()] = parameter

    def remove_parameter(self, parameter_name):
        """Removes the specified parameter from the list."""
        if parameter_name in self.paramorder:
            index = self.paramorder.index(parameter_name)
            del self.paramorder[index]

        if parameter_name in self._parameters:
            del self._parameters[parameter_name]

    def parameters_as_string(self):
        """Returns a comma-separated list of the parameters in the executable definition."""
        params = ", ".join([ p.name for p in self.ordered_parameters ])
        return params

    def add_assignment(self, value):
        """Adds the name of a variable/parameter whose value is changed by
        this exectuable."""
        if not value in self._assignments:
            self._assignments.append(value)

    def add_dependency(self, value):
        """Adds the specified executable dependency to the list for this executable."""
        if value.name in self.dependencies:
            self.dependencies[value.name.lower()].append(value)
        else:
            self.dependencies[value.name.lower()] = [ value ]

class Function(Executable):
    """Represents a function in a program or module."""    
    def __init__(self, name, modifiers, dtype, kind, parent):
        super(Function, self).__init__(name, modifiers, dtype, kind, None, None, parent)

    def __str__(self):
        params = self.parameters_as_string()
        
        depend = "{} dependencies ".format(len(list(self.dependencies.keys())))
        if len(list(self.dependencies.keys())) == 0:
            depend = ""
        assign = "{} assignments".format(len(self.external_assignments()))
        if len(self.external_assignments()) == 0:
            assign = ""
        if depend != "" or assign != "":
            info = "\n\t  - {}{}".format(depend, assign)
        else:
            info = ""

        return "{}FUNCTION {}({}){}".format(self.returns, self.name, 
                                                    params, info)

    @property
    def end_token(self):
        """Gets the end [code type] token for this instance."""
        return "end function"

    def update(self, name, modifiers, dtype, kind):
        """Updates the attributes for the function instance, handles name changes
        in the parent module as well."""
        self.update_name(name)
        self.modifiers = modifiers
        self.dtype = dtype
        self.kind = kind

    @property
    def returns(self):
        """Gets a string showing the return type and modifiers for the
        function in a nice display format."""
        kind = "({}) ".format(self.kind) if self.kind is not None else ""      
        mods = ", ".join(self.modifiers) + " "
        dtype = self.dtype if self.dtype is not None else ""
        return "{}{}{}".format(dtype, kind, mods)

class Subroutine(Executable):
    """Represents a function in a program or module."""   
    def __init__(self, name, modifiers, parent):
        super(Subroutine, self).__init__(name, modifiers, None, None, None, None, parent)

    def __str__(self):
        params = self.parameters_as_string()
        mods = ", ".join(self.modifiers)

        depend = "{} dependencies ".format(len(list(self.dependencies.keys())))
        if len(list(self.dependencies.keys())) == 0:
            depend = ""
        assign = "{} assignments".format(len(self.external_assignments()))
        if len(self.external_assignments()) == 0:
            assign = ""
        if depend != "" or assign != "":
            info = "\n\t  - {}{}".format(depend, assign)
        else:
            info = ""

        return "{} SUBROUTINE {}({}){}".format(mods, self.name, params, info)

    @property
    def end_token(self):
        """Gets the end [code type] token for this instance."""
        return "end subroutine"

    def update(self, name, modifiers):
        """Updates the attributes for the subroutine instance, handles name changes
        in the parent module as well."""
        self.update_name(name)
        self.modifiers = modifiers

class TypeExecutable(CodeElement):
    """Represents a function or subroutine declared in a type that can be executed."""
    
    def __init__(self, name, modifiers, parent, pointsto = None):
        super(TypeExecutable, self).__init__(name, modifiers, parent)
        self.pointsto = pointsto

    def __str__(self):
        mods = ", ".join(self.modifiers)
        pointsto = " => {}".format(self.pointsto) if self.pointsto is not None else ""
        return "{} {}{}".format(mods, self.name, pointsto)

    def parseline(self, line, lineparser):
        """Uses the specified line parser to parse the given line."""
        lineparser.tparser.parseline(self, line)

    def unpickle(self, parent):
        """Sets the parent pointer references for the type executable."""
        self.parent = parent
        self.unpickle_docs()

    @property
    def target(self):
        """Returns the code element that is the actual executable that this type
        executable points to."""
        if self.pointsto is not None:
            #It is in the format of module.executable.
            return self.module.parent.get_executable(self.pointsto)
        else:
            #The executable it points to is the same as its name.
            fullname = "{}.{}".format(self.module.name, self.name)
            return self.module.parent.get_executable(fullname.lower())

class CustomType(CodeElement, Decoratable):
    """Represents a custom defined type in a fortran module."""
    
    def __init__(self, name, modifiers, members, parent):
        super(CustomType, self).__init__(name, modifiers, parent)
        Decoratable.__init__(self)
        #A list of ValueElements() that were declared in the body of the type.
        self.members = members
        #A list of Executable() declared within the contains section of the type.        
        self.executables = {}
        #When an instance is add from just a signature and doesn't have an 
        #end_token, this is set to True
        self.incomplete = False

    def __str__(self):
        execs = "\n\t  - ".join([ x.__str__() for x in self.executables ])
        mods = ", ".join(self.modifiers)
        allexecs = "\n\t  - {}".format(execs) if len(self.executables) > 0 else ""
        mems = "\n\t - ".join([x.__str__() for x in self.members ])
        return "TYPE {} ({}){}\nMEMBERS\n\t{}".format(self.name, mods, allexecs, mems)

    @property
    def end_token(self):
        """Gets the end [code type] token for this instance."""
        return "end type"

    def update_name(self, name):
        """Updates the name of the custom type in this instance and its
        parent reference."""
        if name != self.name:
            self.parent.types[name] = self
            del self.parent.types[self.name]
            self.name = name

    def rt_update(self, statement, linenum, mode, tparser):
        """Uses the specified line parser to parse the given line.

        :arg statement: a string of lines that are part of a single statement.
        :arg linenum: the line number of the first line in the statement relative to
          the entire module contents.
        arg mode: either 'insert', 'replace' or 'delete'
        :arg tparser: an instance of the type parser from the real
          time update module's line parser.
        """
        section = self.find_section(self.module.charindex(linenum, 1))
        if section == "body":
            tparser.parse_line(statement, self, mode)
        elif section == "signature":
            if mode == "insert":
                tparser.parse_signature(statement, self)
        #NOTE: docstrings are handled at a higher level by the line parser
        #because of the XML dependence.

    def unpickle(self, parent):
        """Sets the parent pointer references for the type *and* all of its
        child classes that also have pointer references."""
        self.parent = parent
        self._unpickle_collection(self.members)
        self._unpickle_collection(self.executables)
        self.unpickle_docs()
        
    def _unpickle_collection(self, collection):
        """Unpickles all members of the specified dictionary."""
        for mkey in collection:
            collection[mkey].unpickle(self)

    @property
    def refstring(self):
        """Returns a reference to the string from which this custom type was parsed."""
        if this.parent is not None:
            return this.parent.contents
        else:
            return ""

class Module(CodeElement, Decoratable):
    """Represents a fortran module."""
    
    def __init__(self, name, modifiers, dependencies, publics, contents, parent):
        super(Module, self).__init__(name, modifiers, parent)
        Decoratable.__init__(self)
        #Dependencies is a list of strings in the format module.member that
        #this module requires to operate correctly.
        self.dependencies = dependencies
        #The string contents between the module and end module keywords.
        self.contents = contents
        #A list of methods declared inside the module that were made public
        #using the public keyword in the body of the module (vs. as a 
        #modifier on the member itself).
        self.publics = publics
        #A list of ValueElements() that were declared in the body of the module.
        self.members = {}
        #A list of CustomType() declared in the module using fortran type...end type
        self.types = {}
        #A list of Executable() declared within the contains section of the module.
        self.executables = {}
        #The dictionary of docstrings extracted from the preamble section of the
        #module's contents.
        self.predocs = {}
        #The section in the module after CONTAINS keyword
        self.contains = ""
        #The original string that contains all the members and types before CONTAINS.
        self.preamble = ""
        #The string from which the module was parsed
        self.refstring = ""
        #The path to the library where this module was parsed from.
        self.filepath = None
        #The datetime that the file was last modified.
        self.change_time = None
        #changed keeps track of whether the module has had its refstring updated
        #via a real-time update since the sequencer last analyzed it.
        self.changed = False

        #Lines and character counts for finding where matches fit in the file
        self._lines = []
        self._chars = []
        self._contains_index = None

    def rt_update(self, statement, linenum, mode, modulep, lineparser):
        """Uses the specified line parser to parse the given statement.

        :arg statement: a string of lines that are part of a single statement.
        :arg linenum: the line number of the first line in the statement relative to
          the entire module contents.
        :arg mode: either 'insert', 'replace' or 'delete'
        :arg modulep: an instance of ModuleParser for handling the changes
          to the instance of the module.
        :arg lineparser: a line parser instance for dealing with new instances
          of types or executables that are add using only a signature.
        """
        #Most of the module is body, since that includes everything inside
        #of the module ... end module keywords. Since docstrings are handled
        #at a higher level by line parser, we only need to deal with the body
        #Changes of module name are so rare that we aren't going to bother with them.
        section = self.find_section(self.module.charindex(linenum, 1))
        if section == "body":
            modulep.rt_update(statement, self, mode, linenum, lineparser)

        #NOTE: docstrings are handled at a higher level by the line parser
        #because of the XML dependence.

    def unpickle(self, parent):
        """Sets the parent pointer references for the module *and* all of its
        child classes that also have pointer references."""
        self.parent = parent
        self._unpickle_collection(self.members)
        self._unpickle_collection(self.executables)
        self._unpickle_collection(self.types)
        
    def _unpickle_collection(self, collection):
        """Unpickles all members of the specified dictionary."""
        for mkey in collection:
            collection[mkey].unpickle(self)

    def __str__(self):
        output = []
        #Run statistics on the lines so it displays properly
        self.linenum(1)
        output.append("MODULE {} ({} lines)\n\n".format(self.name, len(self._lines)))
        uses = "\n\t".join(self.sorted_collection("dependencies"))
        output.append("USES:\n\t{}\n\n".format(uses))

        types = "\n\t".join([ t[1].__str__() for t in list(self.types.items()) ])
        output.append("TYPES:\n\t{}\n\n".format(types))

        functions = "\n\t".join([ x[1].__str__() for x in list(self.functions().items()) ])
        subroutines = "\n\t".join([ x[1].__str__() for x in list(self.subroutines().items()) ])
        output.append("EXECUTABLES:\n\t{}\n\n\t{}\n\n".format(functions, subroutines))

        return "".join(output)

    def get_dependency_element(self, symbol):
        """Checks if the specified symbol is the name of one of the methods
        that this module depends on. If it is, search for the actual code
        element and return it."""
        for depend in self.dependencies:
            if "." in depend:
                #We know the module name and the executable name, easy
                if depend.split(".")[1] == symbol.lower():
                    found = depend
                    break
            else:
                #We only have the name of a module, we have to search
                #the whole module for the element.
                fullname = "{}.{}".format(depend, symbol)
                if self.parent.get_executable(fullname) is not None:
                    found = fullname
                    break
        else:
            return None

        return self.parent.get_executable(found)

    def completions(self, symbol, attribute, recursive = False):
        """Finds all possible symbol completions of the given symbol that belong
        to this module and its dependencies.

        :arg symbol: the code symbol that needs to be completed.
        :arg attribute: one of ['dependencies', 'publics', 'members', 
          'types', 'executables'] for specifying which collections to search.
        :arg result: the possible completions collected so far in the search.
        """
        possible = []
        print([symbol, attribute])
        for ekey in self.collection(attribute):
            if symbol in ekey:
                possible.append(ekey)

        #Try this out on all the dependencies as well to find all the possible
        #completions.
        if recursive:
            for depkey in self.dependencies:
                #Completions need to be fast. If the module for the parent isn't already
                #loaded, we just ignore the completions it might have.
                if depkey in self.parent.modules:
                    possible.extend(self.parent.modules[depkey].completions(symbol, attribute))
            
        return possible

    @property
    def end_token(self):
        """Gets the end [code type] token for this instance."""
        return "end module"

    @property
    def contains_index(self):
        """Returns the *line number* that has the CONTAINS keyword separating the
        member and type definitions from the subroutines and functions."""
        if self._contains_index is None:
            max_t = 0
            for tkey in self.types:
                if self.types[tkey].end > max_t and not self.types[tkey].embedded:
                    max_t = self.types[tkey].end

            #Now we have a good first guess. Continue to iterate the next few lines
            #of the the refstring until we find a solid "CONTAINS" keyword. If there
            #are no types in the module, then max_t will be zero and we don't have
            #the danger of running into a contains keyword as part of a type. In that
            #case we can just keep going until we find it.
            i = 0
            start = self.linenum(max_t)[0]
            max_i = 10 if max_t > 0 else len(self._lines)

            while self._contains_index is None and i < max_i:
                if "contains" in self._lines[start + i].lower():
                    self._contains_index = start + i
                i += 1

            if self._contains_index is None:
                #There must not be a CONTAINS keyword in the module
                self._contains_index = len(self._lines)-1

        return self._contains_index

    @property
    def needs(self):
        """Returns a unique list of module names that this module depends on."""
        result = []
        for dep in self.dependencies:
            module = dep.split(".")[0].lower()
            if module not in result:
                result.append(module)

        return result

    def absolute_charindex(self, string, start, end):
        """Gets the absolute start and end indices for a regex match
        with reference to the original module file."""
        search = string[start:end]
        abs_start = self.refstring.index(search)
        return abs_start, (end - start) + abs_start

    def functions(self):
        """Returns a dictionary of all the functions in the module."""
        return self._filter_execs(False)
        
    def subroutines(self):        
        """Returns a dictionary of all the functions in the module."""
        return self._filter_execs(True)

    def _filter_execs(self, isSubroutine):
        """Filters the executables in the dictionary by their type."""
        result = {}
        for key in self.executables:
            if (isinstance(self.executables[key], Subroutine) and isSubroutine) or \
               (isinstance(self.executables[key], Function) and not isSubroutine):
                result[key] = self.executables[key]
        
        return result                

    def warn(self, collection):
        """Checks the module for documentation and best-practice warnings."""
        super(CodeElement, self).warn(collection)
        if not "implicit none" in self.modifiers:
            collection.append("WARNING: implicit none not set in {}".format(self.name))

    def type_search(self, basetype, symbolstr):
        """Recursively traverses the module trees looking for the final
        code element in a sequence of %-separated symbols.

        :arg basetype: the type name of the first element in the symbol string.
        :arg symblstr: a %-separated list of symbols, e.g. this%sym%sym2%go.
        """
        self.parent.type_search(basetype, symbolstr, self)

    def sorted_collection(self, attribute):
        """Returns the names of all elements in a collection sorted."""
        return sorted(self.collection(attribute))
    
    def collection(self, attribute):
        """Returns the collection corresponding the attribute name."""
        return {
            "dependencies": self.dependencies,
            "publics": self.publics,
            "members": self.members,
            "types": self.types,
            "executables": self.executables
        }[attribute]

    def update_refstring(self, string):
        """Updates the refstring that represents the original string that
        the module was parsed from. Also updates any properties or attributes
        that are derived from the refstring."""
        self.refstring = string
        self._lines = []
        self._contains_index = None
        self.changed = True

        #The only other references that become out of date are the contains
        #and preamble attributes which are determined by the parsers.
        #Assuming we did everything right with the rt update, we should be
        #able to just use the new contains index to update those.
        icontains = self.contains_index
        ichar = self.charindex(icontains, 0)
        self.preamble = string[:ichar]
        self.contains = string[ichar + 9:]

    def update_elements(self, line, column, charcount, docdelta=0):
        """Updates all the element instances that are children of this module
        to have new start and end charindex values based on an operation that
        was performed on the module source code.

        :arg line: the line number of the *start* of the operation.
        :arg column: the column number of the start of the operation.
        :arg charcount: the total character length change from the operation.
        :arg docdelta: the character length of changes made to types/execs
          that are children of the module whose docstrings external to their
          definitions were changed.
        """
        target = self.charindex(line, column) + charcount

        #We are looking for all the instances whose *start* attribute lies
        #after this target. Then we update them all by that amount.
        #However, we need to be careful because of docdelta. If an elements
        #docstring contains the target, we don't want to update it.
        if line < self.contains_index:
            for t in self.types:
                if self._update_char_check(self.types[t], target, docdelta):
                    self._element_charfix(self.types[t], charcount)

            for m in self.members:
                if self.members[m].start > target:
                    self.members[m].start += charcount
                    self.members[m].end += charcount

            self._contains_index = None
        else:
            for iexec in self.executables:
                if self._update_char_check(self.executables[iexec], target, docdelta):
                    self._element_charfix(self.executables[iexec], charcount)

    def _update_char_check(self, element, target, docdelta):
        """Checks whether the specified element should have its character indices
        updated as part of real-time updating."""
        if docdelta != 0:
            if (element.docstart <= target and 
                element.docend >= target - docdelta):
                return True
            else:
                return element.absstart > target
        else:
            return element.absstart > target

    def _element_charfix(self, element, charcount):
        """Updates the start and end attributes by charcount for the element."""
        element.start += charcount
        element.docstart += charcount
        element.end += charcount
        element.docend += charcount

    def get_element(self, line, column):
        """Gets the instance of the element who owns the specified line
        and column."""
        ichar = self.charindex(line, column)
        icontains = self.contains_index
        result = None

        if line < icontains:
            #We only need to search through the types and members.
            maxstart = 0
            tempresult = None
            for t in self.types:
                if ichar >= self.types[t].absstart:
                    if self.types[t].absstart > maxstart:
                        maxstart = self.types[t].absstart
                        tempresult = self.types[t]

            #This takes the possibility of an incomplete type into account
            if (tempresult is not None and (ichar <= tempresult.end or 
                                            tempresult.incomplete)):
                result = tempresult

            if not result:
                #Members only span a single line usually and don't get added
                #without an end token.
                for m in self.members:
                    if (ichar >= self.members[m].start and 
                        ichar <= self.members[m].end):
                        result = self.members[m]
                        break
        else:
            #We only need to search through the executables
            tempresult = None
            maxstart = 0

            for iexec in self.executables:
                if (ichar >= self.executables[iexec].absstart):
                    if self.executables[iexec].absstart > maxstart:
                        maxstart = self.executables[iexec].absstart
                        tempresult = self.executables[iexec]

            if tempresult is not None and (ichar <= tempresult.end or
                                           tempresult.incomplete):
                result = tempresult

        if result is None:
            #We must be in the text of the module, return the module
            return self
        else:
            return result

    def update_embedded(self, attribute):
        """Updates the elements in the module 'result' that have character indices
        that are a subset of another element. These correspond to cases where the
        type or subroutine is declared within another subroutine.

        :attr attribute: the name of the collection to update over.
        """
        #The parser doesn't handle embeddings deeper than two levels.
        coll = self.collection(attribute)
        keys = list(coll.keys())
        for key in keys:
            element = coll[key]
            new_parent = self.find_embedded_parent(element)
            if new_parent is not None:
                #Update the parent of the embedded element, add it to the collection
                #of the parent element and then delete it from the module's collection.
                element.parent = new_parent
                if attribute == "types":
                    new_parent.types[key] = element
                else:
                    new_parent.executables[key] = element
                del coll[key]

    def find_embedded_parent(self, element):
        """Finds the parent (if any) of the embedded element by seeing
        if the start and end indices of the element are a subset of 
        any type or executable in this module.
        """
        result = None
        for t in self.types:
            if (element.start > self.types[t].start and
                element.end < self.types[t].end):
                result = self.types[t]
                break
        else:
            for iexec in self.executables:
                if (element.start > self.executables[iexec].start and
                    element.end < self.executables[iexec].end):
                    result = self.executables[iexec]
                    break

        return result

    def charindex(self, line, column):
        """Gets the absolute character index of the line and column
        in the continuous string."""
        #Make sure that we have chars and lines to work from if this
        #gets called before linenum() does.
        if len(self._lines) == 0:
            self.linenum(1)

        return self._chars[line - 1] + column

    def linenum(self, index):
        """Gets the line number of the character at the specified index.
        If the result is unknown, -1 is returned."""
        if len(self._lines) == 0 and self.refstring != "":
            self._lines = self.refstring.split("\n")
            #Add one for the \n that we split on for each line
            self._chars = [ len(x) + 1 for x in self._lines ]
            #Remove the last line break since it doesn't exist
            self._chars[-1] -= 1

            #Now we want to add up the number of characters in each line
            #as the lines progress so that it is easy to search for the
            #line of a single character index
            total = 0
            for i in range(len(self._chars)):
                total += self._chars[i]
                self._chars[i] = total

        if len(self._lines) > 0:
            #Now, find the first index where the character value is >= index
            result = -1
            i = 0
            while result == -1 and i < len(self._chars):
                if index <= self._chars[i]:
                    result = [ i, self._chars[i] - index]
                i += 1

            return result
        else:
            return [ -1, -1 ]

class DocGroup(object):
    """Represents a list of DocElements that have been logically grouped together."""
    
    def __init__(self, XMLElement, decorates = None):
        self.xml = XMLElement
        self.decorates = decorates
        self.attributes = {}
        self.doctype = "group"

        #Extract all the attributes of the group into a dictionary
        for key in list(self.xml.keys()):
            self.attributes[key] = self.xml.get(key)
            
    def __str__(self):
        return "GROUP: {}\nAttributes: {}\nDecorates: {}\n".format(self.name,
                                                                self.attributes, self.decorates)

    @property
    def name(self):
        """Gets the name of this group if it exists."""
        if "name" in self.attributes:
            return self.attributes["name"]
        else:
            return None

class DocElement(object):
    """Represents a docstring enabled element in a code file."""
    
    def __init__(self, XMLElement, parser, decorates = None, parent = None):
        """Initializes the docstring element by parsing out the contents and references.

         - XMLElement: the element from the XML tree for the docstring element.
         - parser: an instance of the DocStringParser() with compiled re objects.
        """
        if XMLElement is not None:
            self.contents = XMLElement.text
            self.doctype = XMLElement.tag
        else:
            self.contents = ""
            self.doctype = ""

        self.references = []        
        #Group is the parent of the docstring (i.e. group), NOT the code element it decorates
        self.group = parent
        
        #Decorates is the code element that the docstring refers to. This is common to all code
        #elements but is only set at a higher level by the code element.
        self.decorates = decorates
        self.attributes = {}
        if XMLElement is not None:
            self.parse(parser, XMLElement)

    def __getstate__(self):
        """Cleans up the object so that it can be pickled without any pointer
        issues."""
        odict = self.__dict__.copy() # copy the dict since we change it
        del odict['group']
        if self.group is not None and not isinstance(self.group, str):
            odict['_parent_name'] = self.group.name
        else:
            odict['_parent_name'] = None
        return odict

    def __setstate__(self, dict):
        self.group = None
        self.__dict__.update(dict)

    @property
    def pointsto(self):
        """Returns the name of the variable, parameter, etc. that this
        docstring points to by checking whether a "name" attribute is
        present on the docstring."""
        if "name" in self.attributes:
            return self.attributes["name"].lower()
        else:
            return None

    def parse(self, parser, xml):
        """Parses the rawtext to extract contents and references."""
        #We can only process references if the XML tag has inner-XML
        if xml.text is not None:
            matches = parser.RE_REFS.finditer(xml.text)
            if matches:
                for match in matches:
                    #Handle "special" references to this.name and param.name here.
                    self.references.append(match.group("reference"))

        #We also need to get all the XML attributes into the element
        for key in list(xml.keys()):
            self.attributes[key] = xml.get(key)
            
    def __str__(self):
        return "{}: {}\nAttributes: {}\nDecorates: {}\n\n".format(self.doctype, self.contents,
                                                                self.attributes, self.decorates)
