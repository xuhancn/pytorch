#pragma once

#ifndef CPP_WRAPPER_MODULE
// All pure C++ headers for the C++ frontend.
#include <torch/all.h>
#endif

// Python bindings for the C++ frontend (includes Python.h).
#include <torch/python.h>


#ifdef CPP_WRAPPER_MODULE
#include <torch/cpp_wrapper.h>
#endif