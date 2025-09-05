// Compatibility shim for newer libc++ (Xcode 16.x) removing internal traits
// We cannot modify vendored libraries; instead, we neutralize _NOEXCEPT(...)
// expressions to plain noexcept via a forced include during compilation.

#pragma once

#if defined(__clang__) && defined(_LIBCPP_VERSION)
  #ifdef _NOEXCEPT
    #undef _NOEXCEPT
  #endif
  // Make any use like _NOEXCEPT(expr) become plain 'noexcept'
  #define _NOEXCEPT(...) noexcept
#endif


