import fortpy.debug as debug
import json
import hashlib
import gc
import sys
import fortpy.settings as settings
import os

try:
    import cPickle as pickle
except ImportError:
    import pickle

class Serializer(object):
    """Serializes parsed module contents to optimizie loading for modules
    whose contents don't change very often."""
    
    version = 10
    """
    Version number (integer) for file system cache.

    Increment this number when there are any incompatible changes in
    parser representation classes.  For example, the following changes
    are regarded as incompatible.

    - Class name is changed.
    - Class is moved to another module.
    - Defined slot of the class is changed.
    """

    def __init__(self):
        self.__index = None
        self.py_tag = 'cpython-%s%s' % sys.version_info[:2]
        """
        Short name for distinguish Python implementations and versions.

        It's like `sys.implementation.cache_tag` but for Python < 3.3
        we generate something similar.  See:
        http://docs.python.org/3/library/sys.html#sys.implementation

        .. todo:: Detect interpreter (e.g., PyPy).
        """

    def load_module(self, path, changed_time, parser):
        """Attempts to load the specified module from a serialized, cached
        version. If that fails, the method returns none."""
        try:
            pickle_changed_time = self._index[path]
        except KeyError:
            return None

        if (changed_time is not None and
            pickle_changed_time < changed_time):
            # the pickle file is outdated
            return None

        target_path = self._get_hashed_path(path)
        with open(target_path, 'rb') as f:
            try:
                gc.disable()
                cache_module = pickle.load(f)
                for mod in cache_module:
                    mod.unpickle(parser)
            finally:
                gc.enable()

        debug.dbg('pickle loaded: %s', path)
        return cache_module

    def save_module(self, path, module):
        """Saves the specified module and its contents to the file system
        so that it doesn't have to be parsed again unless it has changed."""
        #First, get a list of the module paths that have already been 
        #pickled. We will add to that list of pickling this module.
        self.__index = None
        try:
            files = self._index
        except KeyError:
            files = {}
            self._index = files

        target_path = self._get_hashed_path(path)
        with open(target_path, 'wb') as f:
            pickle.dump(module, f, pickle.HIGHEST_PROTOCOL)
            files[path] = module[0].change_time

        #Save the list back to the disk
        self._flush_index()

    @property
    def _index(self):
        """Keys a list of file paths that have been pickled in this directory.
        The index is stored in a json file in the same directory as the 
        pickled objects."""
        if self.__index is None:
            try:
                with open(self._get_path('index.json')) as f:
                    data = json.load(f)
            except (IOError, ValueError):
                self.__index = {}
            else:
                # 0 means version is not defined (= always delete cache):
                if data.get('version', 0) != self.version:
                    self.clear_cache()
                    self.__index = {}
                else:
                    self.__index = data['index']
        return self.__index

    def _flush_index(self):
        """Writes the current list of file paths in the index to the json file
        and then sets self.__index = None.
        """
        data = {'version': self.version, 'index': self._index}
        with open(self._get_path('index.json'), 'w') as f:
            json.dump(data, f)
        self.__index = None

    def clear_cache(self):
        """Removes the cached directory and all of its contents so that we don't
        have any more cached modules."""
        shutil.rmtree(self._cache_directory())

    def _get_hashed_path(self, path):
        """Returns an md5 hash for the specified file path."""
        return self._get_path('%s.pkl' % hashlib.md5(path.encode("utf-8")).hexdigest())

    def _get_path(self, file):
        """Creates the cache directory if it doesn't already exist. Returns the
        full path to the specified file inside the cache directory."""
        dir = self._cache_directory()
        if not os.path.exists(dir):
            os.makedirs(dir)
        return os.path.join(dir, file)

    def _cache_directory(self):
        """Returns the full path to the cache directory as specified in settings.
        """
        return os.path.join(settings.cache_directory, self.py_tag)
