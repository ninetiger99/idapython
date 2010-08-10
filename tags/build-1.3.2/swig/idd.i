%ignore debugger_t;
%ignore memory_info_t;
%ignore register_info_t;
%ignore appcall;
%apply unsigned char { char dtyp };

%include "idd.hpp"

%clear(char dtyp);

%{
//<code(py_idd)>

//-------------------------------------------------------------------------
static bool dbg_can_query()
{
  // Reject the request only if no debugger is set
  // or the debugger cannot be queried while not in suspended state
  return !(dbg == NULL || (!dbg->may_disturb() && get_process_state() > DSTATE_SUSP));
}

//-------------------------------------------------------------------------
static PyObject *meminfo_vec_t_to_py(meminfo_vec_t &areas)
{
  PyObject *py_list = PyList_New(areas.size());
  meminfo_vec_t::const_iterator it, it_end(areas.end());
  Py_ssize_t i = 0;
  for ( it=areas.begin(); it!=it_end; ++it, ++i )
  {
    const memory_info_t &mi = *it;
    // startEA endEA name sclass sbase bitness perm
    PyList_SetItem(py_list, i,
      Py_BuildValue("("PY_FMT64 PY_FMT64 "ss" PY_FMT64 "II)",
        pyul_t(mi.startEA),
        pyul_t(mi.endEA),
        mi.name.c_str(),
        mi.sclass.c_str(),
        pyul_t(mi.sbase),
        (unsigned int)(mi.bitness),
        (unsigned int)mi.perm));
  }
  return py_list;
}

//-------------------------------------------------------------------------
PyObject *dbg_get_memory_info()
{
  if (!dbg_can_query())
    Py_RETURN_NONE;

  // Invalidate memory
  invalidate_dbgmem_config();
  invalidate_dbgmem_contents(BADADDR, BADADDR);

  meminfo_vec_t areas;
  dbg->get_memory_info(areas);
  return meminfo_vec_t_to_py(areas);
}

//-------------------------------------------------------------------------
PyObject *dbg_get_registers()
{
  if (dbg == NULL)
    Py_RETURN_NONE;

  PyObject *py_list = PyList_New(dbg->registers_size);

  for (int i=0;i<dbg->registers_size;i++)
  {
    register_info_t &ri = dbg->registers[i];
    PyObject *py_bits;

    // Does this register have bit strings?
    if (ri.bit_strings != NULL)
    {
      int nbits = (int)b2a_width((int)get_dtyp_size(ri.dtyp), 0) * 4;
      py_bits = PyList_New(nbits);
      for (int i=0;i<nbits;i++)
      {
        const char *s = ri.bit_strings[i];
        PyList_SetItem(py_bits, i, PyString_FromString(s == NULL ? "" : s));
      }
    }
    else
    {
      Py_INCREF(Py_None);
      py_bits = Py_None;
    }

    // name flags class dtyp bit_strings bit_strings_default_mask
    PyList_SetItem(py_list, i,
      Py_BuildValue("(sIIINI)",
        ri.name,
        ri.flags,
        (unsigned int)ri.register_class,
        (unsigned int)ri.dtyp,
        py_bits,
        (unsigned int)ri.bit_strings_default));
  }
  return py_list;
}

//-------------------------------------------------------------------------
PyObject *dbg_get_thread_sreg_base(PyObject *py_tid, PyObject *py_sreg_value)
{
  if (!dbg_can_query() || !PyInt_Check(py_tid) || !PyInt_Check(py_sreg_value))
    Py_RETURN_NONE;
  ea_t answer;
  thid_t tid = PyInt_AsLong(py_tid);
  int sreg_value = PyInt_AsLong(py_sreg_value);
  if (dbg->thread_get_sreg_base(tid, sreg_value, &answer) != 1)
    Py_RETURN_NONE;
  return Py_BuildValue(PY_FMT64, pyul_t(answer));
}

//-------------------------------------------------------------------------
PyObject *dbg_read_memory(PyObject *py_ea, PyObject *py_sz)
{
  uint64 ea, sz;
  if ( !dbg_can_query() || !PyGetNumber(py_ea, &ea) || !PyGetNumber(py_sz, &sz) )
    Py_RETURN_NONE;

  char *buf = new char[size_t(sz)];
  if ( buf == NULL )
    Py_RETURN_NONE;

  PyObject *ret;
  if ( (size_t)dbg->read_memory(ea_t(ea), buf, size_t(sz)) == sz )
  {
    ret = PyString_FromStringAndSize(buf, (Py_ssize_t)sz);
  }
  else
  {
    Py_INCREF(Py_None);
    ret = Py_None;
  }
  delete [] buf;
  return ret;
}

//-------------------------------------------------------------------------
PyObject *dbg_write_memory(PyObject *py_ea, PyObject *py_buf)
{
  uint64 ea;
  if ( !dbg_can_query() || !PyString_Check(py_buf) || !PyGetNumber(py_ea, &ea) )
    Py_RETURN_NONE;

  size_t sz = PyString_GET_SIZE(py_buf);
  void *buf = (void *)PyString_AS_STRING(py_buf);
  if ( dbg->write_memory(ea_t(ea), buf, sz) != sz )
    Py_RETURN_FALSE;
  Py_RETURN_TRUE;
}

//-------------------------------------------------------------------------
PyObject *py_appcall(
  ea_t func_ea,
  thid_t tid,
  PyObject *py_type,
  PyObject *py_fields,
  PyObject *arg_list)
{
  if ( !PyList_Check(arg_list) )
    return NULL;

  const char *type   = py_type == Py_None ? NULL : PyString_AS_STRING(py_type);
  const char *fields = py_fields == Py_None ? NULL : PyString_AS_STRING(py_fields);

  // Convert Python arguments into IDC values
  qvector<idc_value_t> idc_args;
  int sn = 0;
  Py_ssize_t nargs = PyList_Size(arg_list);
  idc_args.resize(nargs);
  bool ok = true;
  for ( Py_ssize_t i=0; i<nargs; i++ )
  {
    // Get argument
    PyObject *py_item = PyList_GetItem(arg_list, i);
    if ( (debug & IDA_DEBUG_APPCALL) != 0 )
    {
      qstring s;
      PyObjectToString(py_item, &s);
      msg("obj[%d]->%s\n", int(i), s.c_str());
    }
    // Convert it
    if ( pyvar_to_idcvar(py_item, &idc_args[i], &sn) < CIP_OK )
    {
      ok = false;
      break;
    }
  }

  // Set exception message
  if ( !ok )
  {
    PyErr_SetString(PyExc_ValueError, "PyAppCall: Failed to convert Python values to IDC values");
    return NULL;
  }

  if ( (debug & IDA_DEBUG_APPCALL) != 0 )
  {
    msg("input variables:\n"
        "----------------\n");
    qstring s;
    for (Py_ssize_t i=0;i<nargs;i++)
    {
      VarPrint(&s, &idc_args[i]);
      msg("%d]\n%s\n-----------\n", int(i), s.c_str());
      s.qclear();
    }
  }
  // Do Appcall
  idc_value_t idc_result;
  error_t ret = appcall(
    func_ea,
    tid,
    (type_t *)type,
    (p_list *)fields,
    idc_args.size(),
    idc_args.begin(),
    &idc_result);

  if (ret != eOk)
  {
    // An exception was thrown?
    if (ret == eExecThrow)
    {
      // Convert the result (which is a debug_event) into a Python object
      PyObject *py_appcall_exc(NULL);
      idcvar_to_pyvar(idc_result, &py_appcall_exc);
      PyErr_SetObject(PyExc_OSError, py_appcall_exc);
      Py_DECREF(py_appcall_exc);
      return NULL;
    }
    // An error in the Appcall? (or an exception but AppCallOptions/DEBEV is not set)
    else
    {
      char err_str[MAXSTR];
      qstrerror(ret, err_str, sizeof(err_str));
      PyErr_SetString(PyExc_Exception, err_str);
      return NULL;
    }
  }

  if ( (debug & IDA_DEBUG_APPCALL) != 0 )
  {
    msg("return variables:\n"
        "-----------------\n");
    qstring s;
    for (Py_ssize_t i=0;i<nargs;i++)
    {
      VarPrint(&s, &idc_args[i]);
      msg("%d]\n%s\n-----------\n", int(i), s.c_str());
      s.qclear();
    }
  }
  // Convert IDC values back to Python values
  for (Py_ssize_t i=0;i<nargs;i++)
  {
    // Get argument
    PyObject *py_item = PyList_GetItem(arg_list, i);
    // We convert arguments but fail only on fatal errors
    // (we ignore failure because of immutable objects)
    if (idcvar_to_pyvar(idc_args[i], &py_item) == CIP_FAILED)
    {
      PyErr_SetString(PyExc_ValueError, "PyAppCall: Failed while converting IDC values to Python values");
      return NULL;
    }
  }
  // Convert the result from IDC back to Python
  PyObject *py_result(NULL);
  if (idcvar_to_pyvar(idc_result, &py_result) <= CIP_IMMUTABLE)
  {
    PyErr_SetString(PyExc_ValueError, "PyAppCall: Failed while converting IDC return value to Python return value");
    return NULL;
  }

  if ( (debug & IDA_DEBUG_APPCALL) != 0 )
  {
    msg("return var:\n"
        "-----------\n");
    qstring s;
    VarPrint(&s, &idc_result);
    msg("%s\n-----------\n", s.c_str());
  }
  return py_result;
}
//</code(py_idd)>
%}

%rename (appcall) py_appcall;

%inline %{

//<inline(py_idd)>
PyObject *dbg_write_memory(PyObject *py_ea, PyObject *py_buf);
PyObject *dbg_read_memory(PyObject *py_ea, PyObject *py_sz);
PyObject *dbg_get_thread_sreg_base(PyObject *py_tid, PyObject *py_sreg_value);
PyObject *dbg_get_registers();
PyObject *dbg_get_memory_info();
static PyObject *dbg_get_name()
{
  if ( dbg == NULL )
    Py_RETURN_NONE;
  return PyString_FromString(dbg->name);
}

static bool dbg_can_query();
PyObject *py_appcall(
  ea_t func_ea,
  thid_t tid,
  PyObject *py_type,
  PyObject *py_fields,
  PyObject *arg_list);
//</inline(py_idd)>

char get_event_module_name(const debug_event_t* ev, char *buf, size_t bufsize)
{
    qstrncpy(buf, ev->modinfo.name, bufsize);
    return true;
}

ea_t get_event_module_base(const debug_event_t* ev)
{
    return ev->modinfo.base;
}

asize_t get_event_module_size(const debug_event_t* ev)
{
    return ev->modinfo.size;
}

char get_event_exc_info(const debug_event_t* ev, char *buf, size_t bufsize)
{
    qstrncpy(buf, ev->exc.info, bufsize);
    return true;
}

char get_event_info(const debug_event_t* ev, char *buf, size_t bufsize)
{
    qstrncpy(buf, ev->info, bufsize);
    return true;
}

ea_t get_event_bpt_hea(const debug_event_t* ev)
{
    return ev->bpt.hea;
}

uint get_event_exc_code(const debug_event_t* ev)
{
    return ev->exc.code;
}

ea_t get_event_exc_ea(const debug_event_t* ev)
{
    return ev->exc.ea;
}

bool can_exc_continue(const debug_event_t* ev)
{
    return ev->exc.can_cont;
}
%}

%pythoncode %{
#<pycode(py_idd)>
import types

# -----------------------------------------------------------------------
# This class is used with |Appcall.array() method
class Appcall_array__(object):
    def __init__(self, tp):
        self.__type = tp

    def pack(self, L):
        t = type(L)
        if not (t == types.ListType or t == types.TupleType):
            raise ValueError, "Either a list or a type must be passed"
        self.__size = len(L)
        if self.__size == 1:
            self.__typedobj = Appcall__.typedobj(self.__type + ";")
        else:
            self.__typedobj = Appcall__.typedobj("%s x[%d];" % (self.__type, self.__size))
        # Now store the object in a string buffer
        ok, buf = self.__typedobj.store(L)
        if ok:
            return Appcall__.byref(buf)
        else:
            return None

    def try_to_convert_to_list(self, obj):
        if not (hasattr(obj, "0") and hasattr(obj, str(self.__size-1))):
            return obj
        # at this point, we are sure we have an "idc list"
        # let us convert to a Python list
        return [getattr(obj, str(x)) for x in xrange(0, self.__size)]

    def unpack(self, buf, as_list=True):
        # take the value from the special ref object
        if isinstance(buf, PyIdc_cvt_refclass__):
            buf = buf.value

        # we can only unpack from strings
        if type(buf) != types.StringType:
            raise ValueError, "Cannot unpack this type!"
        # now unpack
        ok, obj = self.__typedobj.retrieve(buf)
        if not ok:
            raise ValueError, "Failed while unpacking!"
        if not as_list:
            return obj
        return self.try_to_convert_to_list(obj)

# -----------------------------------------------------------------------
# This class is used with the obj() method
class Appcall_object__(object):
    """Helper class used to initialize empty objects"""
    def __init__(self, **kwds):
        self.__dict__ = kwds

    def __getitem__(self, idx):
        return getattr(self, idx)

# -----------------------------------------------------------------------
# Wrapper class for the appcall()
class Appcall_callable__(object):
    """
    Helper class to issue appcalls using a natural syntax:
      appcall.FunctionNameInTheDatabase(arguments, ....)
    or
      appcall["Function@8"](arguments, ...)
    or
      f8 = appcall["Function@8"]
      f8(arg1, arg2, ...)
    or
      o = appcall.obj()
      i = byref(5)
      appcall.funcname(arg1, i, "hello", o)
    """
    def __init__(self, ea, tp = None, fld = None):
        """Initializes an appcall with a given function ea"""
        self.__ea     = ea
        self.__type   = tp
        self.__fields = fld
        self.__options = None # Appcall options

    def __get_options(self):
        return self.__options if self.__options != None else Appcall__.get_appcall_options()
    def __set_options(self, v):
        self.__options = v
    """Sets the Appcall options locally to this Appcall instance"""
    options = property(__get_options, __set_options)

    def __call__(self, *args):
        """Make object callable. We redirect execution to idaapi.appcall()"""
        if self.ea == None:
            raise ValueError, "Object not callable!"

        # unpack arguments and convert to a list
        arg_list = [x for x in args]

        # Save appcall options and set new global options
        old_opt = Appcall__.get_appcall_options()
        Appcall__.set_appcall_options(self.options)

        # Do the Appcall (use the wrapped version)
        e_obj = None
        try:
            r = _idaapi.appcall(
               self.ea,
               _idaapi.get_current_thread(),
               self.type,
               self.fields,
               arg_list)
        except Exception, e:
            e_obj = e
        
        # Restore appcall options
        Appcall__.set_appcall_options(old_opt)

        # Return or re-raise exception
        if e_obj:
            raise Exception, e_obj
        return r

    def __get_ea(self):
        return self.__ea
    def __set_ea(self, val):
        self.__ea = val
    """Returns or sets the EA associated with this object"""
    ea = property(__get_ea, __set_ea)

    def __get_size(self):
        if self.__type == None:
            return -1
        r = _idaapi.get_type_size0(_idaapi.cvar.idati, self.__type)
        if not r:
            return -1
        return r
    """Returns the size of the type"""
    size = property(__get_size)

    def __get_type(self):
        return self.__type
    """Returns the typestring"""
    type = property(__get_type)

    def __get_fields(self):
        return self.__fields
    """Returns the typestring"""
    fields = property(__get_fields)

    def retrieve(self, src=None, flags=0):
        """
        Unpacks a typed object from the database if an ea is given or from a string if a string was passed
        @param src: the address of the object or a string
        @return: Returns a tuple of boolean and object or error number (Bool, Error | Object).
        """

        # Nothing passed? Take the address and unpack from the database
        if not src:
            src = self.ea

        if type(src) == types.StringType:
            return _idaapi.unpack_object_from_bv(_idaapi.cvar.idati, self.type, self.fields, src, flags)
        else:
            return _idaapi.unpack_object_from_idb(_idaapi.cvar.idati, self.type, self.fields, src, flags)

    def store(self, obj, dest_ea=None, base_ea=0, flags=0):
        """
        Packs an object into a given ea if provided or into a string if no address was passed.

        @return: - If packing to a string then a Tuple(Boolean, packed_string or error code)
                 - If packing to the database then a return code is returned (0 is success)
        """

        # no ea passed? thus pack to a string
        if not dest_ea:
            return _idaapi.pack_object_to_bv(obj, _idaapi.cvar.idati, self.type, self.fields, base_ea, flags)
        else:
            return _idaapi.pack_object_to_idb(obj, _idaapi.cvar.idati, self.type, self.fields, dest_ea, flags)

# -----------------------------------------------------------------------
class Appcall_consts__(object):
    def __init__(self, default=0):
        self.__default = default

    def __getattr__(self, attr):
        return Appcall__.valueof(attr, self.__default)

# -----------------------------------------------------------------------
class Appcall__(object):
    """
    Only set up the appcall, do not run it.
    you should call CleanupAppcall() when finished
    """
    APPCALL_MANUAL = 0x1
    """
    Return debug event information
    If this bit is set, exceptions during appcall
    will generate idc exceptions with full
    information about the exception
    """
    APPCALL_DEBEV  = 0x2

    def __init__(self):
        self.__consts = Appcall_consts__()

    def __get_consts(self):
        return self.__consts
    """Use Appcall.Consts.CONST_NAME to access constants"""
    Consts = property(__get_consts)

    @staticmethod
    def __name_or_ea(name_or_ea):
        """Function that accepts a name or an ea and checks if the address is enabled.
        If a name is passed then idaapi.get_name_ea() is applied to retrieve the name
        @return: Returns the resolved EA or raises an exception if the address is not enabled
        """

        # a string? try to resolve it
        if type(name_or_ea) == types.StringType:
            ea = _idaapi.get_name_ea(_idaapi.BADADDR, name_or_ea)
        else:
            ea = name_or_ea
        # could not resolve name or invalid address?
        if ea == _idaapi.BADADDR or not _idaapi.isEnabled(ea):
            raise ValueError, "Undefined function " + name_or_ea
        return ea

    @staticmethod
    def proto(name_or_ea, prototype, flags = None):
        """Allows you to instantiate an appcall with the desired prototype"""

        # resolve and raise exception on error
        ea = Appcall__.__name_or_ea(name_or_ea)
        # parse the type
        if not flags:
            flags = 1 | 2 | 4 # PT_SIL | PT_NDC | PT_TYP
        result = _idaapi.idc_parse_decl(_idaapi.cvar.idati, prototype, flags)
        if not result:
            raise ValueError, "Could not parse type: " + prototype
        # Return the callable method with type info
        return Appcall_callable__(ea, result[1], result[2])

    def __getattr__(self, name_or_ea):
        """Allows you to call functions as if they were member functions"""
        # resolve and raise exception on error
        ea = self.__name_or_ea(name_or_ea)
        if ea == _idaapi.BADADDR:
            raise ValueError, "Undefined function " + name
        # Return the callable method
        return Appcall_callable__(ea)

    def __getitem__(self, idx):
        """
        Use self[func_name] syntax if the function name contains invalid characters for an attribute name
        See __getattr___
        """
        return self.__getattr__(idx)

    @staticmethod
    def valueof(name, default=0):
        """
        Returns the numeric value of a given name string.
        If the name could not be resolved then the default value will be returned
        """
        t, v = _idaapi.get_name_value(_idaapi.BADADDR, name)
        if t == 0: # NT_NONE
          v = default
        return v

    @staticmethod
    def int64(v):
        """Whenever a 64bit number is needed use this method to construct an object"""
        return PyIdc_cvt_int64__(v)

    @staticmethod
    def byref(val):
        """
        Method to create references to immutable objects
        Currently we support references to int/strings
        Objects need not be passed by reference (this will be done automatically)
        """
        return PyIdc_cvt_refclass__(val)

    @staticmethod
    def buffer(str = None, size = 0, fill="\x00"):
        """
        Creates a string buffer. The returned value (r) will be a byref object.
        Use r.value to get the contents and r.size to get the buffer's size
        """
        if not str:
            str = ""
        left = size - len(str)
        if left > 0:
            str = str + (fill * left)
        r = Appcall__.byref(str)
        r.size = size
        return r

    @staticmethod
    def obj(**kwds):
        """Returns an empty object or objects with attributes as passed via its keywords arguments"""
        return Appcall_object__(**kwds)

    @staticmethod
    def cstr(val):
        return as_cstr(val)

    @staticmethod
    def unicode(s):
        return as_unicode(s)

    @staticmethod
    def array(type_name):
        """Defines an array type. Later you need to pack() / unpack()"""
        return Appcall_array__(type_name)

    @staticmethod
    def typedobj(typestr, ea=None):
        """
        Parses a type string and returns an appcall object.
        One can then use retrieve() member method
        @param ea: Optional parameter that later can be used to retrieve the type
        @return: Appcall object
        """
        # parse the type
        result = _idaapi.idc_parse_decl(_idaapi.cvar.idati, typestr, 1 | 2 | 4) # PT_SIL | PT_NDC | PT_TYP
        if not result:
            raise ValueError, "Could not parse type: " + typestr
        # Return the callable method with type info
        return Appcall_callable__(ea, result[1], result[2])

    @staticmethod
    def set_appcall_options(opt):
        old_opt = Appcall__.get_appcall_options()
        _idaapi.cvar.inf.appcall_options = opt
        return old_opt

    @staticmethod
    def get_appcall_options():
        return _idaapi.cvar.inf.appcall_options

    @staticmethod
    def cleanup_appcall(tid = 0):
        """Equivalent to IDC's CleanupAppcall()"""
        return _idaapi.cleanup_appcall(tid)

Appcall = Appcall__()
#</pycode(py_idd)>
%}