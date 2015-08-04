# -- cython: profile=True

"""
This module provider an optional protocol parser that returns
NumPy arrays.

=============================================================================
This module should not be imported by any of the main python-driver modules,
as numpy is an optional dependency.
=============================================================================
"""

include "ioutils.pyx"

cimport cython
from libc.stdint cimport uint64_t
from cpython.ref cimport Py_INCREF, PyObject

from cassandra.bytesio cimport BytesIOReader
from cassandra.datatypes cimport DataType
from cassandra.parsing cimport ParseDesc, ColumnParser, RowParser
from cassandra import cqltypes
from cassandra.util import is_little_endian

import numpy as np


cdef extern from "numpyFlags.h":
    # Include 'numpyFlags.h' into the generated C code to disable the
    # deprecated NumPy API
    pass

cdef extern from "Python.h":
    # An integer type large enough to hold a pointer
    ctypedef uint64_t Py_uintptr_t


# Simple array descriptor, useful to parse rows into a NumPy array
ctypedef struct ArrDesc:
    Py_uintptr_t buf_ptr
    int stride # should be large enough as we allocate contiguous arrays
    int is_object

arrDescDtype = np.dtype(
    [ ('buf_ptr', np.uintp)
    , ('stride', np.dtype('i'))
    , ('is_object', np.dtype('i'))
    ])

_cqltype_to_numpy = {
    cqltypes.LongType:          np.dtype('>i8'),
    cqltypes.CounterColumnType: np.dtype('>i8'),
    cqltypes.Int32Type:         np.dtype('>i4'),
    cqltypes.ShortType:         np.dtype('>i2'),
    cqltypes.FloatType:         np.dtype('>f4'),
    cqltypes.DoubleType:        np.dtype('>f8'),
}

obj_dtype = np.dtype('O')


cdef class NumpyParser(ColumnParser):
    """Decode a ResultMessage into a bunch of NumPy arrays"""

    cpdef parse_rows(self, BytesIOReader reader, ParseDesc desc):
        cdef Py_ssize_t i, rowcount
        cdef ArrDesc[::1] array_descs
        cdef ArrDesc *arrs

        rowcount = read_int(reader)
        array_descs, arrays = make_arrays(desc, rowcount)
        arrs = &array_descs[0]

        for i in range(rowcount):
            unpack_row(reader, desc, arrs)

        return [make_native_byteorder(arr) for arr in arrays]
        # return pd.DataFrame(dict(zip(desc.colnames, arrays)))


### Helper functions to create NumPy arrays and array descriptors

def make_arrays(ParseDesc desc, array_size):
    """
    Allocate arrays for each result column.

    returns a tuple of (array_descs, arrays), where
        'array_descs' describe the arrays for NativeRowParser and
        'arrays' is a dict mapping column names to arrays
            (e.g. this can be fed into pandas.DataFrame)
    """
    array_descs = np.empty((desc.rowsize,), arrDescDtype)
    arrays = []

    for i, coltype in enumerate(desc.coltypes):
        arr = make_array(coltype, array_size)
        array_descs[i]['buf_ptr'] = arr.ctypes.data
        array_descs[i]['stride'] = arr.strides[0]
        array_descs[i]['is_object'] = coltype not in _cqltype_to_numpy
        arrays.append(arr)

    return array_descs, arrays


def make_array(coltype, array_size):
    """
    Allocate a new NumPy array of the given column type and size.
    """
    dtype = _cqltype_to_numpy.get(coltype, obj_dtype)
    return np.empty((array_size,), dtype=dtype)


#### Parse rows into NumPy arrays

@cython.boundscheck(False)
@cython.wraparound(False)
cdef inline int unpack_row(
        BytesIOReader reader, ParseDesc desc, ArrDesc *arrays) except -1:
    cdef char *buf
    cdef Py_ssize_t i, bufsize, rowsize = desc.rowsize
    cdef ArrDesc arr
    cdef DataType dt

    for i in range(rowsize):
        buf = get_buf(reader, &bufsize)
        arr = arrays[i]

        if arr.is_object:
            dt = desc.datatypes[i]
            val = dt.deserialize(buf, bufsize, desc.protocol_version)
            Py_INCREF(val)
            (<PyObject **> arr.buf_ptr)[0] = <PyObject *> val
        else:
            memcopy(buf, <char *> arr.buf_ptr, bufsize)

        # Update the pointer into the array for the next time
        arrays[i].buf_ptr += arr.stride

    return 0


cdef inline void memcopy(char *src, char *dst, Py_ssize_t size):
    """
    Our own simple memcopy which can be inlined. This is useful because our data types
    are only a few bytes.
    """
    cdef Py_ssize_t i
    for i in range(size):
        dst[i] = src[i]


def make_native_byteorder(arr):
    """
    Make sure all values have a native endian in the NumPy arrays.
    """
    if is_little_endian and not arr.dtype.kind == 'O':
        # We have arrays in big-endian order. First swap the bytes
        # into little endian order, and then update the numpy dtype
        # accordingly (e.g. from '>i8' to '<i8')
        #
        # Ignore any object arrays of dtype('O')
        return arr.byteswap().newbyteorder()
    return arr