from .executable import ExecutableGenerator
from shutil import copy
import xml.etree.ElementTree as ET
import os
import datetime
import dateutil.parser

class TestGenerator(object):
    """Generates automatic unit tests based on docstrings in the fortran
    doc elements defined in the code files.

    :arg parser: an instance of the code parser that has code elements
      with all the docstrings.
    :arg libraryroot: the path to the folder that will contain all the
      unit test code files and executables.
    :arg fortpy_templates: the path to the fortpy templates folder to
      copy dependencies from.
    :arg rerun: specifies whether to re-run the tests (i.e. don't recopy
      and re-compile everything, just re-run the tests using existing
      code files. May fail if something has changed.

    :attr xgenerator: an instance of ExecutableGenerator to generate the
      .f90 program files for performing the unit tests.
    :attr dependfiles: a list of additional files to be copied from the
      fortpy templates directory that are needed for the unit testing.
    """
    def __init__(self, parser, libraryroot, fortpy_templates, rerun = False):
        self.parser = parser
        self.libraryroot = libraryroot
        self.xgenerator = ExecutableGenerator(parser, libraryroot)
        self.rerun = rerun

        self.dependfiles = [ "timing.c", "timing.h", "timing.o", "fortpy.f90", "Makefile.ifort" ]
        self._fortpy = fortpy_templates

        #Stores the identifiers of unit tests whose files changed so they
        #need to be recompiled and executed.
        self._changed = []
        #Load the file dates for previous tests into self.archive
        self._xml_get()

    @property
    def tests_to_run(self):
        """Returns the identifiers for those unit tests that are new or
        needed to be recreated because of code changes."""
        return self._changed

    def write(self):
        """Creates a fortran program for each subroutine in the code parsers
        modules lists that tests the subroutine/function."""
        #We need to enumerate over a *copy* of the keys list since the list of 
        #modules is likely to change during the execution as dependencies
        #are found and loaded.
        currentlist = self.parser.modules.keys()
        for mkey in currentlist:
            self._write_module(self.parser.modules[mkey])
        
    def _write_module(self, module):
        """Generates the fortran programs for all executables in the module
        code element specified."""
        for execkey in module.executables:
            anexec = module.executables[execkey]
            #We need to check whether this executable has any outcomes defined
            #for a unit test. If it doesn't, we just skip it.
            found = False
            i = 0

            while not found and i < len(anexec.tests):
                if anexec.tests[i].doctype == "outcome":
                    found = True
                i += 1

            if found:
                self._write_executable(module, anexec)

    def _write_executable(self, module, executable):
        """Generates the fortran program for the specified executable code
        element."""
        #The way this works is that the latest copy of each module that
        #this executable needs to run is copied to a staging folder
        #where it can be compiled.
        identifier = "{}.{}".format(module.name, executable.name)
        self.xgenerator.reset(identifier, self.libraryroot, self.rerun)
        needs = self.xgenerator.needs()

        #Now we need to check whether the files it depends on have changed
        #since the last time we wrote and compiled.
        different = False
        if identifier in self.archive:
            previous = self.archive[identifier]
        else:
            previous = {}

        #As we copy files, we need to keep track of the last date they were
        #modified so that we only retest things that change.
        files = {}
        for needk in needs:
            needed = self.parser.modules[needk]
            moddate = modification_date(needed.filepath)
            #Get the path to the code file in the executable directory so that
            #we can copy it over if it doesn't exist.
            if needk not in self.parser.mappings:
                target = os.path.join(self.xgenerator.folder, needk + ".f90")
            else:
                target = os.path.join(self.xgenerator.folder, self.parser.mappings[needk])

            if needed.filepath not in previous or \
               (needed.filepath in previous and previous[needed.filepath] < moddate) or \
               not os.path.exists(target):
                print "COPY {}".format(needed.filepath)
                copy(needed.filepath, self.xgenerator.folder)
                different = True
            files[needed.filepath] = moddate

        #We also need to copy across any dependency files that don't exist
        #These don't ever change, so we only need to check for existence
        for dfile in self.dependfiles:
            target = os.path.join(self.xgenerator.folder, dfile)
            if not os.path.exists(target):
                source = os.path.join(self._fortpy, dfile)
                print "COPY: {}".format(source)
                copy(source, self.xgenerator.folder)
                different = True

        #All the code files needed for compilation are now in the directory.
        #Create the executable file and the makefile for compilation
        if different:
            print "\nUNITTEST: writing executable for {}".format(executable)
            self.xgenerator.write()
            self.xgenerator.makefile()
            self._changed.append(identifier)

            #Overwrite the file date values for this executable in the archive
            #Also, save the archive in case something goes wrong in the next
            #Executable writing.
            self.archive[identifier] = files
            self._xml_save()
        else:            
            print "\nUNITTEST: ignored '{}' because code hasn't changed.".format(executable.name)

    def _xml_get(self):
        """Returns an XML tree for the documont that tracks dates for code
        files and unit tests."""
        target = os.path.join(self.libraryroot, "archive.xml")
        self.archive = {}

        if os.path.exists(target):
            el = ET.parse(target).getroot()

            for test in el:
                files = {}
                for f in test:
                    files[f.attrib["path"]] = dateutil.parser.parse(f.attrib["modified"])
                self.archive[test.attrib["name"]] = files

    def _xml_save(self):
        """Saves the archive dictionary to XML."""
        root = ET.Element("archive")
        for testk in self.archive:
            subel = ET.SubElement(root, "unittest", attrib={ "name": testk })
            for f in self.archive[testk]:
                single = self.archive[testk][f]
                fileel = ET.SubElement(subel, "file", attrib={ "path": f, "modified": single.isoformat() })

        tree = ET.ElementTree(root)
        xmlpath = os.path.expanduser(os.path.join(self.libraryroot, "archive.xml"))
        tree.write(xmlpath)

def modification_date(filename):
    t = os.path.getmtime(filename)
    return datetime.datetime.fromtimestamp(t)
