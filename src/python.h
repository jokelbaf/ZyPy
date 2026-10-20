// Python's C assertions translate to symbols that embedded programs cannot link.
#ifndef NDEBUG
#define NDEBUG
#endif

// translate-c reports an old GCC version for macOS, which selects C11 atomics that it can't translate.
#ifndef _Py_USE_GCC_BUILTIN_ATOMICS
#define _Py_USE_GCC_BUILTIN_ATOMICS 1
#endif

#include <Python.h>

// Wrap the initializer in a variable so translate-c can translate it.
static const PyModuleDef_Base zypy_PyModuleDef_HEAD_INIT = PyModuleDef_HEAD_INIT;
