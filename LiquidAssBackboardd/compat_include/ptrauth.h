// Non-Darwin build-host shim only (see Makefile guard). Vanilla (non-Apple)
// clang cannot build this SDK's Objective-C++ headers as Clang modules due
// to an `using_if_exists` attribute incompatibility; LGSymbolResolver.mm's
// actual ptrauth_* calls are already correctly guarded by
// __has_feature(ptrauth_calls), which is false for a plain (non-arm64e)
// arm64 target -- i.e. every iOS 12-era device this project supports -- so
// this header's contents are never exercised. It exists purely so the
// unconditional #include succeeds when building with -fno-modules.
#pragma once
