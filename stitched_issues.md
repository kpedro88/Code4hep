# Stitched issues worked around in Code4hep

This file records places where Code4hep compensates for problems that
originate in the upstream **Stitched** package, why each one matters for
Code4hep, and the proposed fix in Stitched. Once a fix lands upstream, the
corresponding workaround here can be removed.

Repo inspected: `tmp/stitched`
(`https://github.com/code4hep/stitched-alpha2`, branch `main_2026_05_27`,
HEAD `f739c6321`).

The relevant upstream file in every case is `StitchedConfig.cmake.in`
(installed as `lib64/cmake/Stitched/StitchedConfig.cmake`), which is what
`find_package(Stitched)` executes in a consumer.

---

## 1. `StitchedConfig` does not `find_dependency(pybind11)` — REAL, actively worked around

### Symptom
With a bare `find_package(Stitched REQUIRED)` (no prior `find_package(pybind11)`),
CMake configuration fails while loading Stitched's own targets:

```
CMake Error at .../Stitched/StitchedTargets.cmake:182 (set_target_properties):
  ... pybind11::pybind11 ...
/usr/.../ld: cannot find -lpybind11::pybind11: No such file or directory
```

### Root cause
`FWCore/PythonParameterSet/CMakeLists.txt` links pybind11 **PUBLIC**:

```cmake
target_link_libraries(stitched_FWCore_PythonParameterSet
    PUBLIC
        stitched_FWCore_ParameterSet
        Python3::Python
        pybind11::pybind11
)
```

Because the link is PUBLIC, `pybind11::pybind11` ends up in the installed
target's `INTERFACE_LINK_LIBRARIES` (see `StitchedTargets.cmake`, target
`Stitched::stitched_FWCore_PythonParameterSet`). But `StitchedConfig.cmake.in`
explicitly skips finding it, with a comment asserting (incorrectly) that it is
private:

```cmake
# StitchedConfig.cmake.in:34
#find_dependency(pybind11 REQUIRED) # not needed since is PRIVATE dependency
```

So when a consumer loads Stitched, the `pybind11::pybind11` target does not
exist and the literal string is passed to the linker as `-lpybind11::pybind11`.

### Why it matters for Code4hep
Code4hep links several Stitched FWCore libraries and must be able to call
`find_package(Stitched)` cleanly. Today it only works because Code4hep finds
pybind11 itself, *before* Stitched, purely to pre-create the target:

- `CMakeLists.txt` — `find_package(pybind11 REQUIRED)` before `find_package(Stitched REQUIRED)`
- `cmake/Code4hepConfig.cmake.in` — `find_dependency(pybind11 REQUIRED)` before `find_dependency(Stitched REQUIRED)`

These lines are pure workarounds: Code4hep itself does not use pybind11.

### Proposed fix (Stitched)
In `StitchedConfig.cmake.in`, replace the commented-out line with a real call
(pybind11 is a PUBLIC dependency, so a consumer needs it):

```cmake
find_dependency(pybind11 REQUIRED)
```

After this lands, drop the pybind11 pre-finds in Code4hep's `CMakeLists.txt`
and `cmake/Code4hepConfig.cmake.in`.

---

## 2. `StitchedConfig` does not `find_dependency` for `cpu_features` — REAL, latent

### Symptom
None yet in Code4hep, because no Code4hep package currently links the affected
Stitched targets. It is a latent failure of the same kind as the pybind11 one.

### Root cause
`Stitched::stitched_FWCore_Services` carries `CpuFeatures::cpu_features` in its
`INTERFACE_LINK_LIBRARIES`, which transitively reaches these PUBLIC-exported
targets:

```
stitched_FWCore_AbstractServices
stitched_FWCore_MessageLogger
stitched_FWCore_ParameterSet
stitched_FWCore_ServiceRegistry
stitched_DataFormats_Provenance
stitched_FWCore_Utilities
```

`StitchedConfig.cmake.in` never finds cpu_features; it only mentions it in a
comment:

```cmake
# StitchedConfig.cmake.in:36
# Note: Python3, cpu_features and other dependencies may need to be found
#       by the consuming project if they're used directly
```

`CpuFeatures::cpu_features` is therefore undefined after `find_package(Stitched)`.

### Why it matters for Code4hep
As soon as any Code4hep (or downstream experiment) package links a target that
transitively pulls `stitched_FWCore_Services` — e.g. anything using the FWCore
services machinery — configuration will fail with
`cannot find -lCpuFeatures::cpu_features`, exactly as pybind11 did. Code4hep has
no workaround for this today; the build simply happens not to hit it yet.

### Proposed fix (Stitched)
Add to `StitchedConfig.cmake.in` (cpu_features ships a CMake package config):

```cmake
find_dependency(CpuFeatures REQUIRED)
```

(If cpu_features is genuinely only an implementation detail, link it PRIVATE in
the relevant `FWCore/.../CMakeLists.txt` instead, so it does not leak into the
interface at all. Either fix removes the latent break.)

---

## 3. `StitchedConfig` does not `find_dependency(Python3)` — REAL, masked

### Root cause
`Python3::Python` appears in the `INTERFACE_LINK_LIBRARIES` of
`Stitched::stitched_FWCore_ParameterSetReader` and
`Stitched::stitched_FWCore_PythonParameterSet`, but `StitchedConfig.cmake.in`
does not `find_dependency(Python3 ...)` (again only the line-36 comment).

### Why it matters for Code4hep
Currently masked: Code4hep's top-level `CMakeLists.txt` runs
`find_package(Python3 REQUIRED COMPONENTS Interpreter Development)` for its own
reasons before any Stitched target is used, so `Python3::Python` already exists.
A consumer of Stitched that does **not** independently find Python3 would fail
the same way pybind11 does.

### Proposed fix (Stitched)
Add to `StitchedConfig.cmake.in`:

```cmake
find_dependency(Python3 REQUIRED COMPONENTS Interpreter Development)
```

Code4hep can keep finding Python3 itself (it needs the interpreter), but it
should not be *required* to do so just to consume Stitched.

---

## 4. CLHEP include-path patch — OBSOLETE workaround, can be removed

### What the workaround does
The build script `build/install/code4hep.sh` writes a `clhep_patch.cmake` that
overrides CMake's `find_package` to rewrite `CLHEP_INCLUDE_DIR` whenever it
matches a `CMSSW` path, and injects it via
`-DCMAKE_PROJECT_Code4hep_INCLUDE=build_Code4hep/clhep_patch.cmake`. It was
added to fix CLHEP headers resolving to a stale CMSSW location.

### Finding
This is no longer necessary. Configuring Code4hep **without** the patch (i.e.
dropping the `-DCMAKE_PROJECT_Code4hep_INCLUDE=...clhep_patch.cmake` flag, with
everything else unchanged) builds cleanly: all 4 libraries, 4 plugins, the ROOT
dictionary, and the executables build and install, and `CLHEP_INCLUDE_DIR`
resolves to the correct cvmfs path
(`.../external/clhep/2.4.7.1-.../include`).

The reason is that `build/install/code4hep.sh` already passes an explicit
`-DCLHEP_ROOT=...` pointing at the CLHEP CMake package directory, so CLHEP's own
config (`CLHEPConfig.cmake`, which does
`set_and_check(CLHEP_INCLUDE_DIR "${PACKAGE_PREFIX_DIR}/include")`) resolves the
include path correctly on its own. The `find_package` override is redundant.

### Strictly speaking, not a Stitched issue
Stitched consumes CLHEP correctly via `find_dependency(CLHEP REQUIRED)`; the
stale path came from the CMSSW environment, not from Stitched. It is recorded
here only because it is a build-time workaround in the Code4hep build scripts.

### Proposed fix (Code4hep)
Remove the `clhep_patch.cmake` heredoc and the
`-DCMAKE_PROJECT_Code4hep_INCLUDE=build_Code4hep/clhep_patch.cmake` line from
`build/install/code4hep.sh`, keeping the existing `-DCLHEP_ROOT=...`. No Stitched
change is required.

---

## Summary

| # | Issue | Status | Workaround location | Fix (in Stitched unless noted) |
|---|-------|--------|---------------------|--------------------------------|
| 1 | pybind11 missing from `StitchedConfig` (PUBLIC dep) | real, active | `CMakeLists.txt`, `cmake/Code4hepConfig.cmake.in` (pybind11 pre-find) | uncomment `find_dependency(pybind11 REQUIRED)` |
| 2 | cpu_features missing from `StitchedConfig` (PUBLIC dep) | real, latent | none yet | add `find_dependency(CpuFeatures REQUIRED)` (or link PRIVATE) |
| 3 | Python3 missing from `StitchedConfig` (PUBLIC dep) | real, masked | top-level `find_package(Python3 ...)` | add `find_dependency(Python3 REQUIRED COMPONENTS Interpreter Development)` |
| 4 | CLHEP include-path patch | obsolete | `build/install/code4hep.sh` (`clhep_patch.cmake`) | remove patch; keep `-DCLHEP_ROOT` (Code4hep-side) |

Issues 1–3 share one root cause: `StitchedConfig.cmake.in` omits
`find_dependency` calls for externals that Stitched targets export **PUBLIC**.
The robust upstream fix is to make `StitchedConfig.cmake.in` find every external
that appears in any target's `INTERFACE_LINK_LIBRARIES` (pybind11, cpu_features,
Python3), or to demote genuinely-private externals to PRIVATE linkage so they do
not leak into the interface.
